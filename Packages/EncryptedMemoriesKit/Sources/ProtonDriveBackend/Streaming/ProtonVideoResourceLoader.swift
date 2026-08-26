import AVFoundation
import Foundation
import MediaByteCache
import PhotosCore

/// Serves a Proton video to AVFoundation through cleartext byte-range requests.
/// Each request maps to the encrypted blocks that cover it, fetches only those blocks, decrypts them,
/// and returns a contiguous file-order window. Obsolete requests are cancelled on seek; encrypted disk
/// data and a small decrypted-block LRU avoid repeated fetches.
final class ProtonVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let prepared: PreparedVideo
    private let source: PhotoVideoStreamSource
    private let crypto: DriveCrypto
    private let cache: VideoByteRangeCache
    private let admission: JoinedShutdownGate
    /// Stable owner lease for this loader lifetime. A later lookup after clear cannot authorize an old loader.
    private let ownerGeneration: CacheWriterGeneration.Token
    private let decryptedCache = NSCache<NSNumber, NSData>()

    // In-flight serving tasks, keyed by the loading request, so a seek can cancel obsolete prefetch.
    private let lock = NSLock()
    private struct RequestTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var tasks: [ObjectIdentifier: RequestTask] = [:]
    private struct PrefetchTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var prefetchTasks: [Int: PrefetchTask] = [:]
    /// How many ~4 MB blocks to warm ahead of the bytes AVFoundation just consumed. Deep enough that the
    /// network-fetch+decrypt read-ahead stays in front of playback (the shallow 4-block window micro-stalled
    /// higher-bitrate video). Paired with a roomier `decryptedCache` so warmed blocks survive until requested.
    private let forwardPrefetchBlockCount = 8
    /// Clear offset the forward read-ahead window was last scheduled from. Lets a repeated request for
    /// the same position skip re-scanning the block map; a seek (any other offset) still re-schedules.
    private var lastForwardPrefetchOffset = -1

    init(
        prepared: PreparedVideo,
        source: PhotoVideoStreamSource,
        crypto: DriveCrypto,
        admission: JoinedShutdownGate,
        cache: VideoByteRangeCache = .shared
    ) {
        self.prepared = prepared
        self.source = source
        self.crypto = crypto
        self.admission = admission
        self.cache = cache
        self.ownerGeneration = cache.captureOwnerGeneration()
        super.init()
        // Keep the read-ahead window and recent blocks. At about 4 MB per block, the transient limit is 80 MB.
        decryptedCache.countLimit = 20
    }

    deinit {
        let activeTasks = lock.withLock {
            let activeTasks = tasks.values.map(\.task) + prefetchTasks.values.map(\.task)
            tasks.removeAll()
            prefetchTasks.removeAll()
            return activeTasks
        }
        activeTasks.forEach { $0.cancel() }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = prepared.contentTypeUTI
            info.isByteRangeAccessSupported = true
            info.contentLength = Int64(prepared.totalSize)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let key = ObjectIdentifier(loadingRequest)
        let taskID = UUID()
        lock.withLock {
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.admission.withAdmission { [self] in
                        try await self.serve(dataRequest, request: loadingRequest)
                    }
                    if !Task.isCancelled { loadingRequest.finishLoading() }
                } catch is CancellationError {
                    // A seek cancels the outer task and AVFoundation will re-ask. A closed account gate
                    // cancels only the admitted child, so finish that stale request deterministically.
                    if !Task.isCancelled {
                        loadingRequest.finishLoading(with: CancellationError() as NSError)
                    }
                } catch {
                    if !Task.isCancelled {
                        loadingRequest.finishLoading(with: error as NSError)
                    }
                }
                self.lock.withLock {
                    guard self.tasks[key]?.id == taskID else { return }
                    self.tasks.removeValue(forKey: key)
                }
            }
            tasks[key] = RequestTask(id: taskID, task: task)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        let task = lock.withLock { tasks.removeValue(forKey: key)?.task }
        task?.cancel()
        let obsoletePrefetch = lock.withLock { () -> [Task<Void, Never>] in
            lastForwardPrefetchOffset = -1
            let tasks = prefetchTasks.values.map(\.task)
            prefetchTasks.removeAll()
            return tasks
        }
        obsoletePrefetch.forEach { $0.cancel() }
        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey, "strategy": "range", "cancelled": "true",
            ])
    }

    // MARK: - Serving

    private func serve(
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        request: AVAssetResourceLoadingRequest
    ) async throws {
        let offset = Int(dataRequest.currentOffset)
        let total = prepared.totalSize
        // Serve to the end of the resource only when AVFoundation requests it.
        let length =
            dataRequest.requestsAllDataToEndOfResource
            ? total - offset
            : Int(dataRequest.requestedOffset) + dataRequest.requestedLength - offset
        let slices = prepared.blockMap.slices(offset: offset, length: max(0, length))

        var served = 0
        var cacheHits = 0
        var cacheMisses = 0
        for slice in slices {
            try Task.checkCancellation()
            guard let block = prepared.block(at: slice.blockIndex) else { continue }
            let (clear, hit) = try await decryptedBlock(block, priority: .immediate)
            if hit { cacheHits += 1 } else { cacheMisses += 1 }
            let from = slice.inBlock.lower
            let to = min(slice.inBlock.upper, clear.count)
            guard from < to else { continue }
            dataRequest.respond(with: clear.subdata(in: from..<to))
            served += to - from
        }
        scheduleForwardPrefetch(afterClearOffset: offset + served, reason: "requestServed")

        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey,
                "strategy": "range",
                "contentLength": "\(total)",
                "contentType": prepared.contentTypeUTI,
                "rangeRequested": "\(offset)-\(offset + max(0, length))",
                "rangeServed": "\(offset)-\(offset + served)",
                "cacheHit": "\(cacheHits)",
                "cacheMiss": "\(cacheMisses)",
                "bytesServed": "\(served)",
            ])
    }

    /// Decrypted bytes for a block + whether it came from a cache (in-memory or disk). Network is the
    /// last resort; fetched encrypted bytes are persisted so reopen / seek-back reuses them.
    private func decryptedBlock(
        _ block: VideoBlock,
        priority: ProtonRequestPriority
    ) async throws -> (Data, hit: Bool) {
        let key = NSNumber(value: block.index)
        if let cached = decryptedCache.object(forKey: key) { return (cached as Data, true) }

        var hit = true
        let encrypted: Data
        let lookup = await cache.lookupAsync(uid: prepared.uid, block: block.index)
        if let disk = lookup.encrypted {
            encrypted = disk
        } else {
            hit = false
            encrypted = try await source.encryptedBlockData(block, priority: priority)
            _ = await cache.storeAsync(
                uid: prepared.uid,
                block: block.index,
                encrypted: encrypted,
                ticket: lookup.ticket,
                ownerGeneration: ownerGeneration
            )
        }
        let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
        decryptedCache.setObject(clear as NSData, forKey: key)
        return (clear, hit)
    }

    /// Starts warming the blocks immediately after the bytes AVFoundation just consumed. This matters
    /// on reopen/resume: the first requested range may be fully cached and play instantly, but without
    /// read-ahead the next uncached block is only requested when playback reaches the edge.
    ///
    /// Driven from a single point (after serving) since served bytes reflect actual progress. The
    /// read-ahead set is found with a binary search instead of a linear filter over every block, and a
    /// repeat at the same `clearOffset` is skipped wholesale (a seek changes the offset and re-schedules).
    private func scheduleForwardPrefetch(afterClearOffset clearOffset: Int, reason: String) {
        let advanced = lock.withLock { () -> Bool in
            guard clearOffset != lastForwardPrefetchOffset else { return false }
            lastForwardPrefetchOffset = clearOffset
            return true
        }
        guard advanced else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
            PhotoDiagnostics.shared.emit(
                "VideoStream",
                [
                    "uid": uidKey, "strategy": "prefetch", "reason": reason,
                    "scheduled": "false", "deduped": "true",
                ], throttleSeconds: 0.5)
            return
        }
        let candidates = prepared.blockMap
            .forwardBlocks(afterClearOffset: clearOffset, count: forwardPrefetchBlockCount)
            .compactMap { prepared.block(at: $0.index) }
        guard !candidates.isEmpty else { return }
        for block in candidates {
            schedulePrefetch(block, reason: reason)
        }
    }

    private func schedulePrefetch(_ block: VideoBlock, reason: String) {
        let key = NSNumber(value: block.index)
        guard decryptedCache.object(forKey: key) == nil else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
            return
        }

        let scheduled = lock.withLock { () -> Bool in
            guard prefetchTasks[block.index] == nil else { return false }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let (_, hit) = try await self.admission.withAdmission { [self] in
                        try await self.decryptedBlock(block, priority: .foregroundPrefetch)
                    }
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey,
                            "strategy": "prefetch",
                            "block": "\(block.index)",
                            "reason": reason,
                            "cacheHit": "\(hit)",
                        ], throttleSeconds: 0.5)
                } catch is CancellationError {
                } catch {
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey,
                            "strategy": "prefetch",
                            "block": "\(block.index)",
                            "reason": reason,
                            "error": "\(error)",
                        ], throttleSeconds: 0.5)
                }
                self.lock.withLock {
                    guard self.prefetchTasks[block.index]?.id == taskID else { return }
                    self.prefetchTasks.removeValue(forKey: block.index)
                }
            }
            prefetchTasks[block.index] = PrefetchTask(id: taskID, task: task)
            return true
        }
        if scheduled {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchScheduled")
            PhotoDiagnostics.shared.emit(
                "VideoStream",
                [
                    "uid": uidKey, "strategy": "prefetch", "reason": reason,
                    "block": "\(block.index)", "scheduled": "true", "deduped": "false",
                ], throttleSeconds: 0.5)
        } else {
            PhotoDiagnostics.shared.increment("perf.videoPrefetchDeduped")
        }
    }

    private var uidKey: String { "\(prepared.uid.volumeID)~\(prepared.uid.nodeID)" }
}
