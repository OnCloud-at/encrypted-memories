import AVFoundation
import Foundation
import MediaByteCache
import PhotosCore

/// Serves a Proton video to AVFoundation through cleartext byte-range requests.
/// Each request maps to the encrypted blocks that cover it, fetches only those blocks, decrypts them,
/// and returns a contiguous file-order window. Obsolete requests are cancelled on seek; encrypted disk
/// data and a small decrypted-block LRU avoid repeated fetches.
final class ProtonVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, VideoStreamReadAheadTuning,
    @unchecked Sendable
{
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
    /// Blocks warmed as decrypted data ahead of the served bytes. This is the hot window; it stays small
    /// because each entry holds about 4 MB of cleartext in memory.
    private let forwardPrefetchBlockCount = 8
    /// Blocks warmed beyond the hot window as encrypted bytes on disk. Deep enough for a high-bitrate clip
    /// to survive a slow stretch, cheap in memory because nothing is decrypted before it is needed.
    /// Sized from the clip's own bitrate once the player reports its duration.
    private var deepPrefetchBlockCount = 8
    /// Bound for a very high bitrate, so one clip cannot queue unbounded fetches.
    private static let deepPrefetchBlockLimit = 48
    /// Blocks warmed at open time, before AVFoundation asks for anything. The player decides on its own
    /// when playback can start without stalling (`automaticallyWaitsToMinimizeStalling`), and that decision
    /// is only as good as the bytes we can already serve: without this warm-up the first block is fetched
    /// and decrypted while the player is already waiting for it.
    private let openingPrefetchBlockCount = 6
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

    /// Sizes the deep read-ahead from the clip's average bitrate. A 4K clip needs several times the bytes of
    /// a 1080p clip for the same seconds of playback, and a small clip needs no deep window at all.
    ///
    /// This never delays playback: the extra blocks are fetched in the background at prefetch priority, and
    /// the player alone decides when it starts. A fast connection with a small clip therefore waits no longer
    /// than before; it simply has the whole file on disk sooner.
    func useReadAhead(forPlaybackDuration seconds: Double) {
        guard
            let bounded = VideoReadAheadWindow.blockCount(
                totalSize: prepared.totalSize,
                durationSeconds: seconds,
                blockCount: prepared.blocks.count,
                minimumBlocks: forwardPrefetchBlockCount,
                maximumBlocks: Self.deepPrefetchBlockLimit
            )
        else { return }
        let bytesPerSecond = Double(prepared.totalSize) / seconds
        let changed = lock.withLock { () -> Bool in
            guard bounded > deepPrefetchBlockCount else { return false }
            deepPrefetchBlockCount = bounded
            lastForwardPrefetchOffset = -1  // let the next served range schedule the wider window
            return true
        }
        guard changed else { return }
        PhotoDiagnostics.shared.emit(
            "VideoStream",
            [
                "uid": uidKey, "strategy": "readAhead",
                "blocks": "\(bounded)",
                "mbitPerSecond": String(format: "%.1f", bytesPerSecond * 8 / 1_000_000),
            ], throttleSeconds: 0.5)
    }

    /// Warms the start of the file and its last block before the player requests anything.
    ///
    /// The start carries the first samples. The last block matters because a container whose moov atom sits
    /// at the end makes AVFoundation read the tail first; serving that from a warm block removes one
    /// network round trip from every open.
    func primePlaybackStart() {
        let head = prepared.blockMap
            .forwardBlocks(afterClearOffset: -1, count: openingPrefetchBlockCount)
            .compactMap { prepared.block(at: $0.index) }
        // The first block and the tail gate the open, so they must not wait behind other prefetch work.
        for (position, block) in head.enumerated() {
            schedulePrefetch(
                block, reason: "open", priority: position == 0 ? .userInitiated : .foregroundPrefetch)
        }
        if let tail = prepared.blocks.last, !head.contains(where: { $0.index == tail.index }) {
            schedulePrefetch(tail, reason: "open-tail", priority: .userInitiated)
        }
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
        // The read-ahead stays alive: AVFoundation also cancels for reasons other than a seek (for example
        // a full buffer), and the next served block re-schedules the window without duplicates.
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
            let (clear, hit) = try await decryptedBlock(block, priority: .immediate, joinsPrefetch: true)
            if hit { cacheHits += 1 } else { cacheMisses += 1 }
            let from = slice.inBlock.lower
            let to = min(slice.inBlock.upper, clear.count)
            guard from < to else { continue }
            dataRequest.respond(with: clear.subdata(in: from..<to))
            served += to - from
            // Per block, not per request: one open-ended request can span the whole file, and the
            // read-ahead must keep moving while it is served.
            scheduleForwardPrefetch(afterClearOffset: offset + served, reason: "blockServed")
        }
        if served == 0 {
            scheduleForwardPrefetch(afterClearOffset: offset, reason: "requestServed")
        }

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
    ///
    /// `joinsPrefetch` makes a demand read wait for an in-flight prefetch of the same block instead of
    /// downloading it a second time. A prefetch task must pass `false`, or it would wait for itself.
    private func decryptedBlock(
        _ block: VideoBlock,
        priority: ProtonRequestPriority,
        joinsPrefetch: Bool = false
    ) async throws -> (Data, hit: Bool) {
        let key = NSNumber(value: block.index)
        if let cached = decryptedCache.object(forKey: key) { return (cached as Data, true) }

        if joinsPrefetch, let prefetch = lock.withLock({ prefetchTasks[block.index]?.task }) {
            await prefetch.value
            try Task.checkCancellation()
            if let cached = decryptedCache.object(forKey: key) { return (cached as Data, true) }
            // A deep warm leaves only encrypted bytes on disk, and a failed prefetch leaves nothing:
            // both continue with the lookup below.
        }

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
    /// Driven from a single point (after each served block) since served bytes reflect actual progress. The
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
        let deepCount = lock.withLock { deepPrefetchBlockCount }
        let window = prepared.blockMap
            .forwardBlocks(afterClearOffset: clearOffset, count: max(forwardPrefetchBlockCount, deepCount))
            .compactMap { prepared.block(at: $0.index) }
        guard !window.isEmpty else { return }
        for (position, block) in window.enumerated() {
            if position < forwardPrefetchBlockCount {
                schedulePrefetch(block, reason: reason)
            } else {
                // Beyond the hot window keep the bytes encrypted on disk. Decrypting them early would cost
                // about 4 MB of memory per block for content the player may never reach.
                scheduleEncryptedWarm(block, reason: reason)
            }
        }
    }

    /// Fetches one block's encrypted bytes into the disk cache without decrypting them.
    private func scheduleEncryptedWarm(_ block: VideoBlock, reason: String) {
        let key = NSNumber(value: block.index)
        guard decryptedCache.object(forKey: key) == nil else { return }
        let scheduled = lock.withLock { () -> Bool in
            guard prefetchTasks[block.index] == nil else { return false }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.admission.withAdmission { [self] in
                        try await self.warmEncryptedBlock(block)
                    }
                } catch is CancellationError {
                } catch {
                    PhotoDiagnostics.shared.emit(
                        "VideoStream",
                        [
                            "uid": self.uidKey, "strategy": "deepWarm",
                            "block": "\(block.index)", "reason": reason, "error": "\(error)",
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
        if scheduled { PhotoDiagnostics.shared.increment("perf.videoDeepWarmScheduled") }
    }

    /// Stores the block's encrypted bytes for a later serve. A block already on disk costs nothing.
    private func warmEncryptedBlock(_ block: VideoBlock) async throws {
        let lookup = await cache.lookupAsync(uid: prepared.uid, block: block.index)
        guard lookup.encrypted == nil else { return }
        let encrypted = try await source.encryptedBlockData(block, priority: .foregroundPrefetch)
        _ = await cache.storeAsync(
            uid: prepared.uid,
            block: block.index,
            encrypted: encrypted,
            ticket: lookup.ticket,
            ownerGeneration: ownerGeneration
        )
    }

    private func schedulePrefetch(
        _ block: VideoBlock,
        reason: String,
        priority: ProtonRequestPriority = .foregroundPrefetch
    ) {
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
                        try await self.decryptedBlock(block, priority: priority)
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
