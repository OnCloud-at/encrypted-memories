import CryptoKit
import Foundation
import MediaByteCache
import MediaDecodingCore
import PhotosCore

public enum BackgroundThumbnailDecodeResult: Sendable {
    case decoded(DecodedThumbnail)
    case missing
    case undecodable
}

public struct ThumbnailFeedCoreConfiguration: Sendable, Equatable {
    public let targetPixels: CGFloat
    public let downloadConcurrencyLimit: Int
    public let initialDownloadConcurrency: Int
    public let minimumDownloadConcurrency: Int
    public let batchSize: Int
    public let decodedMemoryBudgetBytes: Int
    public let maxConcurrentDecodes: Int
    public let priorityQueueLimit: Int
    public let sequentialScanLimit: Int
    public let visibleQuietWindow: TimeInterval
    public let crawlBackoffSeconds: TimeInterval
    public let downloadTimeoutSeconds: Double

    public init(
        targetPixels: CGFloat = 320,
        downloadConcurrencyLimit: Int = 4,
        initialDownloadConcurrency: Int? = nil,
        minimumDownloadConcurrency: Int = 1,
        batchSize: Int = 8,
        decodedMemoryBudgetBytes: Int = 128 * 1024 * 1024,
        maxConcurrentDecodes: Int = 2,
        priorityQueueLimit: Int = 600,
        sequentialScanLimit: Int = 128,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 5,
        downloadTimeoutSeconds: Double = 20
    ) {
        let downloadLimit = max(1, downloadConcurrencyLimit)
        let minimum = min(max(1, minimumDownloadConcurrency), downloadLimit)
        let initial = initialDownloadConcurrency ?? max(minimum, downloadLimit / 2)
        self.targetPixels = max(1, targetPixels)
        self.downloadConcurrencyLimit = downloadLimit
        self.initialDownloadConcurrency = min(max(minimum, initial), downloadLimit)
        self.minimumDownloadConcurrency = minimum
        self.batchSize = max(1, batchSize)
        self.decodedMemoryBudgetBytes = max(1, decodedMemoryBudgetBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.priorityQueueLimit = max(1, priorityQueueLimit)
        self.sequentialScanLimit = max(1, sequentialScanLimit)
        self.visibleQuietWindow = max(0, visibleQuietWindow)
        self.crawlBackoffSeconds = max(0, crawlBackoffSeconds)
        self.downloadTimeoutSeconds = max(0.1, downloadTimeoutSeconds)
    }
}

public protocol ThumbnailCoverageCheckpointStore: Sendable {
    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID>
    func recordPresent(_ uids: [PhotoUID], for key: String)
    func recordMissing(_ uids: [PhotoUID], for key: String)
}

/// Handle to one feed arrival-wake subscription. The registration is safe to end from any executor and is
/// idempotent, so a platform host can release its observer during deterministic teardown without racing a wake.
public final class ThumbnailFeedWakeRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?

    fileprivate init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    /// Remove only this observer. Calling `end()` more than once has no effect.
    public func end() {
        let action = lock.withLock {
            defer { cancel = nil }
            return cancel
        }
        action?()
    }

    deinit { end() }
}

public final class FileThumbnailCoverageCheckpointStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let directory: URL
    private let scope: String
    private let tokenScope: String
    private let lock = NSLock()
    private var loaded: [String: Set<String>] = [:]

    public init(directory: URL, scope: String) {
        self.directory = directory
        self.scope = Self.safeComponent(scope)
        self.tokenScope = scope
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock {
            let pathKey = scopedKey(key)
            let fileURL = url(for: pathKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                loaded[pathKey] = []
                return []
            }
            let tokens: Set<String>
            if let cached = loaded[pathKey] {
                tokens = cached
            } else {
                let state = read(from: fileURL)
                tokens = state.tokens
                loaded[pathKey] = tokens
                let redundantHistory = state.lineCount > max(1_024, tokens.count * 2)
                if redundantHistory {
                    writeSnapshot(tokens, to: fileURL)
                }
            }
            return Set(candidates.filter { tokens.contains(token(for: $0, key: key)) })
        }
    }

    public func recordPresent(_ uids: [PhotoUID], for key: String) {
        record(uids, key: key, present: true)
    }

    public func recordMissing(_ uids: [PhotoUID], for key: String) {
        record(uids, key: key, present: false)
    }

    private func record(_ uids: [PhotoUID], key: String, present: Bool) {
        guard !uids.isEmpty else { return }
        lock.withLock {
            let pathKey = scopedKey(key)
            let fileURL = url(for: pathKey)
            let state =
                loaded[pathKey].map {
                    ReadState(tokens: $0, lineCount: $0.count)
                } ?? read(from: fileURL)
            var known = state.tokens
            let changed: [String]
            if present {
                changed = uids.map { token(for: $0, key: key) }.filter { known.insert($0).inserted }
            } else {
                changed = uids.map { token(for: $0, key: key) }.filter { known.remove($0) != nil }
            }
            guard !changed.isEmpty else {
                loaded[pathKey] = known
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lines = changed.map { Self.line(for: $0, present: present) }.joined()
            if let data = lines.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                    let handle = try? FileHandle(forWritingTo: fileURL)
                {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } catch {
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
            loaded[pathKey] = known
        }
    }

    private func scopedKey(_ key: String) -> String {
        "\(scope)-\(Self.safeComponent(key))"
    }

    private func url(for scopedKey: String) -> URL {
        directory.appendingPathComponent(scopedKey).appendingPathExtension("log")
    }

    private struct ReadState {
        var tokens: Set<String>
        var lineCount: Int
    }

    private func read(from url: URL) -> ReadState {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            return ReadState(tokens: [], lineCount: 0)
        }
        var tokens: Set<String> = []
        var lineCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            lineCount += 1
            guard parts.count == 2, parts[0] == "H" || parts[0] == "M" else { continue }
            let token = String(parts[1])
            if parts[0] == "H" { tokens.insert(token) } else { tokens.remove(token) }
        }
        return ReadState(tokens: tokens, lineCount: lineCount)
    }

    private static func line(for token: String, present: Bool) -> String {
        "\(present ? "H" : "M")\t\(token)\n"
    }

    private func writeSnapshot(_ tokens: Set<String>, to url: URL) {
        let text = tokens.sorted().map { Self.line(for: $0, present: true) }.joined()
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func token(for uid: PhotoUID, key: String) -> String {
        let material = "\(tokenScope)\u{1f}\(key)\u{1f}\(uid.volumeID)\u{1f}\(uid.nodeID)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return Self.lowercaseHex(digest)
    }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    private static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return String(cleaned.prefix(180))
    }
}

/// Universal thumbnail pipeline core.
///
/// Owns platform-independent feed behavior: disk/network decisions, priority ordering, background crawl,
/// adaptive download concurrency, decoded `CGImage` residency, and diagnostics. Platform targets adapt
/// `DecodedThumbnail` to their presentation image type outside this module.
public actor ThumbnailFeedCore {
    private struct PriorityReservation: Sendable {
        let uid: PhotoUID
        var priority: ThumbnailPriority
        let generation: UInt64
    }

    private nonisolated let cache: ThumbnailCache
    private nonisolated let loader: ThumbnailBatchLoader
    private nonisolated let onDecoded: @Sendable (PhotoUID, DecodedThumbnail) -> Void
    private nonisolated let decoded: DecodedThumbnailCache
    private nonisolated let diskPresence = DiskPresenceCache()
    private nonisolated let configuration: ThumbnailFeedCoreConfiguration
    private nonisolated let coverageStore: (any ThumbnailCoverageCheckpointStore)?
    private nonisolated let diagnostics: PhotoDiagnostics

    private var priority: [PhotoUID] = []
    private var priorityByUID: [PhotoUID: ThumbnailPriority] = [:]
    /// Priority items removed from the queue while their disk presence or network load is in flight. A crawl
    /// restart restores these before cancelling the old generation, so first-visible work cannot disappear.
    private var priorityReservations: [PriorityReservation] = []
    private var sequential: [PhotoUID] = []
    private var sequentialIndex = 0
    private var workersRunning = false
    private var workerTask: Task<Void, Never>?
    /// The fixed crawl workers are retained separately so restart/teardown can cancel each task directly.
    /// `workerTask` aggregates their completion and remains the single join handle.
    private var workerTasks: [Task<Void, Never>] = []
    /// Cancelled workers retained until an explicit owner teardown joins them. Ordinary cache clears
    /// stay generation-fenced and non-blocking, while retry/sign-out can establish a hard ownership boundary.
    private var retiredWorkerTasks: [Task<Void, Never>] = []
    /// Explicit user interaction (scroll/pinch/drag), separate from viewport warm requests. Stored
    /// outside actor isolation so shared workload governors can make a synchronous scheduling decision.
    private nonisolated let interactionState = InteractionStateBox()
    private var decodeInFlight = 0
    /// Feed-wide admission for decrypt + image decode. The actual blocking Foundation/CryptoKit/ImageIO work
    /// runs on `decodeExecutor`, never on Swift's cooperative executor.
    private let decodePermits: DecodePermitPool
    private let decodeExecutor: ThumbnailDecodeWorkExecutor
    /// A lock-backed latest-value ingress lets AppKit publish every viewport synchronously without creating
    /// one unstructured actor task per display tick. Exactly one actor drain is scheduled at a time; skipped
    /// intermediate generations were never visible long enough to deserve disk work.
    private nonisolated let visibleDiskDemandInbox = LatestVisibleDecodeDemandInbox()
    /// One long-lived latest-demand queue serves moving viewports. Replacing the viewport drops only pending
    /// stale work; already-running synchronous reads finish in their existing lanes and workers then pull from
    /// the newest generation. This prevents cancelled per-viewport task groups from accumulating blockers.
    private var visibleDiskDemand = LatestVisibleDecodeDemand()
    private var visibleDiskWorkerCount = 0
    /// Reserved crawl/priority candidates whose encrypted presence is being checked off actor. Coverage cannot
    /// be declared settled until these reservations return, even if their source queues are already empty.
    private var diskProbeBatchesInFlight = 0
    private var downloadInFlight = 0
    private var lastErrors: [String] = []
    private var prefetchEnabled = true
    private var prefetchPaused = false
    private let coverageCheckpointKey = "thumbnail-coverage-v1"
    private var checkpointPresent: Set<PhotoUID> = []
    /// Persisted coverage is an advisory write-suppression hint only. It never skips the first authenticated
    /// probe of a fresh crawl; `checkpointPresent` contains only hits returned by the current probe executor.
    private var checkpointHints: Set<PhotoUID> = []
    /// Forces one authenticated probe for every UID in a fresh crawl before normal validated-presence fast paths
    /// resume. This protects startup against a corrupted blob whose filename remains in the in-process proof set.
    private var startupAuthenticationPending = false
    /// Coalesces durable coverage updates so a first crawl does not open the checkpoint file once per tiny
    /// network batch. Losing the final unflushed block on process termination is safe: blobs remain on disk and
    /// are verified again on the next crawl.
    private var pendingCheckpointUpdates: [PhotoUID: Bool] = [:]
    private static let checkpointFlushThreshold = 128
    /// Invalidates asynchronous checkpoint bootstraps and worker groups across timeline/account changes.
    private var prefetchGeneration: UInt64 = 0
    private var prefetchCompleted = 0
    private var prefetchFailed = 0
    private var prefetchFailedTimeout = 0
    private var prefetchFailedBatchError = 0
    private var prefetchFailedItemError = 0
    private var prefetchFailedUnreported = 0
    private var prefetchDiskHit = 0
    private var prefetchDownloadStarted = 0
    private var prefetchDownloadCompleted = 0
    private var prefetchDecodeStarted = 0
    private var prefetchDecodeCompleted = 0
    /// UIDs whose thumbnail the backend refused per item (e.g. "no thumbnail"). Quarantined so the
    /// crawl doesn't re-request them every batch; cleared by `startPrefetch` so a fresh crawl
    /// (new session, timeline refresh) retries them exactly once.
    private nonisolated let unfetchable = UnfetchableThumbnailBox()
    private var skippedUnfetchable = 0
    private var lastRepassPercent = -1.0
    /// Cursor + one-shot completion flag for the bounded end-of-crawl disk-coverage re-scan
    /// (`advanceDiskCoverageScan`). Reset per crawl in `startPrefetch`.
    private var coverageScanCursor = 0
    private var coverageSettled = false
    /// Single-flight guard for `runCoverageRefresh`; only one worker refreshes coverage at a time.
    private var coverageRefreshInFlight = false
    private var coverageRefreshStarts = 0
    /// How many coverage refreshes ran an actual chunked `cache.has` sweep instead of settling from known state.
    private var coverageFullScans = 0
    /// Mirrors the cache session generation so account changes invalidate presence knowledge, while ordinary
    /// crawl starts retain the UID-keyed values for overlapping timeline items.
    private var diskPresenceGeneration: CacheWriterGeneration.Token
    /// Stable lease for this feed owner. A feed created for account A must fail closed after the shared cache
    /// is configured for account B, including late RAM decode publication.
    private nonisolated let ownerSessionLease: CacheWriterGeneration.SessionToken
    private var targetConcurrency = 2
    private var activeDownloaders = 0
    /// SDK thumbnail enumeration cannot currently be cancelled through its public facade. Timed-out loader
    /// tasks therefore continue to occupy a concurrency slot until they actually return, preventing an
    /// unbounded accumulation of hidden network/crypto work during an outage.
    private var timedOutLoaders = 0
    /// Completion trackers for timed-out SDK loaders. Owner teardown joins these tasks before it releases
    /// the backend, even when the SDK operation ignored the crawl worker's cancellation.
    private var timedOutLoaderTasks: [UUID: Task<Void, Never>] = [:]
    private var nextDirectDecodeFlightID: UInt64 = 0
    private var directDecodeFlights: [PhotoUID: DirectDecodeFlight] = [:]
    /// Direct visible loads became feed-owned when exact-UID requests were coalesced. Retain cancelled flights
    /// until teardown joins them, just like cancellation-ignoring crawl loaders.
    private var retiredDirectDecodeTasks: [Task<DecodedThumbnail?, Never>] = []
    private var aimdSuccessStreak = 0
    #if DEBUG
        private var lastPrefetchSummaryAt: Date?
        private var lastPrefetchSummaryWasActive = false
        private var lastPrefetchSummaryPausedReason: String?
    #endif

    private nonisolated let clock: @Sendable () -> Date
    /// Last visible-demand timestamp. Held in a `nonisolated`, lock-guarded box (not actor state) so
    /// `noteVisibleDemand` can record demand without queuing behind the crawl on the serial actor - the crawl
    /// workers read it `nonisolated` too, so they back off the instant a viewport goes live even while one of
    /// them is mid-scan. If this were actor state the demand signal would starve on the same queue as the
    /// `warmDecoded` it is meant to unblock (the cold-start bug).
    private nonisolated let lastDemand = LastDemandBox()
    private var crawlBackoffUntil: Date?

    /// Fired (on the feed actor) after a thumbnail becomes usable while a viewport is live - the "images
    /// available" signal grid hosts subscribe to so they redraw without needing a scroll nudge. Background
    /// downloads first land bytes on disk; visible disk decodes also use this wake once their image enters RAM.
    /// This is the platform-neutral analogue of the macOS `MetalGridDataSource.onImagesAvailable` wake: the
    /// crawl worker stores network arrivals to disk only, so without this signal a host that has gone idle (or
    /// whose visible warm set is unchanged) never learns the bytes arrived. Each platform host owns one token.
    private nonisolated let imagesAvailableWake = ImagesAvailableWakeBox()
    #if DEBUG
        /// Deterministic test-only gate for a disk probe. It is absent from release builds.
        private nonisolated let testingHooks = ThumbnailFeedCoreTestingHooks()
    #endif

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        configuration: ThumbnailFeedCoreConfiguration = ThumbnailFeedCoreConfiguration(),
        coverageStore: (any ThumbnailCoverageCheckpointStore)? = nil,
        diagnostics: PhotoDiagnostics = .shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        onDecoded: @escaping @Sendable (PhotoUID, DecodedThumbnail) -> Void = { _, _ in }
    ) {
        self.cache = cache
        self.loader = loader
        self.configuration = configuration
        self.coverageStore = coverageStore
        self.diagnostics = diagnostics
        self.clock = clock
        self.onDecoded = onDecoded
        self.decoded = DecodedThumbnailCache(costLimit: configuration.decodedMemoryBudgetBytes)
        self.decodePermits = DecodePermitPool(permits: configuration.maxConcurrentDecodes)
        self.decodeExecutor = ThumbnailDecodeWorkExecutor()
        let leases = cache.captureLeases()
        self.ownerSessionLease = leases.session
        self.diskPresenceGeneration = leases.writer
        targetConcurrency = configuration.initialDownloadConcurrency
    }

    private nonisolated func ownerLeaseIsCurrent() -> Bool {
        cache.isCurrentSessionLease(ownerSessionLease)
    }

    /// Subscribe to the "images available" arrival wake (see `onImagesAvailable`). The callback fires on the feed
    /// actor whenever a thumbnail becomes available while a viewport is recently live; the host hops to its own
    /// actor and redraws / re-warms. Registration is synchronous with respect to the nonisolated wake box, so a
    /// first visible viewport cannot miss a tiny cached arrival while an actor task is still queued.
    @discardableResult
    public func setOnImagesAvailable(_ callback: (@Sendable () -> Void)?) -> ThumbnailFeedWakeRegistration {
        guard let callback else { return ThumbnailFeedWakeRegistration(cancel: {}) }
        return imagesAvailableWake.add(callback)
    }

    /// Nonisolated adapter for platform hosts. The wake itself is owned by `ThumbnailFeedCore`; AppKit/UIKit
    /// facades expose only `feedCore`, then subscribe through this shared entry point instead of carrying
    /// duplicate fire-and-forget actor-hop code. The returned token removes only this subscriber.
    @discardableResult
    public nonisolated func setOnImagesAvailableWake(
        _ callback: @escaping @Sendable () -> Void
    ) -> ThumbnailFeedWakeRegistration {
        imagesAvailableWake.add(callback)
    }

    /// A generous "a live viewport is (or was very recently) waiting on content" gate for the arrival wake: wide
    /// enough to span a slow network delivery (bounded by the download timeout), so a tile that lands seconds
    /// after its warm still wakes the grid, yet closed when no viewport has demanded anything recently, so a
    /// purely background crawl (user not looking) never spins the host's display loop.
    private nonisolated func hostArrivalWakeIsLive(now: Date) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return now.timeIntervalSince(last) < configuration.downloadTimeoutSeconds + 5
    }

    /// Governor-driven memory-pressure response for the decoded-thumbnail RAM tier. `scale` lowers the
    /// cost budget (evicting LRU entries down to it); `purge` drops everything held now (the UIKit
    /// `didReceiveMemoryWarning` / critical semantic). `nonisolated` + internally lock-guarded, so the
    /// governor calls it without hopping the feed actor (never blocks visible-tile decodes). Restoring
    /// `scale: 1.0, purge: false` returns the full budget. The disk tier is untouched - nothing is lost,
    /// only re-decoded on demand.
    public nonisolated func applyDecodedMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        decoded.setCostLimit(max(1, Int(Double(configuration.decodedMemoryBudgetBytes) * clamped)))
        if purge { decoded.removeAll() }
    }

    public func cachedDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        if let cached = decoded.image(for: uid) {
            diagnostics.increment("thumb.ramDecodedHit")
            return cached
        }
        diagnostics.increment("thumb.ramDecodeMiss")
        diagnostics.recordDiskReadDuringPinch()
        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        let maxPixels = configuration.targetPixels
        let result = await decodeExecutor.perform(priority: .visibleNow) { () -> (Bool, DecodedThumbnail?) in
            guard let data = cache.diskData(for: uid) else { return (false, nil) }
            return (true, ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels))
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return nil
        }
        if result.0 {
            diskPresence.set(uid, present: true)
            diagnostics.increment("thumb.diskCacheHit")
            guard let image = result.1 else {
                diagnostics.increment("thumb.diskDecodeFailed")
                recordError("decode failed for \(Self.key(uid))")
                return nil
            }
            storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels))
            return image
        }
        diskPresence.set(uid, present: false)
        diagnostics.increment("thumb.diskCacheMiss")
        return nil
    }

    /// Cache-only decode for low-priority consumers such as local ML indexing.
    ///
    /// Disk I/O, decryption and image decode run away from the serial feed actor, so indexing
    /// cannot delay visible-grid scheduling. One-shot ML decodes do not enter the grid's decoded
    /// LRU or emit redraw callbacks. A miss never starts a network request; the caller can retry
    /// after the normal thumbnail crawl has populated the encrypted disk tier.
    public nonisolated func backgroundCachedDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard case .decoded(let image) = await backgroundThumbnailDecodeResult(for: uid) else { return nil }
        return image
    }

    /// Detailed cache-only result for background consumers that must distinguish a thumbnail
    /// that may still arrive from bytes that are present but cannot be decoded.
    public nonisolated func backgroundThumbnailDecodeResult(for uid: PhotoUID) async -> BackgroundThumbnailDecodeResult
    {
        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        if let image = decoded.image(for: uid) {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            return .decoded(image)
        }

        let maxPixels = configuration.targetPixels
        let result = await Task.detached(priority: .utility) { () -> (dataPresent: Bool, image: DecodedThumbnail?) in
            guard let data = cache.diskData(for: uid) else { return (false, nil) }
            return (true, ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels))
        }.value
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard result.dataPresent else {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            diskPresence.set(uid, present: false)
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            return .missing
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        diskPresence.set(uid, present: true)
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard let image = result.image else {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            return .undecodable
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        return .decoded(image)
    }

    public nonisolated func memoryDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        return decoded.image(for: uid)
    }

    /// True when the RAM tier holds this UID but at a decode cap materially below `pixels` - i.e. a warm
    /// at `pixels` would actually produce a sharper image. False when the entry is absent (that is the
    /// ordinary missing-tile path) or already adequate, so a settled render loop that keys retry work on
    /// this can never spin on a source-limited image.
    public nonisolated func decodedNeedsSharperSource(_ uid: PhotoUID, forPixels pixels: Int) -> Bool {
        guard ownerLeaseIsCurrent() else { return false }
        return decoded.needsSharperDecode(for: uid, requestedPixels: pixels)
    }

    /// Ordinary warm consumers retain the configured decode target as their floor. `0` means no size opinion.
    private func effectiveDecodePixels(for request: ThumbnailRequest) -> CGFloat {
        guard request.pixelSize > 0 else { return configuration.targetPixels }
        return max(CGFloat(request.pixelSize), configuration.targetPixels)
    }

    /// The latest viewport owns its measured upload size, avoiding a larger transient RAM decode.
    private func visibleDecodePixels(for request: ThumbnailRequest) -> CGFloat {
        request.pixelSize > 0 ? max(1, CGFloat(request.pixelSize)) : configuration.targetPixels
    }

    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
        unfetchable.contains(uid)
    }

    public func cacheState(
        for request: ThumbnailRequest, gpuTextureResident: Bool = false
    ) async -> ThumbnailCacheTierState {
        guard ownerLeaseIsCurrent() else {
            return ThumbnailCacheTierState(
                knownInTimeline: true,
                diskThumbnail: false,
                ramDecoded: false,
                gpuTexture: gpuTextureResident
            )
        }
        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        let diskThumbnail = await decodeExecutor.perform(priority: .idleLibraryCrawl) {
            cache.hasUsableDiskData(request.uid)
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            return ThumbnailCacheTierState(
                knownInTimeline: true,
                diskThumbnail: false,
                ramDecoded: false,
                gpuTexture: gpuTextureResident
            )
        }
        diskPresence.set(request.uid, present: diskThumbnail)
        return ThumbnailCacheTierState(
            knownInTimeline: true,
            diskThumbnail: diskThumbnail,
            ramDecoded: decoded.contains(request.uid),
            gpuTexture: gpuTextureResident
        )
    }

    /// Returns true when this UID is queued already or was queued now. The worker validates encrypted disk
    /// presence away from this actor before crossing the network boundary; admission itself must stay O(1),
    /// because a first-time cache validation performs a real file read and AES-GCM open.
    @discardableResult
    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) -> Bool {
        if requestedPriority != .idleLibraryCrawl { lastDemand.set(clock()) }
        if let index = priorityReservations.firstIndex(where: { $0.uid == uid }) {
            if requestedPriority < priorityReservations[index].priority {
                priorityReservations[index].priority = requestedPriority
                diagnostics.increment("thumb.priorityUpgrade")
            }
            return true
        }
        if let existing = priorityByUID[uid] {
            if requestedPriority < existing {
                priorityByUID[uid] = requestedPriority
                diagnostics.increment("thumb.priorityUpgrade")
            }
            return true
        }
        priority.append(uid)
        priorityByUID[uid] = requestedPriority
        trimPriorityQueueIfNeeded()
        startWorkers()
        return true
    }

    /// Replace the queued network demand owned by the live grid viewport.
    ///
    /// The list is ordered in viewport priority (the newly exposed edge first). Replacing, rather than merely
    /// appending, is important during a fast scroll: old `.visibleNow` entries must not remain tied with the new
    /// viewport, and an off-screen scroll-ahead corridor must not keep consuming admissions after its cells have
    /// been skipped. Requests already inside the SDK cannot be recalled; this only removes work that has not
    /// crossed the network admission boundary.
    @discardableResult
    public func replaceVisiblePriorityDemand(_ orderedUIDs: [PhotoUID]) -> Int {
        lastDemand.set(clock())
        removeQueuedPriorities([.visibleNow, .nearViewportScrollAhead])

        var seen = Set<PhotoUID>()
        var queued = 0
        for uid in orderedUIDs where seen.insert(uid).inserted {
            if requestPriority(uid, priority: .visibleNow) { queued += 1 }
        }
        return queued
    }

    public nonisolated func hasRecentVisibleDemand(within: TimeInterval = 2.0) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return clock().timeIntervalSince(last) < within
    }

    /// Records that a viewport is live without enqueuing or decoding anything - a single lock-guarded clock
    /// write, `nonisolated` so it never queues on the serial actor. The per-frame warm path calls this the
    /// instant the first visible cells are known, so the background crawl's `recentDemand` gate (`takeBatch` /
    /// the end-of-list coverage re-scan) backs its filesystem scanning off immediately and yields the actor to
    /// the visible decode - instead of the crawl only learning of demand once `warmDecoded` itself reaches the
    /// actor, the very call the crawl is starving on a cold start.
    public nonisolated func noteVisibleDemand() {
        lastDemand.set(clock())
    }

    public func hasPendingThumbnailWork() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || sequentialIndex < sequential.count
    }

    /// True only while the grid needs the backend: queued visible-priority work or live viewport demand.
    /// Unlike `hasPendingThumbnailWork()`, this excludes the whole-library
    /// sequential fill: lower-priority background work (the Map's GPS crawl) yields on this, so it backs
    /// off while the user scrolls but is not parked until a full-library thumbnail crawl finishes.
    public func hasVisibleThumbnailPressure() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || hasRecentVisibleDemand()
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        await warmDecodedImpl(
            requests,
            priority: requestedPriority,
            limit: limit
        )
    }

    /// Publishes the moving viewport through a latest-value mailbox. This is deliberately `nonisolated`: a
    /// scrolling host must never queue hundreds of obsolete actor messages while disk maintenance is yielding.
    /// Network admission remains a separate stable-viewport operation.
    public nonisolated func submitVisibleDiskDecodeDemand(
        _ requests: [ThumbnailRequest]
    ) {
        lastDemand.set(clock())
        guard visibleDiskDemandInbox.submit(requests: requests) else { return }
        Task { await drainVisibleDiskDemandInbox() }
    }

    private func drainVisibleDiskDemandInbox() {
        while let submission = visibleDiskDemandInbox.takeLatestOrFinish() {
            applyVisibleDiskDecodeDemand(submission.requests, generation: submission.generation)
        }
    }

    private func applyVisibleDiskDecodeDemand(
        _ requests: [ThumbnailRequest],
        generation: UInt64
    ) {
        var seen = Set<PhotoUID>()
        let jobs = requests.compactMap { request -> LatestVisibleDecodeDemand.Job? in
            guard seen.insert(request.uid).inserted else { return nil }
            let pixels = visibleDecodePixels(for: request)
            guard !decoded.hasAdequateEntry(for: request.uid, requestedPixels: Int(pixels)) else { return nil }
            return LatestVisibleDecodeDemand.Job(
                uid: request.uid, maxPixels: pixels, isUpgrade: decoded.contains(request.uid))
        }
        guard visibleDiskDemand.replace(with: jobs, generation: generation) else {
            return
        }
        diagnostics.emitDebug(
            "ThumbSchedule",
            [
                "action": "replaceDiskDemand",
                "generation": "\(generation)",
                "requested": "\(requests.count)",
                "pending": "\(visibleDiskDemand.pendingCount)",
                "active": "\(visibleDiskDemand.activeCount)",
            ], throttleSeconds: 0.10, throttleKey: "replaceDiskDemand")
        startVisibleDiskWorkersIfNeeded()
    }

    private func startVisibleDiskWorkersIfNeeded() {
        let desired = min(configuration.maxConcurrentDecodes, visibleDiskDemand.pendingCount)
        while visibleDiskWorkerCount < desired {
            visibleDiskWorkerCount += 1
            Task { [weak self] in
                await self?.runVisibleDiskWorker()
            }
        }
    }

    private func runVisibleDiskWorker() async {
        while let job = visibleDiskDemand.takeNext() {
            guard await decodePermits.acquire(priority: .visibleNow) else {
                // `false` means this worker was cancelled before it acquired a lane. The asset was not read,
                // so it must remain pending if it still belongs to the latest viewport generation.
                visibleDiskDemand.returnToPending(job)
                break
            }
            let cache = self.cache
            let generation = cache.captureWriterGeneration()
            let executor = decodeExecutor
            let tile = await executor.perform(priority: .visibleNow) {
                Self.decodeTile(
                    cache: cache,
                    uid: job.uid,
                    maxPixels: job.maxPixels,
                    isUpgrade: job.isUpgrade
                )
            }
            await decodePermits.release()
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                visibleDiskDemand.complete(job)
                continue
            }
            publishVisibleDiskTile(tile, generation: generation)
            visibleDiskDemand.complete(job)
        }
        visibleDiskWorkerCount = max(0, visibleDiskWorkerCount - 1)
        startVisibleDiskWorkersIfNeeded()
    }

    private func publishVisibleDiskTile(_ tile: DecodedTile, generation: CacheWriterGeneration.Token) {
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return
        }
        recordSlowDecodeStages(tile)
        diagnostics.increment("thumb.ramDecodeMiss")
        guard tile.diskHadData else {
            diskPresence.set(tile.uid, present: false)
            recordCheckpointMissing([tile.uid], writerGeneration: generation)
            return
        }
        diskPresence.set(tile.uid, present: true)
        diagnostics.increment("thumb.diskCacheHit")
        prefetchDecodeStarted += 1
        diagnostics.recordDecodeStarted(queueDepth: visibleDiskDemand.pendingCount)
        guard let image = tile.decoded else {
            diagnostics.increment("thumb.diskDecodeFailed")
            diagnostics.recordDecodeFailed(queueDepth: visibleDiskDemand.pendingCount)
            recordError("decode failed for \(Self.key(tile.uid))")
            return
        }
        storeDecoded(image, for: tile.uid, decodePixelCap: tile.decodePixelCap)
        notifyHostOfAvailableImageIfVisible()
        if tile.isUpgrade { diagnostics.increment("thumb.decodedUpgrade") }
        prefetchDecodeCompleted += 1
        diagnostics.recordDecodeCompleted(
            durationMs: tile.durationMs,
            queueDepth: visibleDiskDemand.pendingCount
        )
    }

    private func warmDecodedImpl(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        let targets = Array(requests.prefix(max(0, limit)))
        lastDemand.set(clock())
        var alreadyDecoded = 0
        var decodedFromDisk = 0
        var queuedNetwork = 0
        var missing = 0
        let mainThreadDecodeCount = 0
        guard ownerLeaseIsCurrent() else {
            return WarmDecodedResult(
                requested: targets.count,
                alreadyDecoded: 0,
                decodedFromDisk: 0,
                queuedNetwork: 0,
                missing: 0,
                mainThreadDecodeCount: mainThreadDecodeCount
            )
        }
        guard !Task.isCancelled else {
            return WarmDecodedResult(
                requested: targets.count,
                alreadyDecoded: 0,
                decodedFromDisk: 0,
                queuedNetwork: 0,
                missing: 0,
                mainThreadDecodeCount: mainThreadDecodeCount
            )
        }
        var needDecode: [(uid: PhotoUID, pixels: CGFloat, isUpgrade: Bool)] = []
        needDecode.reserveCapacity(targets.count)
        for request in targets {
            // Size-aware skip: "already decoded" only counts when the cached entry's decode cap is adequate
            // for this request (shared `ThumbnailDecodeUpgradePolicy` hysteresis). A materially larger ask
            // re-decodes the same UID sharper, in place - this is what lets a zoomed-in grid level sharpen
            // tiles that were first decoded for a denser level.
            let pixels = effectiveDecodePixels(for: request)
            if decoded.hasAdequateEntry(for: request.uid, requestedPixels: Int(pixels)) {
                diagnostics.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
            } else {
                needDecode.append((request.uid, pixels, decoded.contains(request.uid)))
            }
        }
        if !needDecode.isEmpty {
            let cache = self.cache
            let decodeGeneration = cache.captureWriterGeneration()
            let decodePermits = self.decodePermits
            let decodeExecutor = self.decodeExecutor
            let lanes = max(1, min(needDecode.count, configuration.maxConcurrentDecodes))
            await withTaskGroup(of: DecodedTile?.self) { group in
                var iterator = needDecode.makeIterator()
                func addNext() {
                    guard !Task.isCancelled else { return }
                    guard let (uid, maxPixels, isUpgrade) = iterator.next() else { return }
                    group.addTask {
                        guard await decodePermits.acquire(priority: requestedPriority) else { return nil }
                        guard !Task.isCancelled else {
                            await decodePermits.release()
                            return nil
                        }
                        let tile = await decodeExecutor.perform(priority: requestedPriority) {
                            Self.decodeTile(cache: cache, uid: uid, maxPixels: maxPixels, isUpgrade: isUpgrade)
                        }
                        await decodePermits.release()
                        return Task.isCancelled ? nil : tile
                    }
                }
                for _ in 0..<lanes { addNext() }
                for await tile in group {
                    if Task.isCancelled || !ownerLeaseIsCurrent() || !cache.isCurrentWriterGeneration(decodeGeneration)
                    {
                        group.cancelAll()
                        continue
                    }
                    if let tile {
                        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(decodeGeneration) else {
                            group.cancelAll()
                            continue
                        }
                        recordSlowDecodeStages(tile)
                        diagnostics.increment("thumb.ramDecodeMiss")
                        if tile.diskHadData {
                            diskPresence.set(tile.uid, present: true)
                            diagnostics.increment("thumb.diskCacheHit")
                            prefetchDecodeStarted += 1
                            diagnostics.recordDecodeStarted(queueDepth: 0)
                            if let image = tile.decoded {
                                // Publish each completed decode immediately. Waiting for the slowest member of
                                // a large visible batch made every already-finished tile remain a placeholder,
                                // which surfaced most often on macOS because its decode policy uses more lanes.
                                storeDecoded(image, for: tile.uid, decodePixelCap: tile.decodePixelCap)
                                notifyHostOfAvailableImageIfVisible()
                                if tile.isUpgrade { diagnostics.increment("thumb.decodedUpgrade") }
                                prefetchDecodeCompleted += 1
                                diagnostics.recordDecodeCompleted(durationMs: tile.durationMs, queueDepth: 0)
                                decodedFromDisk += 1
                            } else {
                                missing += 1
                                diagnostics.increment("thumb.diskDecodeFailed")
                                diagnostics.recordDecodeFailed(queueDepth: 0)
                                recordError("decode failed for \(Self.key(tile.uid))")
                            }
                        } else {
                            // Admission is O(1); the worker revalidates encrypted disk presence off actor
                            // before it crosses the network boundary, covering a byte arrival in this race.
                            requestPriority(tile.uid, priority: requestedPriority)
                            queuedNetwork += 1
                        }
                    }
                    addNext()
                }
            }
        }
        return WarmDecodedResult(
            requested: targets.count,
            alreadyDecoded: alreadyDecoded,
            decodedFromDisk: decodedFromDisk,
            queuedNetwork: queuedNetwork,
            missing: missing,
            mainThreadDecodeCount: mainThreadDecodeCount
        )
    }

    /// Decode or enqueue the current on-screen viewport at the highest thumbnail priority.
    ///
    /// The priority is deliberately not configurable here. Platform grids report visibility; they do not
    /// decide how visible work competes with zoom targets, scroll-ahead preparation, or the library crawl.
    public func warmVisibleDecoded(
        _ requests: [ThumbnailRequest],
        limit: Int
    ) async -> WarmDecodedResult {
        await warmDecoded(requests, priority: .visibleNow, limit: limit)
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await warmDecoded(
            uids.map { ThumbnailRequest(uid: $0, pixelSize: Int(configuration.targetPixels)) },
            priority: .zoomAnchorAndFocusRow,
            limit: limit
        )
    }

    public func decoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        if let image = await cachedDecoded(for: uid) { return image }
        // Visible tiles re-request on every appearance; once the backend has said "no thumbnail"
        // for this crawl, don't burn a network round-trip per visibility.
        if unfetchable.contains(uid) {
            diagnostics.increment("thumb.unfetchableShortCircuit")
            return nil
        }
        if let flight = directDecodeFlights[uid] {
            return await flight.task.value
        }

        nextDirectDecodeFlightID &+= 1
        let flightID = nextDirectDecodeFlightID
        let flight: Task<DecodedThumbnail?, Never> = Task { [weak self] in
            guard let self else { return nil }
            return await self.loadDirectDecoded(for: uid)
        }
        directDecodeFlights[uid] = DirectDecodeFlight(id: flightID, task: flight)
        let result = await flight.value
        if directDecodeFlights[uid]?.id == flightID {
            directDecodeFlights.removeValue(forKey: uid)
        }
        return result
    }

    private func loadDirectDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        let box = ByteBox()
        let cache = self.cache
        let writerGeneration = cache.captureWriterGeneration()
        guard cache.isCurrentWriterGeneration(writerGeneration) else { return nil }
        diagnostics.recordNetworkRequestDuringPinch()
        let result: ThumbnailBatchLoadResult
        if let priorityLoader = loader as? any PriorityThumbnailBatchLoader {
            result = await priorityLoader.loadThumbnails(for: [uid], priority: .visibleNow) { loadedUID, data in
                if loadedUID == uid { box.set(data) }
            }
        } else {
            result = await loader.loadThumbnails(for: [uid]) { loadedUID, data in
                if loadedUID == uid { box.set(data) }
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            decoded.removeAll()
            return nil
        }
        guard let data = box.value else {
            if let reason = result.itemErrors[uid] {
                unfetchable.insert(uid)
                recordError("thumbnail refused for \(Self.key(uid)): \(reason)")
            } else if let reason = result.batchError {
                recordError("thumbnail fetch failed for \(Self.key(uid)): \(reason)")
            }
            return nil
        }
        let maxPixels = configuration.targetPixels
        let image: DecodedThumbnail? = await decodeExecutor.perform(priority: .visibleNow) { () -> DecodedThumbnail? in
            guard cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration) == .stored else { return nil }
            return ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            decoded.removeAll()
            return nil
        }
        diskPresence.set(uid, present: true)
        guard let image else {
            diagnostics.increment("thumb.diskDecodeFailed")
            recordError("decode failed for \(Self.key(uid))")
            return nil
        }
        storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels))
        return image
    }

    public func startPrefetch(_ uids: [PhotoUID]) async {
        guard prefetchEnabled, ownerLeaseIsCurrent() else { return }
        flushCheckpointUpdates()
        restorePriorityReservationsForRestart()
        prefetchGeneration &+= 1
        let generation = prefetchGeneration
        let activeWorker = workerTask
        workerTasks.forEach { $0.cancel() }
        workerTasks.removeAll(keepingCapacity: false)
        activeWorker?.cancel()
        if let activeWorker {
            retiredWorkerTasks.append(activeWorker)
        }
        workerTask = nil
        workersRunning = false
        sequential = uids
        sequentialIndex = 0

        // Coverage-log parsing and cache-directory enumeration are local I/O. Keep them off the
        // serial feed actor so first-visible disk decrypt/decode can run immediately after login.
        let coverageStore = self.coverageStore
        let coverageKey = coverageCheckpointKey
        let cache = self.cache
        let cacheGeneration = cache.captureWriterGeneration()
        let bootstrap = await Task.detached(priority: .utility) {
            Set(coverageStore?.loadPresent(uids, for: coverageKey) ?? [])
        }.value
        guard generation == prefetchGeneration, prefetchEnabled else { return }
        guard cache.isCurrentWriterGeneration(cacheGeneration) else { return }

        if diskPresenceGeneration != cacheGeneration {
            diskPresence.invalidate()
            diskPresenceGeneration = cacheGeneration
        }

        checkpointHints = bootstrap
        checkpointPresent.removeAll(keepingCapacity: true)
        // A persisted checkpoint is advisory only. Every UID starts at zero and crosses the bounded utility
        // probe before the crawl can skip it, so a removed or corrupt blob cannot hide behind a stale checkpoint.
        startupAuthenticationPending = !uids.isEmpty
        sequentialIndex = 0
        diskPresence.beginTracking(uids, knownPresent: [])
        unfetchable.removeAll()  // a fresh crawl retries backend-refused items exactly once
        lastRepassPercent = -1.0
        coverageScanCursor = 0
        coverageSettled = false
        coverageRefreshInFlight = false
        coverageRefreshStarts = 0
        coverageFullScans = 0
        startWorkers()
    }

    public func stopPrefetch() {
        flushCheckpointUpdates()
        prefetchGeneration &+= 1
        let activeWorker = workerTask
        workerTasks.forEach { $0.cancel() }
        workerTasks.removeAll(keepingCapacity: false)
        activeWorker?.cancel()
        if let activeWorker {
            retiredWorkerTasks.append(activeWorker)
        }
        workerTask = nil
        workersRunning = false
        priority.removeAll()
        priorityByUID.removeAll()
        priorityReservations.removeAll(keepingCapacity: false)
        sequential.removeAll()
        startupAuthenticationPending = false
        for flight in directDecodeFlights.values {
            flight.task.cancel()
            retiredDirectDecodeTasks.append(flight.task)
        }
        directDecodeFlights.removeAll(keepingCapacity: false)
    }

    /// Stops and joins every worker owned by this feed instance. Account retry and sign-out use this
    /// boundary before releasing the backend; destructive cache clear remains generation-fenced and non-blocking.
    public func stopPrefetchAndWait() async {
        stopPrefetch()
        while true {
            let retiredWorkers = retiredWorkerTasks
            retiredWorkerTasks.removeAll(keepingCapacity: false)
            for task in retiredWorkers {
                await task.value
            }

            // A worker registers a cancellation-ignoring SDK loader after its bounded timeout.
            // Read this collection after the workers finish so no late native owner escapes.
            let lateLoaders = Array(timedOutLoaderTasks.values)
            for task in lateLoaders {
                await task.value
            }

            let directLoads = retiredDirectDecodeTasks
            retiredDirectDecodeTasks.removeAll(keepingCapacity: false)
            for task in directLoads {
                _ = await task.value
            }

            guard retiredWorkerTasks.isEmpty,
                timedOutLoaderTasks.isEmpty,
                retiredDirectDecodeTasks.isEmpty
            else { continue }
            break
        }
    }

    /// Clears the encrypted thumbnail tier and its coverage state as one feed operation, then restarts the
    /// current library crawl. Stopping first prevents an old worker or checkpoint from repopulating stale
    /// coverage after the cache directory has been removed.
    public func clearCacheAndRestartPrefetch() async {
        let current = sequential
        let shouldRestart = prefetchEnabled && !current.isEmpty
        stopPrefetch()
        await cache.clear()
        checkpointPresent.removeAll()
        checkpointHints.removeAll()
        diskPresence.invalidate()
        if shouldRestart { await startPrefetch(current) }
    }

    public func setPrefetchEnabled(_ enabled: Bool) {
        prefetchEnabled = enabled
        if !enabled { stopPrefetch() }
    }

    public func pausePrefetch() {
        prefetchPaused = true
    }

    public func resumePrefetch() {
        prefetchPaused = false
        startWorkers()
    }

    public nonisolated func setUserInteractionActive(_ active: Bool) {
        interactionState.set(active)
    }

    /// True only while a platform host reports an active gesture or scroll deceleration. A visible
    /// grid and queued/missing thumbnails do not count: those may remain pending indefinitely and
    /// must not starve background indexing after the user becomes idle.
    public nonisolated func hasActiveUserInteraction() -> Bool {
        interactionState.get()
    }

    public struct PrefetchStatus: Sendable, Equatable {
        public let enabled: Bool
        public let paused: Bool
        public let diskThumbnailCoverageFraction: Double
        public let diskThumbnailTotal: Int
        public let diskCoverageVerified: Bool
        public let currentQueueLength: Int
        public let downloadsInFlight: Int
        public let decodesInFlight: Int
        public let lastErrors: [String]
        public let cacheSizeBytes: Int64
        public let diskFileCount: Int
        public let activeJobs: Int
        public let completed: Int
        public let failed: Int
        /// Classified breakdown of `failed` (their sum equals `failed`).
        public let failedTimeout: Int
        public let failedBatchError: Int
        public let failedItemError: Int
        public let failedUnreported: Int
        public let diskHit: Int
        public let downloadStarted: Int
        public let downloadCompleted: Int
        public let decodeStarted: Int
        public let decodeCompleted: Int
        /// Items currently quarantined because the backend refused them per item this crawl.
        public let unfetchableCount: Int
        public let skippedUnfetchable: Int
        public let pausedReason: String
    }

    public func prefetchStatus() -> PrefetchStatus {
        let coverage = diskPresence.coverage()
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else {
            pausedReason = "none"
        }
        return PrefetchStatus(
            enabled: prefetchEnabled,
            paused: prefetchPaused,
            diskThumbnailCoverageFraction: coverage.percent,
            diskThumbnailTotal: coverage.total,
            diskCoverageVerified: coverageSettled,
            currentQueueLength: priority.count + max(0, sequential.count - sequentialIndex),
            downloadsInFlight: downloadInFlight,
            decodesInFlight: decodeInFlight,
            lastErrors: lastErrors,
            cacheSizeBytes: 0,
            diskFileCount: coverage.present,
            activeJobs: downloadInFlight + decodeInFlight,
            completed: prefetchCompleted,
            failed: prefetchFailed,
            failedTimeout: prefetchFailedTimeout,
            failedBatchError: prefetchFailedBatchError,
            failedItemError: prefetchFailedItemError,
            failedUnreported: prefetchFailedUnreported,
            diskHit: prefetchDiskHit,
            downloadStarted: prefetchDownloadStarted,
            downloadCompleted: prefetchDownloadCompleted,
            decodeStarted: prefetchDecodeStarted,
            decodeCompleted: prefetchDecodeCompleted,
            unfetchableCount: unfetchable.count,
            skippedUnfetchable: skippedUnfetchable,
            pausedReason: pausedReason
        )
    }

    private func startWorkers() {
        guard !workersRunning else { return }
        workersRunning = true
        let generation = prefetchGeneration
        let workers: [Task<Void, Never>] = (0..<configuration.downloadConcurrencyLimit).map { _ in
            Task { [weak self] in
                guard let self else { return }
                await self.worker(generation: generation)
            }
        }
        workerTasks = workers
        workerTask = Task { [weak self, workers] in
            for worker in workers {
                await worker.value
            }
            guard let self else { return }
            await self.workersStopped(generation: generation)
        }
    }

    private func workersStopped(generation: UInt64) {
        guard generation == prefetchGeneration else { return }
        workerTasks.removeAll(keepingCapacity: false)
        workerTask = nil
        workersRunning = false
        if !priority.isEmpty || sequentialIndex < sequential.count { startWorkers() }
    }

    private func worker(generation: UInt64) async {
        while !Task.isCancelled, generation == prefetchGeneration {
            guard ownerLeaseIsCurrent() else { return }
            let work = await takeBatch()
            guard ownerLeaseIsCurrent() else { return }
            let chunk = work.uids
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count {
                    if diskProbeBatchesInFlight > 0 {
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    // Coverage is verified for this crawl; nothing remains.
                    if coverageSettled { return }
                    // Never re-scan while a viewport is actively warming (recent visible demand) - it would
                    // compete for the serial actor with the visible decode that demand represents. Idle; the
                    // scan resumes once demand quiets.
                    if recentVisibleDemand() {
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    // Single-flight: exactly one worker runs the end-of-crawl coverage refresh; the rest idle
                    // (staying available for a demand burst) rather than each scanning. Combined with the
                    // chunked, demand-aborting `runCoverageRefresh`, this means one bounded refresh per drain,
                    // never a stampede of N full-library scans on the serial actor.
                    guard !coverageRefreshInFlight else {
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    coverageRefreshInFlight = true
                    let outcome = await runCoverageRefresh()
                    coverageRefreshInFlight = false
                    switch outcome {
                    case .aborted:
                        continue  // A live viewport takes priority; retry coverage when quiet.
                    case .recrawl:
                        sequentialIndex = 0
                        coverageScanCursor = 0
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    case .settled:
                        coverageSettled = true  // Coverage is settled; stop rescanning this crawl.
                        return
                    }
                }
                // A disk-hit-only batch made real forward progress. Continue immediately: the probe already
                // ran on the utility executor and the next iteration will observe a newly arrived visible-demand
                // signal before reserving more crawl candidates. Do not delay after a disk-hit-only batch.
                if work.probedDisk { continue }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            while activeDownloaders + timedOutLoaders >= targetConcurrency, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
            }
            if Task.isCancelled { return }
            activeDownloaders += 1
            downloadInFlight += chunk.count
            prefetchDownloadStarted += chunk.count
            diagnostics.recordNetworkRequestDuringPinch()
            guard ownerLeaseIsCurrent() else { return }
            let writerGeneration = cache.captureWriterGeneration()
            let snapshot = await Self.loadBatch(
                chunk,
                loader: loader,
                cache: cache,
                diskPresence: diskPresence,
                writerGeneration: writerGeneration,
                sessionLease: ownerSessionLease,
                writeExecutor: decodeExecutor,
                writePermits: decodePermits,
                priority: work.priority,
                seconds: configuration.downloadTimeoutSeconds
            )
            activeDownloaders = max(0, activeDownloaders - 1)
            releasePriorityReservations(for: chunk, generation: generation)
            if let lateLoader = snapshot.lateLoader {
                timedOutLoaders += 1
                let taskID = UUID()
                let tracker = Task { [weak self] in
                    _ = await lateLoader.value
                    await self?.timedOutLoaderFinished(taskID: taskID, itemCount: chunk.count)
                }
                timedOutLoaderTasks[taskID] = tracker
            } else {
                downloadInFlight = max(0, downloadInFlight - chunk.count)
            }
            guard generation == prefetchGeneration, ownerLeaseIsCurrent() else { return }
            let completed = snapshot.delivered.count
            prefetchCompleted += completed
            prefetchDownloadCompleted += completed
            recordCheckpointPresent(Array(snapshot.delivered), writerGeneration: writerGeneration)
            let undelivered = chunk.filter { !snapshot.delivered.contains($0) }
            prefetchFailed += undelivered.count
            var networkSuspect = false  // batch/timeout/unreported failures point at transport, not content
            switch snapshot.resolution {
            case .timedOut:
                prefetchFailedTimeout += undelivered.count
                networkSuspect = true
                recordError(
                    "thumbnail batch timed out after \(configuration.downloadTimeoutSeconds)s (\(completed)/\(chunk.count) delivered)"
                )
            case .finished(let result):
                if let batchError = result.batchError {
                    prefetchFailedBatchError += undelivered.count
                    networkSuspect = true
                    recordError("thumbnail batch failed (\(completed)/\(chunk.count) delivered): \(batchError)")
                } else if !undelivered.isEmpty {
                    let refused = undelivered.filter { result.itemErrors[$0] != nil }
                    prefetchFailedItemError += refused.count
                    unfetchable.formUnion(refused)
                    if let first = refused.first, let reason = result.itemErrors[first] {
                        recordError(
                            "thumbnail refused for \(refused.count) item(s), e.g. \(Self.key(first)): \(reason)")
                    }
                    let unreported = undelivered.count - refused.count
                    prefetchFailedUnreported += unreported
                    if unreported > 0 {
                        networkSuspect = true
                        recordError("thumbnail batch missing \(unreported)/\(chunk.count) with no reported reason")
                    }
                }
            }
            if completed == 0, !chunk.isEmpty {
                crawlBackoffUntil = clock().addingTimeInterval(configuration.crawlBackoffSeconds)
                if networkSuspect {
                    targetConcurrency = max(configuration.minimumDownloadConcurrency, targetConcurrency / 2)
                }
                aimdSuccessStreak = 0
            } else if completed > 0 {
                aimdSuccessStreak += 1
                if aimdSuccessStreak >= 4 {
                    aimdSuccessStreak = 0
                    targetConcurrency = min(configuration.downloadConcurrencyLimit, targetConcurrency + 1)
                }
            }
            // Arrival wake: bytes just landed on disk. If a viewport is recently live, tell the host to
            // re-warm missing visible cells from disk and redraw.
            if completed > 0, hostArrivalWakeIsLive(now: clock()) {
                imagesAvailableWake.call()
            }
            emitPrefetchSummary()
        }
    }

    private enum BatchResolution: Sendable {
        case finished(ThumbnailBatchLoadResult)
        case timedOut
    }

    private struct BatchSnapshot: Sendable {
        let delivered: Set<PhotoUID>
        let resolution: BatchResolution
        let lateLoader: Task<ThumbnailBatchLoadResult, Never>?
    }

    private struct BatchWork: Sendable {
        var uids: [PhotoUID] = []
        var priority: ThumbnailPriority = .idleLibraryCrawl
        var probedDisk = false
    }

    private struct DirectDecodeFlight {
        let id: UInt64
        let task: Task<DecodedThumbnail?, Never>
    }

    private struct DiskProbe: Sendable {
        let uid: PhotoUID
        let usable: Bool
    }

    /// Runs one loader batch against a real wall-clock timeout. Cancellation is forwarded to the
    /// loader when the deadline wins. The loader task remains accounted for until it actually
    /// returns, so a cancellation-ignoring transport still cannot create unbounded hidden work.
    /// Late deliveries may land in the disk cache, but counters snapshot exactly once here: an
    /// item is either delivered-by-resolution or failed, never both.
    private nonisolated static func loadBatch(
        _ chunk: [PhotoUID],
        loader: ThumbnailBatchLoader,
        cache: ThumbnailCache,
        diskPresence: DiskPresenceCache,
        writerGeneration: CacheWriterGeneration.Token,
        sessionLease: CacheWriterGeneration.SessionToken,
        writeExecutor: ThumbnailDecodeWorkExecutor,
        writePermits: DecodePermitPool,
        priority: ThumbnailPriority,
        seconds: Double
    ) async -> BatchSnapshot {
        let delivered = UIDSetBox()
        let writes = ThumbnailWriteTaskGroup()
        let loaderTask = Task {
            if let priorityLoader = loader as? any PriorityThumbnailBatchLoader {
                await priorityLoader.loadThumbnails(for: chunk, priority: priority) { uid, data in
                    writes.submit {
                        guard cache.isCurrentSessionLease(sessionLease) else { return }
                        guard await writePermits.acquire(priority: priority) else { return }
                        let stored = await writeExecutor.perform(priority: priority) {
                            cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration)
                        }
                        await writePermits.release()
                        guard stored == .stored else { return }
                        guard cache.isCurrentSessionLease(sessionLease) else { return }
                        diskPresence.set(uid, present: true)
                        delivered.insert(uid)
                    }
                }
            } else {
                await loader.loadThumbnails(for: chunk) { uid, data in
                    writes.submit {
                        guard cache.isCurrentSessionLease(sessionLease) else { return }
                        guard await writePermits.acquire(priority: priority) else { return }
                        let stored = await writeExecutor.perform(priority: priority) {
                            cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration)
                        }
                        await writePermits.release()
                        guard stored == .stored else { return }
                        guard cache.isCurrentSessionLease(sessionLease) else { return }
                        diskPresence.set(uid, present: true)
                        delivered.insert(uid)
                    }
                }
            }
        }
        let completionTask = Task {
            let result = await loaderTask.value
            await writes.finishAndWait()
            return result
        }
        let resolutionGate = OneShotContinuation<BatchResolution>()
        let resolution: BatchResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard resolutionGate.install(continuation) else { return }
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    if resolutionGate.resolve(.timedOut) {
                        loaderTask.cancel()
                    }
                }
                Task {
                    let result = await completionTask.value
                    if resolutionGate.resolve(.finished(result)) {
                        timeoutTask.cancel()
                    }
                }
            }
        } onCancel: {
            // Resume the cancelled crawl worker immediately. The returned loader handle remains
            // tracked and owner teardown still joins it before releasing the backend.
            loaderTask.cancel()
            _ = resolutionGate.resolve(.timedOut)
        }
        let lateLoader: Task<ThumbnailBatchLoadResult, Never>?
        if case .timedOut = resolution {
            // This completion includes callback disk writes. Owner teardown must not release the account/cache
            // graph while a late write still owns its generation and utility-executor operation.
            lateLoader = completionTask
        } else {
            lateLoader = nil
        }
        return BatchSnapshot(delivered: delivered.snapshot, resolution: resolution, lateLoader: lateLoader)
    }

    private func timedOutLoaderFinished(taskID: UUID, itemCount: Int) {
        timedOutLoaderTasks[taskID] = nil
        timedOutLoaders = max(0, timedOutLoaders - 1)
        downloadInFlight = max(0, downloadInFlight - itemCount)
    }

    /// Reserves queue candidates on the actor, then yields it while the dedicated executor performs the actual
    /// file reads and AES-GCM validation. The old implementation called `hasUsableDiskData` inline here; one
    /// pathological APFS read could therefore stop every viewport replacement for multiple seconds.
    private func takeBatch() async -> BatchWork {
        let probeGeneration = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        var candidates: [PhotoUID] = []
        var reserved = Set<PhotoUID>()
        var batchPriority = ThumbnailPriority.idleLibraryCrawl
        var diskHits: [PhotoUID] = []
        var diskMisses: [PhotoUID] = []
        while candidates.count < configuration.batchSize, !priority.isEmpty {
            let bestIndex =
                priority.indices.min {
                    let lhs = priorityByUID[priority[$0]] ?? .idleLibraryCrawl
                    let rhs = priorityByUID[priority[$1]] ?? .idleLibraryCrawl
                    if lhs != rhs { return lhs < rhs }
                    // Preserve the caller's near-to-far order inside one priority. The former LIFO tie break
                    // inverted a scroll-ahead corridor, downloading its far edge before the cells about to enter
                    // the viewport.
                    return $0 < $1
                } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: bestIndex)
            let itemPriority = priorityByUID.removeValue(forKey: uid) ?? .idleLibraryCrawl
            batchPriority = min(batchPriority, itemPriority)
            if unfetchable.contains(uid) {
                skippedUnfetchable += 1
                continue
            }
            // Priority work always revalidates. A durable checkpoint can outlive an evicted or corrupt cache
            // file; trusting it here would leave a stable visible placeholder with no subsequent network wake.
            guard reserved.insert(uid).inserted else { continue }
            priorityReservations.append(
                PriorityReservation(
                    uid: uid,
                    priority: itemPriority,
                    generation: prefetchGeneration
                ))
            candidates.append(uid)
        }

        let now = clock()
        let backingOff = crawlBackoffUntil.map { now < $0 } ?? false
        guard !prefetchPaused, prefetchEnabled, !recentVisibleDemand(now: now), !backingOff else {
            let batch = await finishDiskProbeBatch(
                candidates,
                priority: batchPriority,
                writerGeneration: probeGeneration,
                forceAuthentication: startupAuthenticationPending
            )
            if startupAuthenticationPending,
                sequentialIndex >= sequential.count,
                candidates.isEmpty || batch.probedDisk
            {
                startupAuthenticationPending = false
            }
            return batch
        }

        var scannedThisCall = 0
        while candidates.count < configuration.batchSize,
            sequentialIndex < sequential.count,
            scannedThisCall < configuration.sequentialScanLimit
        {
            scannedThisCall += 1
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            if unfetchable.contains(uid) {
                skippedUnfetchable += 1
                continue
            }
            if checkpointPresent.contains(uid) {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return BatchWork()
                }
                diskPresence.set(uid, present: true)
                prefetchDiskHit += 1
                continue
            }
            guard reserved.insert(uid).inserted else { continue }
            candidates.append(uid)
        }
        guard !candidates.isEmpty else {
            if startupAuthenticationPending, sequentialIndex >= sequential.count {
                startupAuthenticationPending = false
            }
            return BatchWork(priority: batchPriority)
        }
        let forceAuthentication = startupAuthenticationPending
        guard
            let probes = await accountedDiskProbes(
                candidates,
                priority: batchPriority,
                writerGeneration: probeGeneration,
                forceAuthentication: forceAuthentication
            )
        else {
            return BatchWork()
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        for probe in probes {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                return BatchWork()
            }
            diskPresence.set(probe.uid, present: probe.usable)
            if probe.usable {
                diskHits.append(probe.uid)
                prefetchDiskHit += 1
            } else {
                diskMisses.append(probe.uid)
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        recordCheckpointPresent(diskHits, writerGeneration: probeGeneration)
        recordCheckpointMissing(diskMisses, writerGeneration: probeGeneration)
        releasePriorityReservations(for: diskHits, generation: prefetchGeneration)
        if forceAuthentication, sequentialIndex >= sequential.count {
            startupAuthenticationPending = false
        }
        return BatchWork(uids: diskMisses, priority: batchPriority, probedDisk: !candidates.isEmpty)
    }

    private func finishDiskProbeBatch(
        _ candidates: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        forceAuthentication: Bool
    ) async -> BatchWork {
        guard !candidates.isEmpty else { return BatchWork(priority: priority) }
        guard
            let probes = await accountedDiskProbes(
                candidates,
                priority: priority,
                writerGeneration: writerGeneration,
                forceAuthentication: forceAuthentication
            )
        else {
            return BatchWork()
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return BatchWork()
        }
        var misses: [PhotoUID] = []
        var hits: [PhotoUID] = []
        for probe in probes {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
                return BatchWork()
            }
            diskPresence.set(probe.uid, present: probe.usable)
            if probe.usable {
                hits.append(probe.uid)
                prefetchDiskHit += 1
            } else {
                misses.append(probe.uid)
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return BatchWork()
        }
        recordCheckpointPresent(hits, writerGeneration: writerGeneration)
        recordCheckpointMissing(misses, writerGeneration: writerGeneration)
        releasePriorityReservations(for: hits, generation: prefetchGeneration)
        return BatchWork(uids: misses, priority: priority, probedDisk: !candidates.isEmpty)
    }

    private func accountedDiskProbes(
        _ uids: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        forceAuthentication: Bool
    ) async -> [DiskProbe]? {
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return nil
        }
        let generation = prefetchGeneration
        diskProbeBatchesInFlight += 1
        defer { diskProbeBatchesInFlight = max(0, diskProbeBatchesInFlight - 1) }
        let probes = await probeUsableDisk(
            uids,
            priority: priority,
            writerGeneration: writerGeneration,
            sessionLease: ownerSessionLease,
            forceAuthentication: forceAuthentication
        )
        guard generation == prefetchGeneration,
            prefetchEnabled,
            ownerLeaseIsCurrent(),
            cache.isCurrentWriterGeneration(writerGeneration),
            let probes
        else {
            return nil
        }
        return probes
    }

    private nonisolated func probeUsableDisk(
        _ uids: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        sessionLease: CacheWriterGeneration.SessionToken,
        forceAuthentication: Bool
    ) async -> [DiskProbe]? {
        let cache = self.cache
        let executor = self.decodeExecutor
        guard cache.isCurrentSessionLease(sessionLease),
            cache.isCurrentWriterGeneration(writerGeneration)
        else {
            return nil
        }
        #if DEBUG
            let testingHooks = self.testingHooks
        #endif
        let probes = await executor.perform(priority: priority) { () -> [DiskProbe]? in
            var probes: [DiskProbe] = []
            probes.reserveCapacity(uids.count)
            for uid in uids {
                guard cache.isCurrentSessionLease(sessionLease),
                    cache.isCurrentWriterGeneration(writerGeneration)
                else {
                    return nil
                }
                #if DEBUG
                    testingHooks.beforeDiskProbe()
                #endif
                self.diagnostics.recordDiskPresenceCheckDuringPinch()
                let usable =
                    forceAuthentication
                    ? cache.hasAuthenticatedDiskData(uid)
                    : cache.hasUsableDiskData(uid)
                probes.append(DiskProbe(uid: uid, usable: usable))
            }
            return probes
        }
        guard cache.isCurrentSessionLease(sessionLease),
            cache.isCurrentWriterGeneration(writerGeneration)
        else {
            return nil
        }
        return probes
    }

    @discardableResult
    private func removeQueuedPriorities(_ removedPriorities: Set<ThumbnailPriority>) -> Int {
        var removed = 0
        priority.removeAll { uid in
            guard let value = priorityByUID[uid], removedPriorities.contains(value) else { return false }
            priorityByUID.removeValue(forKey: uid)
            removed += 1
            return true
        }
        return removed
    }

    private func trimPriorityQueueIfNeeded() {
        while priority.count > configuration.priorityQueueLimit {
            // Discard the least urgent, farthest queued item. Equal priorities remain FIFO so the next
            // near-viewport item is retained.
            let index =
                priority.indices.max { lhs, rhs in
                    let left = priorityByUID[priority[lhs]] ?? .idleLibraryCrawl
                    let right = priorityByUID[priority[rhs]] ?? .idleLibraryCrawl
                    if left != right { return left < right }
                    return lhs < rhs
                } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: index)
            priorityByUID.removeValue(forKey: uid)
        }
    }

    private func restorePriorityReservationsForRestart() {
        for reservation in priorityReservations {
            if let queuedPriority = priorityByUID[reservation.uid] {
                priorityByUID[reservation.uid] = min(queuedPriority, reservation.priority)
            } else {
                priority.append(reservation.uid)
                priorityByUID[reservation.uid] = reservation.priority
            }
        }
        priorityReservations.removeAll(keepingCapacity: true)
        trimPriorityQueueIfNeeded()
    }

    private func releasePriorityReservations(for uids: [PhotoUID], generation: UInt64) {
        guard !uids.isEmpty else { return }
        let released = Set(uids)
        priorityReservations.removeAll { reservation in
            reservation.generation == generation && released.contains(reservation.uid)
        }
    }

    /// Whether a viewport has demanded thumbnails within the quiet window. `nonisolated` (reads the lock-guarded
    /// demand box), so the crawl can consult it mid-scan without touching actor state.
    private nonisolated func recentVisibleDemand(now: Date? = nil) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return (now ?? clock()).timeIntervalSince(last) < configuration.visibleQuietWindow
    }

    /// Bound on disk-presence stats performed per `advanceDiskCoverageScan` invocation - the ceiling on how long
    /// one end-of-crawl coverage step can hold the serial actor. Small enough that a visible warm decode never
    /// waits behind more than this many filesystem stats.
    private static let coverageScanChunk = 512

    /// Advances the end-of-crawl disk-coverage re-scan by one bounded chunk of disk checks, returning the
    /// refreshed coverage only when a full pass just completed (else `nil` - "call again"). Bounded so it can
    /// never hold the serial actor for an O(library) scan, and it bails to `nil` the instant a viewport goes
    /// live, so it can never starve a visible warm decode. Workers share `coverageScanCursor`, so together they
    /// complete one pass in bounded steps; no single worker runs a full scan. All filesystem probes run on the
    /// decode executor, never on this actor.
    private func advanceDiskCoverageScan() async -> (present: Int, total: Int, percent: Double)? {
        let cache = self.cache
        let probeGeneration = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return nil
        }
        var scanned = 0
        var present: [PhotoUID] = []
        var missing: [PhotoUID] = []
        var needsProbe: [PhotoUID] = []
        while coverageScanCursor < sequential.count, scanned < Self.coverageScanChunk {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                return nil
            }
            if recentVisibleDemand() { return nil }
            let uid = sequential[coverageScanCursor]
            if checkpointPresent.contains(uid) {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return nil
                }
                diskPresence.set(uid, present: true)
                present.append(uid)
            } else {
                needsProbe.append(uid)
            }
            coverageScanCursor += 1
            scanned += 1
        }
        if !needsProbe.isEmpty {
            let probeUIDs = needsProbe
            let probes = await decodeExecutor.perform(priority: .idleLibraryCrawl) { () -> [DiskProbe]? in
                var probes: [DiskProbe] = []
                probes.reserveCapacity(probeUIDs.count)
                for uid in probeUIDs {
                    guard cache.isCurrentSessionLease(self.ownerSessionLease),
                        cache.isCurrentWriterGeneration(probeGeneration)
                    else {
                        return nil
                    }
                    self.diagnostics.recordDiskPresenceCheckDuringPinch()
                    probes.append(DiskProbe(uid: uid, usable: cache.hasUsableDiskData(uid)))
                }
                return probes
            }
            guard let probes,
                ownerLeaseIsCurrent(),
                cache.isCurrentSessionLease(ownerSessionLease),
                cache.isCurrentWriterGeneration(probeGeneration)
            else {
                return nil
            }
            for probe in probes {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return nil
                }
                diskPresence.set(probe.uid, present: probe.usable)
                if probe.usable {
                    present.append(probe.uid)
                } else {
                    missing.append(probe.uid)
                }
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return nil
        }
        recordCheckpointPresent(present, writerGeneration: probeGeneration)
        recordCheckpointMissing(missing, writerGeneration: probeGeneration)
        guard coverageScanCursor >= sequential.count else { return nil }  // pass not finished yet
        coverageScanCursor = 0
        return diskPresence.coverage()
    }

    private func recordCheckpointPresent(
        _ uids: [PhotoUID],
        writerGeneration: CacheWriterGeneration.Token? = nil
    ) {
        guard !uids.isEmpty, ownerLeaseIsCurrent() else { return }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) { return }
        for uid in uids where checkpointPresent.insert(uid).inserted {
            // A current probe proved the hint. Avoid rewriting an unchanged durable entry, but retain the
            // current-session proof in `checkpointPresent` for coverage decisions.
            if checkpointHints.remove(uid) == nil {
                pendingCheckpointUpdates[uid] = true
            }
        }
        flushCheckpointUpdatesIfNeeded(writerGeneration: writerGeneration)
    }

    private func recordCheckpointMissing(
        _ uids: [PhotoUID],
        writerGeneration: CacheWriterGeneration.Token? = nil
    ) {
        guard !uids.isEmpty, ownerLeaseIsCurrent() else { return }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) { return }
        for uid in uids {
            let hadHint = checkpointHints.remove(uid) != nil
            let hadPresent = checkpointPresent.remove(uid) != nil
            if hadHint || hadPresent {
                pendingCheckpointUpdates[uid] = false
            }
        }
        flushCheckpointUpdatesIfNeeded(writerGeneration: writerGeneration)
    }

    private func flushCheckpointUpdatesIfNeeded(writerGeneration: CacheWriterGeneration.Token? = nil) {
        if pendingCheckpointUpdates.count >= Self.checkpointFlushThreshold {
            flushCheckpointUpdates(writerGeneration: writerGeneration)
        }
    }

    private func flushCheckpointUpdates(writerGeneration: CacheWriterGeneration.Token? = nil) {
        guard ownerLeaseIsCurrent() else {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        guard let coverageStore, !pendingCheckpointUpdates.isEmpty else {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        var present: [PhotoUID] = []
        var missing: [PhotoUID] = []
        present.reserveCapacity(pendingCheckpointUpdates.count)
        missing.reserveCapacity(pendingCheckpointUpdates.count)
        for (uid, isPresent) in pendingCheckpointUpdates {
            if isPresent { present.append(uid) } else { missing.append(uid) }
        }
        pendingCheckpointUpdates.removeAll(keepingCapacity: true)
        guard ownerLeaseIsCurrent(),
            writerGeneration.map({ cache.isCurrentWriterGeneration($0) }) ?? true
        else {
            return
        }
        coverageStore.recordPresent(present, for: coverageCheckpointKey)
        guard ownerLeaseIsCurrent(),
            writerGeneration.map({ cache.isCurrentWriterGeneration($0) }) ?? true
        else {
            return
        }
        coverageStore.recordMissing(missing, for: coverageCheckpointKey)
    }

    private enum CoverageRefreshOutcome { case settled, recrawl, aborted }

    /// Runs the end-of-crawl disk-coverage refresh to completion, in bounded `advanceDiskCoverageScan` chunks
    /// that yield the serial actor between them and abort the instant a viewport goes live. Invoked single-flight
    /// (guarded by `coverageRefreshInFlight`), so exactly one runs per drain regardless of worker count - it can
    /// never hold the actor for an O(library) scan, be multiplied by the worker count, or starve a visible warm
    /// decode. Emits one `[ThumbCoverage]` line at start and one at finish (never per item).
    private func runCoverageRefresh() async -> CoverageRefreshOutcome {
        defer { flushCheckpointUpdates() }
        let startedAt = clock()
        coverageRefreshStarts += 1
        emitCoverage("refreshStart", scanned: 0, coverage: diskPresence.coverage(), startedAt: startedAt, reason: "-")
        // Known-state fast path: if the incremental tracker already reports (near) complete coverage from this
        // session's crawling, settle without a full `cache.has` sweep - it would be redundant background I/O.
        // The tracker only counts UIDs it has positively seen present, so this can never falsely report "warm"
        // from incomplete knowledge; a real scan runs only when knowledge is incomplete (e.g. a checkpoint
        // resume left early items unscanned) and might reveal missing items to re-crawl.
        let known = diskPresence.coverage()
        if known.percent >= 0.995 {
            emitCoverage("refreshDone", scanned: 0, coverage: known, startedAt: startedAt, reason: "trackerComplete")
            return .settled
        }
        coverageFullScans += 1
        coverageScanCursor = 0
        while true {
            if recentVisibleDemand() {
                emitCoverage(
                    "refreshAbortVisibleDemand", scanned: coverageScanCursor,
                    coverage: diskPresence.coverage(), startedAt: startedAt, reason: "visibleDemand")
                return .aborted
            }
            guard let coverage = await advanceDiskCoverageScan() else {
                try? await Task.sleep(for: .milliseconds(1))  // Yield after each chunk.
                continue
            }
            let recrawl = coverage.percent < 0.995 && coverage.percent > lastRepassPercent + 0.01
            if recrawl { lastRepassPercent = coverage.percent }
            emitCoverage(
                "refreshDone", scanned: coverage.total, coverage: coverage, startedAt: startedAt,
                reason: recrawl ? "recrawl" : "settled")
            return recrawl ? .recrawl : .settled
        }
    }

    private func emitCoverage(
        _ event: String, scanned: Int, coverage: (present: Int, total: Int, percent: Double),
        startedAt: Date, reason: String
    ) {
        diagnostics.emit(
            "ThumbCoverage",
            [
                "event": event,
                "scanned": "\(scanned)",
                "total": "\(coverage.total)",
                "present": "\(coverage.present)",
                "durationMs": "\(Int(clock().timeIntervalSince(startedAt) * 1000))",
                "workers": "\(configuration.downloadConcurrencyLimit)",
                "reason": reason,
            ])
    }

    private nonisolated static func decodeTile(
        cache: ThumbnailCache,
        uid: PhotoUID,
        maxPixels: CGFloat,
        isUpgrade: Bool
    ) -> DecodedTile {
        let readStartedAt = Date()
        let data = PhotoPerformanceSignposts.mediaFeed.interval("feed.decrypt") {
            cache.diskData(for: uid)
        }
        let readDurationMs = Date().timeIntervalSince(readStartedAt) * 1000
        guard let data else {
            return DecodedTile(
                uid: uid,
                decoded: nil,
                diskHadData: false,
                readDurationMs: readDurationMs,
                durationMs: 0,
                decodePixelCap: Int(maxPixels),
                isUpgrade: isUpgrade
            )
        }
        let decodeStartedAt = Date()
        let decoded = PhotoPerformanceSignposts.mediaFeed.interval("feed.decode") {
            ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
        }
        return DecodedTile(
            uid: uid,
            decoded: decoded,
            diskHadData: true,
            readDurationMs: readDurationMs,
            durationMs: Date().timeIntervalSince(decodeStartedAt) * 1000,
            decodePixelCap: Int(maxPixels),
            isUpgrade: isUpgrade
        )
    }

    private func recordSlowDecodeStages(_ tile: DecodedTile) {
        guard tile.readDurationMs >= 250 || tile.durationMs >= 250 else { return }
        diagnostics.emitDebug(
            "ThumbDecode",
            [
                "action": "slowStage",
                "diskHadData": "\(tile.diskHadData)",
                "readMs": "\(Int(tile.readDurationMs))",
                "decodeMs": "\(Int(tile.durationMs))",
            ])
    }

    private func storeDecoded(_ image: DecodedThumbnail, for uid: PhotoUID, decodePixelCap: Int) {
        decoded.set(image, for: uid, decodePixelCap: decodePixelCap)
        onDecoded(uid, image)
    }

    /// A completed disk decode is immediately useful to the Metal grid. This wake intentionally happens at each
    /// completion, rather than after the surrounding task group drains: the native host coalesces redraw requests
    /// onto its display link, so the first ready visible tile can be uploaded while slower encrypted reads run.
    private func notifyHostOfAvailableImageIfVisible() {
        guard hostArrivalWakeIsLive(now: clock()) else { return }
        imagesAvailableWake.call()
    }

    private func recordError(_ message: String) {
        lastErrors.append(message)
        if lastErrors.count > 10 { lastErrors.removeFirst(lastErrors.count - 10) }
    }

    private func emitPrefetchSummary() {
        #if DEBUG
            let pausedReason: String
            if !prefetchEnabled {
                pausedReason = "disabled"
            } else if prefetchPaused {
                pausedReason = "manual"
            } else {
                pausedReason = "none"
            }
            let now = clock()
            let queueDepth = priority.count + max(0, sequential.count - sequentialIndex)
            let isActive = queueDepth > 0 || downloadInFlight + decodeInFlight > 0
            let intervalElapsed = lastPrefetchSummaryAt.map { now.timeIntervalSince($0) >= 1 } ?? true
            let shouldEmit =
                intervalElapsed
                || (lastPrefetchSummaryWasActive && !isActive)
                || lastPrefetchSummaryPausedReason != pausedReason
            guard shouldEmit else { return }
            lastPrefetchSummaryAt = now
            lastPrefetchSummaryWasActive = isActive
            lastPrefetchSummaryPausedReason = pausedReason
            diagnostics.emit(
                "ThumbPrefetch",
                [
                    "enabled": "\(prefetchEnabled)",
                    "queueDepth": "\(queueDepth)",
                    "activeJobs": "\(downloadInFlight + decodeInFlight)",
                    "completed": "\(prefetchCompleted)",
                    "failed": "\(prefetchFailed)",
                    "failedTimeout": "\(prefetchFailedTimeout)",
                    "failedBatchError": "\(prefetchFailedBatchError)",
                    "failedItemError": "\(prefetchFailedItemError)",
                    "failedUnreported": "\(prefetchFailedUnreported)",
                    "unfetchable": "\(unfetchable.count)",
                    "skippedUnfetchable": "\(skippedUnfetchable)",
                    "diskHit": "\(prefetchDiskHit)",
                    "downloadStarted": "\(prefetchDownloadStarted)",
                    "downloadCompleted": "\(prefetchDownloadCompleted)",
                    "decodeStarted": "\(prefetchDecodeStarted)",
                    "decodeCompleted": "\(prefetchDecodeCompleted)",
                    "pausedReason": pausedReason,
                    "lastError": lastErrors.last ?? "-",
                ])
        #endif
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}

#if DEBUG
    private final class ThumbnailFeedCoreTestingHooks: @unchecked Sendable {
        private let lock = NSLock()
        private var diskProbeHook: (@Sendable () -> Void)?

        func setBeforeDiskProbe(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { diskProbeHook = hook }
        }

        func beforeDiskProbe() {
            let hook = lock.withLock { diskProbeHook }
            hook?()
        }
    }

    extension ThumbnailFeedCore {
        /// Debug-only seam for installing a synchronous gate before a disk probe starts.
        nonisolated func setDiskProbeHookForTesting(_ hook: (@Sendable () -> Void)?) {
            testingHooks.setBeforeDiskProbe(hook)
        }

        /// Debug-only seam that runs one bounded end-of-crawl coverage-scan step and returns its probe count.
        func coverageScanStepStatCountForTesting(seeding uids: [PhotoUID]) async -> Int {
            sequential = uids
            coverageScanCursor = 0
            _ = await advanceDiskCoverageScan()
            // The cursor advances by one bounded chunk per call and reports that step's probe count.
            return coverageScanCursor
        }

        /// Debug-only seam that reports end-of-crawl coverage refreshes started during this crawl.
        func coverageRefreshStartCountForTesting() -> Int { coverageRefreshStarts }

        /// Debug-only seam that reports refreshes which ran a chunked `cache.has` sweep.
        func coverageFullScanCountForTesting() -> Int { coverageFullScans }
    }
#endif

/// The moving viewport has one replaceable queue and a fixed worker population. Pending work from an older
/// generation disappears immediately; active work is never duplicated or awaited as a viewport-wide barrier.
struct LatestVisibleDecodeDemand {
    struct Job: Hashable, Sendable {
        let uid: PhotoUID
        let maxPixels: CGFloat
        let isUpgrade: Bool
    }

    private(set) var generation: UInt64 = 0
    private var pending: [Job] = []
    private var active: [PhotoUID: Job] = [:]
    private var desired: [PhotoUID: Job] = [:]

    var pendingCount: Int { pending.count }
    var activeCount: Int { active.count }

    mutating func replace(with jobs: [Job], generation newGeneration: UInt64) -> Bool {
        guard newGeneration >= generation else { return false }
        generation = newGeneration
        var seen = Set<PhotoUID>()
        let uniqueJobs = jobs.filter { job in
            guard seen.insert(job.uid).inserted else { return false }
            return true
        }
        desired = Dictionary(uniqueKeysWithValues: uniqueJobs.map { ($0.uid, $0) })
        // Never run two synchronous reads/decrypts/decodes for the same asset. If the latest viewport asks for
        // a sharper tile while a smaller decode is active, `complete` queues the upgrade after that result has
        // been published.
        pending = uniqueJobs.filter { active[$0.uid] == nil }
        return true
    }

    mutating func takeNext() -> Job? {
        guard !pending.isEmpty else { return nil }
        let job = pending.removeFirst()
        active[job.uid] = job
        return job
    }

    mutating func complete(_ job: Job) {
        guard active[job.uid] == job else { return }
        active.removeValue(forKey: job.uid)
        guard let latest = desired[job.uid], latest.maxPixels > job.maxPixels else { return }
        guard !pending.contains(where: { $0.uid == job.uid }) else { return }
        pending.append(Job(uid: latest.uid, maxPixels: latest.maxPixels, isUpgrade: true))
    }

    mutating func returnToPending(_ job: Job) {
        guard active[job.uid] == job else { return }
        active.removeValue(forKey: job.uid)
        guard let latest = desired[job.uid] else { return }
        guard !pending.contains(where: { $0.uid == job.uid }) else { return }
        pending.insert(latest, at: 0)
    }
}

/// Thread-safe single-consumer mailbox for high-frequency viewport updates. A submitter schedules an actor
/// drain only when none is active; the drain always takes the newest generation and discards superseded values.
final class LatestVisibleDecodeDemandInbox: @unchecked Sendable {
    struct Submission: Sendable, Equatable {
        let requests: [ThumbnailRequest]
        let generation: UInt64
    }

    private let lock = NSLock()
    private var latest: Submission?
    private var drainScheduled = false
    private var nextGeneration: UInt64 = 0

    /// Returns true only for the producer that must schedule the single drain task. The mailbox owns the
    /// generation so replacing a platform data source cannot reset ordering while this feed remains alive.
    func submit(requests: [ThumbnailRequest]) -> Bool {
        lock.withLock {
            nextGeneration &+= 1
            latest = Submission(requests: requests, generation: nextGeneration)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    /// Returns the newest pending value. When empty, atomically releases drain ownership so a racing producer
    /// either observes an active drain or becomes responsible for scheduling the next one.
    func takeLatestOrFinish() -> Submission? {
        lock.withLock {
            guard let submission = latest else {
                drainScheduled = false
                return nil
            }
            latest = nil
            return submission
        }
    }
}

/// Tracks callback writes so a completed loader batch does not report delivery before its encrypted disk writes
/// finish on the dedicated executor. A callback submitted after the loader closes is discarded, so no write can
/// outlive the task group and escape owner teardown.
private final class ThumbnailWriteTaskGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard !closed else { return }
            tasks.append(Task { await operation() })
        }
    }

    func finishAndWait() async {
        let pending = lock.withLock {
            closed = true
            let pending = tasks
            tasks.removeAll(keepingCapacity: false)
            return pending
        }
        for task in pending {
            await task.value
        }
    }
}

/// Foundation file reads, CryptoKit and ImageIO are synchronous. Running them directly in Swift child tasks can
/// occupy the cooperative executor until unrelated actor work stops progressing. A dedicated concurrent queue
/// contains that blocking boundary; `DecodePermitPool` remains the feed-wide concurrency cap.
final class ThumbnailDecodeWorkExecutor: @unchecked Sendable {
    private let interactiveQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.thumbnail-decode.interactive",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let backgroundQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.thumbnail-decode.background",
        qos: .utility,
        attributes: .concurrent
    )

    func perform<T: Sendable>(
        priority: ThumbnailPriority,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        let queue = priority <= .zoomAnchorAndFocusRow ? interactiveQueue : backgroundQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// Cancellation-safe, priority-aware admission for the feed's decrypt/decode lanes. Visible work jumps queued
/// background work; an already-running synchronous operation retains its permit until the dedicated queue returns.
actor DecodePermitPool {
    private struct Waiter {
        let id: UUID
        let priority: ThumbnailPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    init(permits: Int) {
        available = max(1, permits)
    }

    func acquire(priority: ThumbnailPriority) async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(
                        Waiter(
                            id: waiterID,
                            priority: priority,
                            sequence: nextSequence,
                            continuation: continuation
                        ))
                    nextSequence &+= 1
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }

        // A cancellation can race the handoff from `release()`. Do not strand the permit in that case.
        if acquired, Task.isCancelled {
            release()
            return false
        }
        return acquired
    }

    func release() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        let index = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority { return left.priority < right.priority }
            return left.sequence < right.sequence
        }!
        waiters.remove(at: index).continuation.resume(returning: true)
    }

    private func cancel(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

private final class UnfetchableThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<PhotoUID> = []

    var count: Int {
        lock.withLock { ids.count }
    }

    func contains(_ uid: PhotoUID) -> Bool {
        lock.withLock { ids.contains(uid) }
    }

    func insert(_ uid: PhotoUID) {
        lock.withLock { _ = ids.insert(uid) }
    }

    func formUnion<S: Sequence>(_ sequence: S) where S.Element == PhotoUID {
        lock.withLock { ids.formUnion(sequence) }
    }

    func removeAll() {
        lock.withLock { ids.removeAll(keepingCapacity: true) }
    }
}

private struct DecodedTile: @unchecked Sendable {
    let uid: PhotoUID
    let decoded: DecodedThumbnail?
    let diskHadData: Bool
    let readDurationMs: Double
    let durationMs: Double
    let decodePixelCap: Int
    let isUpgrade: Bool
}

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    func set(_ data: Data) {
        lock.withLock { bytes = data }
    }

    var value: Data? {
        lock.withLock { bytes }
    }
}

private final class UIDSetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var uids: Set<PhotoUID> = []

    func insert(_ uid: PhotoUID) {
        lock.withLock { _ = uids.insert(uid) }
    }

    var snapshot: Set<PhotoUID> {
        lock.withLock { uids }
    }
}

/// One-shot continuation used to resolve completion, timeout, and cancellation races exactly once.
private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolvedValue: Value?

    /// Installs the waiter. A cancellation can resolve before installation, in which case this
    /// method resumes the waiter immediately and tells the caller not to start race tasks.
    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let pending = lock.withLock { () -> Value? in
            guard let resolvedValue else {
                self.continuation = continuation
                return nil
            }
            return resolvedValue
        }
        guard let pending else { return true }
        continuation.resume(returning: pending)
        return false
    }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let result = lock.withLock { () -> (claimed: Bool, continuation: CheckedContinuation<Value, Never>?) in
            guard resolvedValue == nil else { return (false, nil) }
            resolvedValue = value
            defer { continuation = nil }
            return (true, continuation)
        }
        result.continuation?.resume(returning: value)
        return result.claimed
    }
}

/// Lock-guarded last-visible-demand timestamp, shared between the actor's methods and the `nonisolated`
/// crawl reads. Lets `noteVisibleDemand` record demand without an actor hop (so it can't starve behind the
/// crawl it is meant to pause).
private final class LastDemandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    func set(_ date: Date) {
        lock.withLock { value = date }
    }

    func get() -> Date? {
        lock.withLock { value }
    }
}

/// Lock-guarded gesture state shared with synchronous background-work governors. Platform hosts
/// update it only at interaction boundaries, so an idle viewport never generates polling or writes.
private final class InteractionStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func set(_ value: Bool) {
        lock.withLock { active = value }
    }

    func get() -> Bool {
        lock.withLock { active }
    }
}

/// Synchronous registration closes the first-viewport race where tiny cached images could finish before a
/// fire-and-forget actor task installed the host wake. Invocation copies all callbacks under lock and calls them
/// outside the critical section, so observers may safely end or add registrations while a wake is in flight.
private final class ImagesAvailableWakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]

    func add(_ callback: @escaping @Sendable () -> Void) -> ThumbnailFeedWakeRegistration {
        let id = UUID()
        lock.withLock { callbacks[id] = callback }
        return ThumbnailFeedWakeRegistration { [weak self] in
            self?.remove(id)
        }
    }

    private func remove(_ id: UUID) {
        _ = lock.withLock { callbacks.removeValue(forKey: id) }
    }

    func call() {
        let current: [@Sendable () -> Void] = lock.withLock { Array(callbacks.values) }
        for callback in current { callback() }
    }
}
