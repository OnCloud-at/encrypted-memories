import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MediaDecodingCore
import PhotosCore
import Testing

@testable import MediaByteCache
@testable import MediaFeedCore

private let feedCacheTestKey = SymmetricKey(size: .bits256)

@Test func decodePermitPoolDoesNotLeakCancelledWaiters() async throws {
    let pool = DecodePermitPool(permits: 1)
    #expect(await pool.acquire(priority: .idleLibraryCrawl))

    let waitingAcquire = Task { await pool.acquire(priority: .idleLibraryCrawl) }
    try await Task.sleep(for: .milliseconds(25))
    waitingAcquire.cancel()
    let cancelledAcquire = await waitingAcquire.value
    #expect(!cancelledAcquire)

    await pool.release()
    let replacementAcquire = await pool.acquire(priority: .visibleNow)
    #expect(replacementAcquire, "a cancelled viewport must not consume a decode lane")
    await pool.release()
}

@Test func latestVisibleDecodeDemandDropsOnlyPendingStaleWork() {
    let oldActive = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "old-active"),
        maxPixels: 96,
        isUpgrade: false
    )
    let oldPending = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "old-pending"),
        maxPixels: 96,
        isUpgrade: false
    )
    let latest = (0..<3).map {
        LatestVisibleDecodeDemand.Job(
            uid: PhotoUID(volumeID: "vol", nodeID: "latest-\($0)"),
            maxPixels: 96,
            isUpgrade: false
        )
    }
    var demand = LatestVisibleDecodeDemand()

    let acceptedOld = demand.replace(with: [oldActive, oldPending], generation: 1)
    let startedOld = demand.takeNext()
    let acceptedLatest = demand.replace(with: latest, generation: 2)
    #expect(acceptedOld)
    #expect(startedOld == oldActive)
    #expect(acceptedLatest)
    #expect(demand.pendingCount == latest.count)
    let startedLatest = demand.takeNext()
    let acceptedLateOld = demand.replace(with: [oldPending], generation: 1)
    #expect(startedLatest == latest[0])
    #expect(!acceptedLateOld)
    #expect(demand.generation == 2)
}

@Test func latestVisibleDecodeDemandSerializesSharperUpgradeForActiveAsset() {
    let uid = PhotoUID(volumeID: "vol", nodeID: "same-visible-asset")
    let small = LatestVisibleDecodeDemand.Job(uid: uid, maxPixels: 96, isUpgrade: false)
    let large = LatestVisibleDecodeDemand.Job(uid: uid, maxPixels: 384, isUpgrade: false)
    var demand = LatestVisibleDecodeDemand()

    let acceptedSmall = demand.replace(with: [small], generation: 1)
    #expect(acceptedSmall)
    #expect(demand.takeNext() == small)
    let acceptedLarge = demand.replace(with: [large], generation: 2)
    #expect(acceptedLarge)
    #expect(demand.pendingCount == 0, "an active decode must not be duplicated")

    demand.complete(small)
    let queuedUpgrade = demand.takeNext()
    #expect(queuedUpgrade?.uid == uid)
    #expect(queuedUpgrade?.maxPixels == large.maxPixels)
    #expect(queuedUpgrade?.isUpgrade == true)
}

@Test func latestVisibleDecodeDemandReturnsCancelledActiveJobToLatestViewport() {
    let old = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "cancelled-visible-asset"),
        maxPixels: 96,
        isUpgrade: false
    )
    let replacement = LatestVisibleDecodeDemand.Job(
        uid: old.uid,
        maxPixels: 192,
        isUpgrade: false
    )
    var demand = LatestVisibleDecodeDemand()

    let acceptedOld = demand.replace(with: [old], generation: 1)
    #expect(acceptedOld)
    #expect(demand.takeNext() == old)
    let acceptedReplacement = demand.replace(with: [replacement], generation: 2)
    #expect(acceptedReplacement)
    demand.returnToPending(old)

    #expect(demand.activeCount == 0)
    #expect(demand.pendingCount == 1)
    #expect(demand.takeNext() == replacement, "cancellation must not lose the latest visible request")
}

@Test func latestVisibleDecodeDemandRealisticViewportMeasurement() {
    let jobs = (0..<512).map {
        LatestVisibleDecodeDemand.Job(
            uid: PhotoUID(volumeID: "vol", nodeID: "viewport-\($0)"),
            maxPixels: 384,
            isUpgrade: false
        )
    }
    var demand = LatestVisibleDecodeDemand()
    let started = ContinuousClock.now

    for generation in 1...240 {
        let accepted = demand.replace(with: jobs, generation: UInt64(generation))
        #expect(accepted)
    }
    let replacementElapsed = started.duration(to: ContinuousClock.now)
    #expect(demand.pendingCount == jobs.count)

    let drainStarted = ContinuousClock.now
    var drained = 0
    while let job = demand.takeNext() {
        demand.complete(job)
        drained += 1
    }
    let drainElapsed = drainStarted.duration(to: ContinuousClock.now)
    print(
        "[LatestVisibleDecodeDemand] viewport=\(jobs.count) replacements=240 "
            + "replaceElapsed=\(replacementElapsed) drainElapsed=\(drainElapsed)"
    )
    #expect(drained == jobs.count)
    #expect(demand.pendingCount == 0)
}

@Test func latestVisibleDecodeDemandInboxCoalescesQueuedGenerations() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let first = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "first"), pixelSize: 96)]
    let latest = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "latest"), pixelSize: 192)]

    #expect(inbox.submit(requests: first), "the first producer owns drain scheduling")
    #expect(!inbox.submit(requests: latest), "later frames update the mailbox without more tasks")
    #expect(inbox.takeLatestOrFinish() == .init(requests: latest, generation: 2))
    #expect(inbox.takeLatestOrFinish() == nil, "an empty drain atomically releases ownership")
    #expect(inbox.submit(requests: first), "the next burst schedules exactly one new drain")
    #expect(
        inbox.takeLatestOrFinish() == .init(requests: first, generation: 3),
        "mailbox ordering must survive producer and data-source replacement")
}

@Test func latestVisibleDecodeDemandInboxOwnsMonotonicGeneration() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let first = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "first"))]
    let replacement = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "replacement"))]

    #expect(inbox.submit(requests: first))
    #expect(inbox.takeLatestOrFinish() == .init(requests: first, generation: 1))
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(inbox.submit(requests: replacement))
    #expect(inbox.takeLatestOrFinish() == .init(requests: replacement, generation: 2))
}

@Test func decodePermitPoolPrioritizesVisibleWaiters() async throws {
    let pool = DecodePermitPool(permits: 1)
    #expect(await pool.acquire(priority: .idleLibraryCrawl))
    let background = Task { await pool.acquire(priority: .idleLibraryCrawl) }
    let visible = Task { await pool.acquire(priority: .visibleNow) }
    try await Task.sleep(for: .milliseconds(25))

    await pool.release()
    #expect(await visible.value)
    await pool.release()
    #expect(await background.value)
    await pool.release()
}

@Test func thumbnailDecodeWorkExecutorLeavesCooperativeCaller() async {
    let executor = ThumbnailDecodeWorkExecutor()
    let ranOnMainThread = await executor.perform(priority: .visibleNow) { Thread.isMainThread }
    #expect(!ranOnMainThread)
}

private actor RecordingLoader: ThumbnailBatchLoader {
    private var order: [PhotoUID] = []
    private var finishedBatchCount = 0
    private let payloads: [PhotoUID: Data]
    private let itemErrors: [PhotoUID: String]
    private let batchError: String?
    private let failAll: Bool
    private let delayMilliseconds: Int

    init(
        payloads: [PhotoUID: Data] = [:],
        itemErrors: [PhotoUID: String] = [:],
        batchError: String? = nil,
        failAll: Bool = false,
        delayMilliseconds: Int = 0
    ) {
        self.payloads = payloads
        self.itemErrors = itemErrors
        self.batchError = batchError
        self.failAll = failAll
        self.delayMilliseconds = delayMilliseconds
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        order.append(contentsOf: uids)
        if delayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        defer { finishedBatchCount += 1 }
        if let batchError { return ThumbnailBatchLoadResult(batchError: batchError) }
        guard !failAll else { return .delivered }  // models a loader that delivers nothing and reports nothing
        var errors: [PhotoUID: String] = [:]
        for uid in uids {
            if let data = payloads[uid] {
                onLoaded(uid, data)
            } else if let reason = itemErrors[uid] {
                errors[uid] = reason
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: errors)
    }

    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
    func requestCount() -> Int { order.count }
    func finishedBatches() -> Int { finishedBatchCount }
}

private actor CancellationAwareLoader: ThumbnailBatchLoader {
    private var requested: [PhotoUID] = []
    private var cancellationCount = 0
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        do {
            try await Task.sleep(for: delay)
        } catch is CancellationError {
            cancellationCount += 1
        } catch {
            return ThumbnailBatchLoadResult(batchError: error.localizedDescription)
        }
        return .delivered
    }

    func requestCount() -> Int { requested.count }
    func cancellations() -> Int { cancellationCount }
}

private actor NonCooperativeLoader: ThumbnailBatchLoader {
    private var requested: [PhotoUID] = []
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        let detachedDelay = Task.detached { [delay] in
            try? await Task.sleep(for: delay)
        }
        await detachedDelay.value
        return .delivered
    }

    func requestCount() -> Int { requested.count }
}

private actor ControlledLateLoader: ThumbnailBatchLoader {
    private let payloads: [PhotoUID: Data]
    private var requested: [PhotoUID] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var finishedBatchCount = 0

    init(payloads: [PhotoUID: Data]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        for uid in uids {
            if let data = payloads[uid] { onLoaded(uid, data) }
        }
        finishedBatchCount += 1
        return .delivered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func requestCount() -> Int { requested.count }
    func requestedOrder() -> [PhotoUID] { requested }
    func finishedBatches() -> Int { finishedBatchCount }
}

private actor PerUIDControlledLateLoader: ThumbnailBatchLoader {
    private let payloads: [PhotoUID: Data]
    private var requested: [PhotoUID] = []
    private var continuations: [PhotoUID: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<PhotoUID> = []
    private var finishedBatchCount = 0

    init(payloads: [PhotoUID: Data]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        for uid in uids where !released.contains(uid) {
            await withCheckedContinuation { continuation in
                continuations[uid, default: []].append(continuation)
            }
        }
        for uid in uids {
            if let data = payloads[uid] { onLoaded(uid, data) }
        }
        finishedBatchCount += 1
        return .delivered
    }

    func release(_ uid: PhotoUID) {
        released.insert(uid)
        let waiters = continuations.removeValue(forKey: uid) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func requestCount() -> Int { requested.count }
    func finishedBatches() -> Int { finishedBatchCount }
}

private actor PriorityRecordingLoader: PriorityThumbnailBatchLoader {
    private let payload: Data
    private var priorities: [ThumbnailPriority] = []

    init(payload: Data) { self.payload = payload }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        priorities.append(priority)
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }

    var recordedPriorities: [ThumbnailPriority] { priorities }
}

/// Advanceable monotonic clock for deterministic demand-window tests (no real sleeps / wall-clock reliance).
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func read() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Thread-safe fire counter for the `onImagesAvailable` arrival-wake tests (the callback is `@Sendable`).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

private final class BlockingCoverageStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)

    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock { didEnter = true }
        release.wait()
        return []
    }

    var hasEntered: Bool { lock.withLock { didEnter } }

    func recordPresent(_ uids: [PhotoUID], for key: String) {}
    func recordMissing(_ uids: [PhotoUID], for key: String) {}
}

private final class BlockingDiskProbeHook: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var exited = false
    let release = DispatchSemaphore(value: 0)

    func wait() {
        lock.withLock { entered = true }
        release.wait()
        lock.withLock { exited = true }
    }

    var hasEntered: Bool { lock.withLock { entered } }
    var hasExited: Bool { lock.withLock { exited } }
}

private final class RecordingCoverageStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var present: Set<PhotoUID> = []
    private var presentWrites = 0

    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock { present.intersection(candidates) }
    }

    func recordPresent(_ uids: [PhotoUID], for key: String) {
        guard !uids.isEmpty else { return }
        lock.withLock {
            present.formUnion(uids)
            presentWrites += 1
        }
    }

    func recordMissing(_ uids: [PhotoUID], for key: String) {
        lock.withLock { present.subtract(uids) }
    }

    var snapshot: Set<PhotoUID> { lock.withLock { present } }
    var writeCount: Int { lock.withLock { presentWrites } }
}

@Suite("MediaFeedCore")
struct ThumbnailFeedCoreTests {
    @Test func directVisibleFetchUsesPriorityAwareLoader() async throws {
        let uid = Self.uid("priority-visible")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("priority-visible"),
            loader: loader,
            configuration: Self.configuration()
        )

        #expect(await feed.decoded(for: uid) != nil)
        #expect(await loader.recordedPriorities == [.visibleNow])
    }

    @Test func concurrentDirectRequestsForSameUIDShareOneLoaderCall() async throws {
        let uid = Self.uid("direct-coalesced")
        let loader = RecordingLoader(
            payloads: [uid: Self.pngData(width: 24, height: 24)],
            delayMilliseconds: 25
        )
        let feed = ThumbnailFeedCore(
            cache: Self.cache("direct-coalesced"),
            loader: loader,
            configuration: Self.configuration()
        )

        async let first = feed.decoded(for: uid)
        async let second = feed.decoded(for: uid)

        #expect(await first != nil)
        #expect(await second != nil)
        #expect(await loader.requestCount() == 1)
    }

    @Test func everyVisibleWarmPassUsesHighestPriority() async throws {
        let first = Self.uid("visible-warm-first")
        let later = Self.uid("visible-warm-later")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-warm-priority"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: first)], limit: 1)
        try await Self.waitUntil { await loader.recordedPriorities.count == 1 }
        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: later)], limit: 1)
        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }

        #expect(await loader.recordedPriorities == [.visibleNow, .visibleNow])
    }

    @Test func equalPriorityQueueKeepsNearToFarOrder() async throws {
        let blocker = Self.uid("fifo-blocker")
        let near = Self.uid("fifo-near")
        let middle = Self.uid("fifo-middle")
        let far = Self.uid("fifo-far")
        let loader = ControlledLateLoader(payloads: [:])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("priority-fifo"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(blocker, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        for uid in [near, middle, far] {
            await feed.requestPriority(uid, priority: .nearViewportScrollAhead)
        }
        await loader.release()
        try await Self.waitUntil { await loader.requestCount() == 4 }

        #expect(await loader.requestedOrder() == [blocker, near, middle, far])
        await feed.stopPrefetch()
    }

    @Test func replacingVisibleDemandRemovesQueuedScrollAhead() async throws {
        let blocker = Self.uid("replace-blocker")
        let staleAhead = (0..<4).map { Self.uid("replace-ahead-\($0)") }
        let currentVisible = [Self.uid("replace-visible-0"), Self.uid("replace-visible-1")]
        let loader = ControlledLateLoader(payloads: [:])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("replace-visible"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(blocker, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        for uid in staleAhead {
            await feed.requestPriority(uid, priority: .nearViewportScrollAhead)
        }
        #expect(await feed.replaceVisiblePriorityDemand(currentVisible) == currentVisible.count)
        await loader.release()
        try await Self.waitUntil { await loader.requestCount() == 3 }
        try await Task.sleep(for: .milliseconds(100))

        let order = await loader.requestedOrder()
        #expect(order == [blocker] + currentVisible)
        for uid in staleAhead {
            #expect(order.contains(uid) == false)
        }
        await feed.stopPrefetch()
    }

    @Test func coverageCheckpointStoresOnlyOpaqueIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-coverage-opaque-\(UUID().uuidString)", isDirectory: true)
        let uid = PhotoUID(volumeID: "sensitive-volume-id", nodeID: "sensitive-node-id")
        let store = FileThumbnailCoverageCheckpointStore(directory: directory, scope: "account-A")
        store.recordPresent([uid], for: "thumbnail-coverage-v1")

        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(uid.volumeID))
        #expect(!text.contains(uid.nodeID))
        #expect(!text.contains(Data(uid.volumeID.utf8).base64EncodedString()))
        #expect(!text.contains(Data(uid.nodeID.utf8).base64EncodedString()))
        #expect(store.loadPresent([uid], for: "thumbnail-coverage-v1") == [uid])
    }

    @Test func coverageCheckpointWritesAreCoalescedAndFlushedAtCompletion() async throws {
        let uids = (0..<260).map { Self.uid("checkpoint-coalesce-\($0)") }
        let cache = Self.cache("checkpoint-coalesce")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let store = RecordingCoverageStore()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 4),
            coverageStore: store
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(store.snapshot == Set(uids))
        #expect(store.writeCount <= 3)
        await feed.stopPrefetch()
    }

    @Test func checkpointBootstrapDoesNotBlockVisibleDiskDecode() async throws {
        let uid = Self.uid("bootstrap-visible")
        let cache = Self.cache("bootstrap-visible")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: uid)
        let coverage = BlockingCoverageStore()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration(),
            coverageStore: coverage
        )

        let bootstrap = Task { await feed.startPrefetch([uid]) }
        try await Self.waitUntil { coverage.hasEntered }
        #expect(coverage.hasEntered)

        let warm = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid)],
            priority: .visibleNow,
            limit: 1
        )
        #expect(warm.decodedFromDisk == 1)

        coverage.release.signal()
        await bootstrap.value
        await feed.stopPrefetch()
    }

    @Test func stoppedCheckpointBootstrapCannotRestartOldCrawl() async throws {
        let uid = Self.uid("bootstrap-stale")
        let coverage = BlockingCoverageStore()
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("bootstrap-stale"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            coverageStore: coverage
        )

        let bootstrap = Task { await feed.startPrefetch([uid]) }
        try await Self.waitUntil { coverage.hasEntered }
        #expect(coverage.hasEntered)
        await feed.stopPrefetch()
        coverage.release.signal()
        await bootstrap.value
        try await Task.sleep(for: .milliseconds(100))

        #expect(await loader.requestCount() == 0)
        #expect(await feed.prefetchStatus().currentQueueLength == 0)
    }

    @Test func diskOnlyBytesWarmIntoDecodedRamWithoutNetwork() async throws {
        let uid = Self.uid("disk-only")
        let cache = Self.cache("disk")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let loader = RecordingLoader()
        let aspects = LockedAspects()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(maxConcurrentDecodes: 2),
            onDecoded: { uid, decoded in
                aspects.record(uid, aspect: decoded.aspectRatio)
            }
        )

        let before = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(before.diskThumbnail)
        #expect(!before.ramDecoded)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(result.mainThreadDecodeCount == 0)
        #expect(await loader.requestCount() == 0)
        #expect(feed.memoryDecoded(for: uid) != nil)
        #expect(aspects.value(for: uid).map { abs($0 - 2.0) < 0.2 } == true)

        let after = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(after.diskThumbnail)
        #expect(after.ramDecoded)
    }

    @Test func libraryUpdateResolutionTreatsDiskThumbnailAsSettledWithoutNetwork() async {
        let uid = Self.uid("library-update-disk")
        let cache = Self.cache("library-update-disk")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        let resolution = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: true)

        #expect(resolution.availableUIDs == [uid])
        #expect(resolution.terminalUIDs.isEmpty)
        #expect(await loader.requestCount() == 0)
    }

    @Test func libraryUpdateResolutionEnqueuesOnlyMissingNewAssetThumbnail() async throws {
        let uid = Self.uid("library-update-network")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("library-update-network"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        let initial = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: true)
        #expect(initial.availableUIDs.isEmpty)
        #expect(initial.terminalUIDs.isEmpty)
        try await Self.waitUntil { await loader.fetched(uid) }

        let settled = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: false)
        #expect(settled.availableUIDs == [uid])
        #expect(await loader.requestCount() == 1)
    }

    @Test func cancelledVisibleWarmDoesNotStartAStaleBatch() async {
        let uids = (0..<96).map { Self.uid("cancelled-warm-\($0)") }
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(
            cache: Self.cache("cancelled-warm"),
            loader: loader,
            configuration: Self.configuration(maxConcurrentDecodes: 2)
        )

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await feed.warmDecoded(
                uids.map { ThumbnailRequest(uid: $0) },
                priority: .visibleNow,
                limit: uids.count
            )
        }
        task.cancel()
        let result = await task.value

        #expect(result.requested == uids.count)
        #expect(result.decodedFromDisk == 0)
        #expect(result.queuedNetwork == 0)
        #expect(await loader.requestCount() == 0)
    }

    @Test func networkDeliveryWakesHostWhenViewportLive() async throws {
        // The crawl worker stores network arrivals to disk only. Without an arrival wake, a grid host whose
        // A visible set that does not change never re-warms those bytes into RAM, leaving the tile black until
        // the user scrolls. This proves the shared wake fires when a delivery lands while a viewport is live.
        let uid = Self.uid("wake-live")
        let cache = Self.cache("wake-live")  // The empty disk cache forces a fetch over the fake network.
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        let registration = await feed.setOnImagesAvailable { wakes.increment() }

        feed.noteVisibleDemand()  // A live viewport must wake when data arrives.
        await feed.requestPriority(uid, priority: .visibleNow)  // enqueue the disk-miss for the crawl worker

        try await Self.waitUntil { wakes.value() > 0 }
        #expect(wakes.value() > 0)
        #expect(await loader.fetched(uid))
        registration.end()
    }

    @Test func networkDeliveryWakesEveryRegisteredHost() async throws {
        let uid = Self.uid("wake-multicast")
        let cache = Self.cache("wake-multicast")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let firstWakes = Counter()
        let secondWakes = Counter()
        let firstRegistration = await feed.setOnImagesAvailable { firstWakes.increment() }
        let secondRegistration = await feed.setOnImagesAvailable { secondWakes.increment() }

        feed.noteVisibleDemand()
        await feed.requestPriority(uid, priority: .visibleNow)

        try await Self.waitUntil { firstWakes.value() > 0 && secondWakes.value() > 0 }
        #expect(firstWakes.value() > 0)
        #expect(secondWakes.value() > 0)
        #expect(await loader.fetched(uid))

        firstRegistration.end()
        secondRegistration.end()
    }

    @Test func endingOneWakeRegistrationLeavesTheOtherSubscriber() async throws {
        let uid = Self.uid("wake-end-one")
        let cache = Self.cache("wake-end-one")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let firstWakes = Counter()
        let secondWakes = Counter()
        let firstRegistration = await feed.setOnImagesAvailable { firstWakes.increment() }
        let secondRegistration = await feed.setOnImagesAvailable { secondWakes.increment() }
        firstRegistration.end()

        feed.noteVisibleDemand()
        await feed.requestPriority(uid, priority: .visibleNow)

        try await Self.waitUntil { secondWakes.value() > 0 }
        #expect(firstWakes.value() == 0)
        #expect(secondWakes.value() > 0)
        #expect(await loader.fetched(uid))

        secondRegistration.end()
    }

    @Test func backgroundCrawlDeliveryDoesNotWakeHostWithoutDemand() async throws {
        // A purely background crawl (no live viewport) must not spin the host's display loop: the wake stays
        // silent when there has been no recent visible demand.
        let uid = Self.uid("wake-idle")
        let cache = Self.cache("wake-idle")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        let registration = await feed.setOnImagesAvailable { wakes.increment() }

        await feed.startPrefetch([uid])  // crawl only; never sets visible demand
        try await Self.waitUntil { await loader.fetched(uid) }
        try await Task.sleep(for: .milliseconds(120))  // give any (erroneous) wake time to fire
        #expect(wakes.value() == 0)
        registration.end()
    }

    @Test func visiblePressureExcludesSequentialBacklogButTracksLiveDemand() async throws {
        // The Map's GPS crawl yields on `hasVisibleThumbnailPressure`. A pending whole-library sequential
        // A sequential fill must not count as pressure. The GPS crawl checks `hasPendingThumbnailWork`,
        // and the map remains responsive while the backlog is cached.
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let uids = (0..<8).map { Self.uid("pressure-\($0)") }
        let loader = RecordingLoader(delayMilliseconds: 250)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("pressure"), loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            clock: { clock.read() }
        )

        await feed.startPrefetch(uids)  // seeds the whole-library sequential backlog
        #expect(await feed.hasPendingThumbnailWork(), "sequential backlog must count as pending work")
        #expect(
            await feed.hasVisibleThumbnailPressure() == false,
            "a background fill alone must NOT register as visible pressure")

        feed.noteVisibleDemand()  // a live viewport appears
        #expect(await feed.hasVisibleThumbnailPressure(), "live demand must register as visible pressure")

        clock.advance(10)  // demand window (2 s) expires
        #expect(
            await feed.hasVisibleThumbnailPressure() == false,
            "expired demand must release the pressure so the GPS crawl resumes")
    }

    @Test func queuedVisibleThumbnailDoesNotMasqueradeAsActiveUserInteraction() async throws {
        let uid = Self.uid("stalled-visible")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("stalled-visible"),
            loader: RecordingLoader(delayMilliseconds: 10_000),
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(uid, priority: .visibleNow)
        #expect(
            await feed.hasVisibleThumbnailPressure(),
            "the pending visible thumbnail remains important to the media scheduler")
        #expect(
            feed.hasActiveUserInteraction() == false,
            "a queued or stalled thumbnail must not indefinitely block unrelated background work")

        feed.setUserInteractionActive(true)
        #expect(feed.hasActiveUserInteraction())
        feed.setUserInteractionActive(false)
        #expect(feed.hasActiveUserInteraction() == false)
        await feed.stopPrefetch()
    }

    @Test func corruptDiskBlobDoesNotStarveVisibleFetch() async throws {
        let cache = Self.cache("corrupt")
        let uid = Self.uid("corrupt")
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid))
        #expect(cache.has(uid))

        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.fetched(uid) }
        #expect(await loader.fetched(uid))
        #expect(cache.hasUsableDiskData(uid))
    }

    @Test func platformPolicyIsInjectedThroughSanitizedConfiguration() {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: -10,
            downloadConcurrencyLimit: 0,
            initialDownloadConcurrency: 99,
            minimumDownloadConcurrency: 0,
            batchSize: 0,
            decodedMemoryBudgetBytes: 0,
            maxConcurrentDecodes: 0,
            priorityQueueLimit: 0,
            sequentialScanLimit: 0,
            visibleQuietWindow: -1,
            crawlBackoffSeconds: -1,
            downloadTimeoutSeconds: 0
        )

        #expect(configuration.targetPixels == 1)
        #expect(configuration.downloadConcurrencyLimit == 1)
        #expect(configuration.initialDownloadConcurrency == 1)
        #expect(configuration.minimumDownloadConcurrency == 1)
        #expect(configuration.batchSize == 1)
        #expect(configuration.decodedMemoryBudgetBytes == 1)
        #expect(configuration.maxConcurrentDecodes == 1)
        #expect(configuration.priorityQueueLimit == 1)
        #expect(configuration.sequentialScanLimit == 1)
        #expect(configuration.visibleQuietWindow == 0)
        #expect(configuration.crawlBackoffSeconds == 0)
        #expect(configuration.downloadTimeoutSeconds == 0.1)
    }

    @Test func batchLoaderCompletesAllRequestedThumbnails() async throws {
        let uids = (0..<3).map { Self.uid("full-\($0)") }
        let cache = Self.cache("full")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 3)
        #expect(status.downloadCompleted == 3)
        #expect(status.failed == 0)
        #expect(uids.allSatisfy { cache.has($0) })
    }

    @Test func partialBatchCountsCompletedVersusFailed() async throws {
        let served = (0..<2).map { Self.uid("part-ok-\($0)") }
        let refused = (0..<2).map { Self.uid("part-no-\($0)") }
        let cache = Self.cache("partial")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: served.map { ($0, Self.pngData(width: 8, height: 8)) }),
            itemErrors: Dictionary(uniqueKeysWithValues: refused.map { ($0, "no thumbnail for node") })
        )
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(served + refused)
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.downloadCompleted == 2 && status.failed == 2
        }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 4)
        #expect(status.downloadCompleted == 2)
        #expect(status.failed == 2)
        #expect(status.failedItemError == 2)
        #expect(status.failedTimeout == 0)
        #expect(status.failedBatchError == 0)
        #expect(status.unfetchableCount == 2)
        #expect(status.lastErrors.joined().contains("no thumbnail for node"))
    }

    @Test func zeroResultBatchRecordsClassifiedFailureAndBacksOff() async throws {
        let uids = (0..<2).map { Self.uid("zero-\($0)") }
        let frozen = Date(timeIntervalSince1970: 5000)
        let loader = RecordingLoader(batchError: "simulated 429")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("zero"),
            loader: loader,
            configuration: Self.configuration(batchSize: 2),
            clock: { frozen }
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().failedBatchError == 2 }

        // With a frozen clock, the crawl backoff never expires; no further attempts may happen.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loader.requestCount() == 2)

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 2)
        #expect(status.downloadCompleted == 0)
        #expect(status.failed == 2)
        #expect(status.failedBatchError == 2)
        #expect(status.lastErrors.joined().contains("simulated 429"))
        await feed.stopPrefetch()  // frozen clock never expires the backoff; don't leave the worker looping
    }

    @Test func endOfCrawlCoverageRescanIsBoundedNotFullLibraryScan() async throws {
        // Concurrency invariant: a single end-of-crawl coverage step stats only a bounded chunk, never the
        // whole library, so no worker (and not the whole stampede of them) can hold the serial feed actor for
        // an O(library) scan that would starve a visible warm decode. Proven directly on the incremental scan.
        let feed = ThumbnailFeedCore(
            cache: Self.cache("coverage-bound"), loader: RecordingLoader(), configuration: Self.configuration())
        let library = (0..<5000).map { Self.uid("cov-\($0)") }

        let statsInOneStep = await feed.coverageScanStepStatCountForTesting(seeding: library)

        #expect(statsInOneStep < library.count)  // one actor-held step never scans the whole 5000-item library
        #expect(statsInOneStep == 512)  // it advances exactly one bounded chunk
    }

    @Test func coverageScanAbortsImmediatelyWhenViewportIsLive() async throws {
        // A live viewport aborts the coverage re-scan before it stats a single item, so a visible warm decode is
        // never blocked behind coverage maintenance. With a frozen clock, the demand stays "recent".
        let frozen = Date(timeIntervalSince1970: 5000)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("coverage-abort"), loader: RecordingLoader(),
            configuration: Self.configuration(), clock: { frozen })
        feed.noteVisibleDemand()  // synchronous (nonisolated); frozen clock keeps it recent
        let library = (0..<5000).map { Self.uid("abort-\($0)") }

        let scanned = await feed.coverageScanStepStatCountForTesting(seeding: library)

        #expect(scanned == 0)  // aborted before the first `cache.has` stat
    }

    @Test func endOfCrawlCoverageRefreshIsSingleFlightAndSkipsRedundantScan() async throws {
        // Many workers reach the drained end together, but the coverage refresh is single-flight: exactly one
        // runs. The crawl's per-item
        // `diskPresence` tracking already established full coverage during the drain, that one refresh settles
        // from the known state without a redundant full `cache.has` re-scan.
        let uids = (0..<40).map { Self.uid("single-flight-\($0)") }
        let cache = Self.cache("single-flight")
        let png = Self.pngData(width: 8, height: 8)
        for uid in uids { cache.storeToDisk(png, for: uid) }
        let feed = ThumbnailFeedCore(
            cache: cache, loader: RecordingLoader(),
            configuration: Self.configuration(downloadConcurrencyLimit: 8))

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
        try await Task.sleep(for: .milliseconds(120))  // give any stampede a chance to (wrongly) start more

        #expect(await feed.coverageRefreshStartCountForTesting() == 1)  // one refresh, not one per worker
        #expect(await feed.coverageFullScanCountForTesting() == 0)  // Known state means no redundant full sweep.
        #expect(await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0)  // and coverage is correct
        await feed.stopPrefetch()
    }

    @Test func coverageRefreshResumesAfterVisibleDemandQuiets() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let uids = (0..<20).map { Self.uid("resume-\($0)") }
        let cache = Self.cache("coverage-resume")
        let png = Self.pngData(width: 8, height: 8)
        for uid in uids { cache.storeToDisk(png, for: uid) }
        let feed = ThumbnailFeedCore(
            cache: cache, loader: RecordingLoader(),
            configuration: Self.configuration(downloadConcurrencyLimit: 4),
            clock: { clock.read() })

        feed.noteVisibleDemand()  // The live viewport at T=1000 keeps coverage refresh gated.
        await feed.startPrefetch(uids)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await feed.coverageRefreshStartCountForTesting() == 0)  // no refresh while demand is recent

        clock.advance(1.0)  // demand quiets
        try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
        #expect(await feed.coverageRefreshStartCountForTesting() >= 1)  // coverage refresh resumes once idle
        await feed.stopPrefetch()
    }

    @Test func decodedCacheHitAndMissKeyedByPhotoUID() {
        let cache = DecodedThumbnailCache(costLimit: 1_000_000)
        let a = Self.uid("dc-a")
        let b = Self.uid("dc-b")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)
        #expect(cache.image(for: a) != nil)
        #expect(cache.image(for: b) == nil)
        #expect(cache.contains(a))
        #expect(!cache.contains(b))
    }

    @Test func decodedCacheEvictsLruWhenOverBudgetAndKeepsRecentlyUsed() {
        // Budget holds exactly two 10×10×4=400-byte entries; the third eviction targets the LRU.
        let cache = DecodedThumbnailCache(costLimit: 800)
        let ids = (0..<3).map { Self.uid("dc-lru-\($0)") }
        cache.set(Self.decodedThumb(10, 10), for: ids[0], decodePixelCap: 320)
        cache.set(Self.decodedThumb(10, 10), for: ids[1], decodePixelCap: 320)
        // Touch the first item so the second becomes the eviction candidate.
        _ = cache.image(for: ids[0])
        cache.set(Self.decodedThumb(10, 10), for: ids[2], decodePixelCap: 320)

        #expect(cache.image(for: ids[0]) != nil)  // recently used survives
        #expect(cache.image(for: ids[1]) == nil)  // least-recently used evicted
        #expect(cache.image(for: ids[2]) != nil)  // just-inserted survives
        #expect(cache.snapshotForTesting().count == 2)
    }

    @Test func decodedCacheReplaceUpdatesRunningCost() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let a = Self.uid("dc-rep")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)  // 400
        #expect(cache.snapshotForTesting().cost == 400)
        cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320)
        #expect(cache.snapshotForTesting().count == 1)
        #expect(cache.snapshotForTesting().cost == 1600)
    }

    @Test func decodedCacheKeepsSingleOverBudgetItemThenReclaims() {
        // An item alone larger than the whole budget is kept (transiently over budget), then reclaimed
        // when a newer item arrives.
        let cache = DecodedThumbnailCache(costLimit: 100)
        let a = Self.uid("dc-big-a")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)  // 400 > 100, so the entry is kept.
        #expect(cache.image(for: a) != nil)
        #expect(cache.snapshotForTesting().count == 1)
        let b = Self.uid("dc-big-b")
        cache.set(Self.decodedThumb(10, 10), for: b, decodePixelCap: 320)  // Keeping b evicts the LRU (a).
        #expect(cache.image(for: b) != nil)
        #expect(cache.image(for: a) == nil)
    }

    @Test func decodedCacheSetCostLimitEvictsDownToBudget() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let ids = (0..<3).map { Self.uid("dc-shrink-\($0)") }
        for id in ids { cache.set(Self.decodedThumb(10, 10), for: id, decodePixelCap: 320) }  // 3×400 = 1200
        cache.setCostLimit(800)  // shrink to evict oldest down to ≤800
        #expect(cache.snapshotForTesting().count == 2)
        #expect(cache.snapshotForTesting().cost <= 800)
        #expect(cache.image(for: ids[2]) != nil)  // newest survives
        #expect(cache.image(for: ids[0]) == nil)  // oldest evicted
    }

    @Test func decodedCacheRemoveAllClears() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        cache.set(Self.decodedThumb(10, 10), for: Self.uid("dc-x"), decodePixelCap: 320)
        cache.removeAll()
        #expect(cache.snapshotForTesting().count == 0)
        #expect(cache.snapshotForTesting().cost == 0)
        #expect(cache.image(for: Self.uid("dc-x")) == nil)
    }

    @Test func warmReDecodesSharperWhenALargerPixelSizeIsRequested() async throws {
        // Decoded once small for a dense level, the same UID must re-decode sharper for a larger level -
        // "already decoded" is size-aware, keyed on the shared 1.25× upgrade hysteresis.
        let uid = Self.uid("upgrade")
        let cache = Self.cache("upgrade")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let small = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(small.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)  // configuration targetPixels = 16

        let sharpened = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid, pixelSize: 64)], priority: .visibleNow, limit: 1)
        #expect(sharpened.alreadyDecoded == 0)
        #expect(sharpened.decodedFromDisk == 1)  // re-decoded, not skipped
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)  // cached image actually got sharper
    }

    @Test func warmSkipsSlightlyLargerAsksWithoutChurn() async throws {
        // An ask below the 1.25× hysteresis (18 vs cap 16) must not re-decode - repeated settled frames at
        // a marginally different effective size stay free.
        let uid = Self.uid("no-churn")
        let cache = Self.cache("no-churn")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        for _ in 0..<3 {
            let again = await feed.warmDecoded(
                [ThumbnailRequest(uid: uid, pixelSize: 18)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)
    }

    @Test func sourceLimitedImageNeverReDecodesInALoop() async throws {
        // The recorded decode cap (not the achieved size) gates adequacy: a 64 px source asked for at 320
        // yields a 64 px image, and repeating the 320 ask must be a no-op, not a per-frame re-decode.
        let uid = Self.uid("src-limited")
        let cache = Self.cache("src-limited")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let first = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
        #expect(first.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)  // source-limited below the 320 ask

        for _ in 0..<3 {
            let again = await feed.warmDecoded(
                [ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        // And the render loop's retry signal agrees: nothing sharper is available for this ask.
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 320))
    }

    @Test func decodedNeedsSharperSourceReportsOnlyPresentUndersizedEntries() async throws {
        let uid = Self.uid("sharper-signal")
        let cache = Self.cache("sharper-signal")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 64))
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.decodedNeedsSharperSource(uid, forPixels: 64))  // present but materially undersized
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 18))  // A value within hysteresis is adequate.
    }

    @Test func decodedCacheUpgradeReplacesCostAndKeepsLargerOnRace() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let a = Self.uid("dc-upgrade")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16)  // 400 bytes
        cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320)  // upgrade replaces cost in place
        #expect(cache.snapshotForTesting().count == 1)
        #expect(cache.snapshotForTesting().cost == 1600)
        // A smaller concurrent decode landing last must not undo the sharp entry (cross-grid warm race).
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16)
        #expect(cache.snapshotForTesting().cost == 1600)
        #expect(cache.image(for: a)?.pixelWidth == 20)
    }

    @Test func decodedRamTierRespondsToMemoryPressureThroughFeed() async throws {
        // End-to-end through the feed: warmDecoded stores into the decoded tier; a critical pressure purge
        // drops it; restoring the budget lets a fresh decode land again.
        let uid = Self.uid("dc-pressure")
        let diskCache = Self.cache("dc-pressure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)

        feed.applyDecodedMemoryPressure(scale: 0.0, purge: true)  // Critical pressure shrinks the budget and purges.
        #expect(feed.memoryDecoded(for: uid) == nil)

        feed.applyDecodedMemoryPressure(scale: 1.0, purge: false)  // Restore the full budget.
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)  // decodes land again
    }

    @Test func memoryOnlyRenderReadPathNeverFallsThroughToDiskOrDecode() async throws {
        // The per-frame render read (`memoryDecoded`) must be a pure RAM lookup: bytes sitting on disk must
        // not be silently read/decrypted/decoded by it - that is warmDecoded's (off-render) job. A nil here
        // despite disk-present bytes is the proof; after an explicit warm the same read serves from RAM.
        let uid = Self.uid("render-pure")
        let diskCache = Self.cache("render-pure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(diskCache.hasUsableDiskData(uid))  // bytes are on disk…
        #expect(feed.memoryDecoded(for: uid) == nil)  // …but the render read does no disk work
        #expect(feed.memoryDecoded(for: uid) == nil)  // stable: repeated reads stay memory-only

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)  // the off-render warm fills the RAM tier
    }

    @Test func backgroundCachedDecodeNeverStartsNetworkWork() async {
        let present = Self.uid("background-cache-hit")
        let missing = Self.uid("background-cache-miss")
        let cache = Self.cache("background-cache")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: present)
        let loader = RecordingLoader(payloads: [missing: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        let decoded = await feed.backgroundCachedDecoded(for: present)
        #expect(decoded?.pixelWidth == 16)
        #expect(decoded?.pixelHeight == 8)
        #expect(feed.memoryDecoded(for: present) == nil)
        #expect(await feed.backgroundCachedDecoded(for: missing) == nil)
        #expect(await loader.requestCount() == 0)
    }

    @Test func oldFeedCannotPublishThumbnailAfterAccountSwitch() async {
        let uid = Self.uid("old-feed-after-account-switch")
        let cache = Self.cache("old-feed-after-account-switch")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration()
        )

        let beforeSwitch = await feed.backgroundThumbnailDecodeResult(for: uid)
        guard case .decoded = beforeSwitch else {
            Issue.record("the account-A thumbnail must decode before the account switch")
            return
        }

        cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
        cache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let afterSwitch = await feed.backgroundThumbnailDecodeResult(for: uid)
        guard case .missing = afterSwitch else {
            Issue.record("an account-A feed must not publish account-B disk data")
            return
        }
    }

    @Test func diskHitsDoNotBecomeDownloads() async throws {
        let uids = (0..<3).map { Self.uid("disk-hit-\($0)") }
        let cache = Self.cache("diskhits")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskHit >= 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 0)
        #expect(status.failed == 0)
        #expect(await loader.requestCount() == 0)
    }

    @Test func removedValidatedBlobFallsBackToNetwork() async throws {
        let uid = Self.uid("validated-then-removed")
        let cache = Self.cache("validated-then-removed")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        #expect(cache.hasUsableDiskData(uid))
        try FileManager.default.removeItem(at: cache.diskURL(for: uid))

        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 16, height: 16)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        let warm = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid)],
            priority: .visibleNow,
            limit: 1
        )
        #expect(warm.queuedNetwork == 1)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        #expect(await loader.fetched(uid))
    }

    @Test func diskHitOnlyCrawlPersistsCheckpointForRelaunch() async throws {
        // When a whole crawl is already on disk, no network batch runs. The checkpoint still must advance to
        // the end, otherwise the next app launch reports the full library as pending previews and counts down
        // through a redundant disk scan.
        let uids = (0..<12).map { Self.uid("disk-checkpoint-\($0)") }
        let cache = Self.cache("disk-checkpoint")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }

        let firstFeed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await firstFeed.startPrefetch(uids)
        try await Self.waitUntil { await firstFeed.prefetchStatus().currentQueueLength == 0 }
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        #expect(await firstFeed.prefetchStatus().diskHit >= uids.count)
        await firstFeed.stopPrefetch()

        let relaunchedFeed = ThumbnailFeedCore(
            cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await relaunchedFeed.startPrefetch(uids)
        try await Self.waitUntil { await relaunchedFeed.prefetchStatus().diskCoverageVerified }
        let relaunched = await relaunchedFeed.prefetchStatus()
        #expect(relaunched.currentQueueLength == 0)
        #expect(relaunched.diskFileCount == uids.count)
        await relaunchedFeed.stopPrefetch()
    }

    @Test func coverageCheckpointSkipsKnownUIDsButFetchesNewRemoteUIDs() async throws {
        let cached = (0..<8).map { Self.uid("persist-known-\($0)") }
        let newFirst = Self.uid("persist-new-first")
        let newLast = Self.uid("persist-new-last")
        let cache = Self.cache("persist-known")
        let firstStore = Self.checkpointStore(for: cache)
        let firstLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: cached.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let firstFeed = ThumbnailFeedCore(
            cache: cache,
            loader: firstLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: firstStore
        )

        await firstFeed.startPrefetch(cached)
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        #expect(await firstLoader.requestCount() == cached.count)
        await firstFeed.stopPrefetch()

        let relaunchedStore = Self.checkpointStore(for: cache)
        let relaunchedLoader = RecordingLoader(
            payloads: [
                newFirst: Self.pngData(width: 8, height: 8),
                newLast: Self.pngData(width: 8, height: 8),
            ]
        )
        let relaunchedFeed = ThumbnailFeedCore(
            cache: cache,
            loader: relaunchedLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: relaunchedStore
        )

        await relaunchedFeed.startPrefetch([newFirst] + cached + [newLast])
        try await Self.waitUntil { await relaunchedFeed.prefetchStatus().diskCoverageVerified }

        #expect(await relaunchedLoader.requestCount() == 2)
        #expect(await relaunchedLoader.fetched(newFirst))
        #expect(await relaunchedLoader.fetched(newLast))
        for uid in cached {
            #expect(await relaunchedLoader.fetched(uid) == false)
        }
        #expect(cache.hasUsableDiskData(newFirst))
        #expect(cache.hasUsableDiskData(newLast))
        await relaunchedFeed.stopPrefetch()
    }

    @Test func cacheClearInvalidatesPersistentCoverageCheckpoint() async throws {
        let uids = (0..<6).map { Self.uid("clear-checkpoint-\($0)") }
        let cache = Self.cache("clear-checkpoint")
        let firstLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let firstFeed = ThumbnailFeedCore(
            cache: cache,
            loader: firstLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await firstFeed.startPrefetch(uids)
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        await firstFeed.stopPrefetch()

        await cache.clear()

        let afterClearLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let afterClearFeed = ThumbnailFeedCore(
            cache: cache,
            loader: afterClearLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await afterClearFeed.startPrefetch(uids)
        try await Self.waitUntil { await afterClearFeed.prefetchStatus().downloadCompleted == uids.count }
        #expect(await afterClearLoader.requestCount() == uids.count)
        await afterClearFeed.stopPrefetch()
    }

    @Test func liveCacheClearRestartsCurrentCrawlWithoutStaleCoverage() async throws {
        let uids = (0..<4).map { Self.uid("live-clear-\($0)") }
        let cache = Self.cache("live-clear")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }
        #expect(await loader.requestCount() == uids.count)

        await feed.clearCacheAndRestartPrefetch()
        try await Self.waitUntil { await loader.requestCount() == uids.count * 2 }
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        for uid in uids { #expect(cache.hasUsableDiskData(uid)) }
        #expect(await feed.prefetchStatus().diskFileCount == uids.count)
        await feed.stopPrefetch()
    }

    @Test func implausibleCoverageCheckpointFallsBackToDiskVerification() async throws {
        let present = Self.uid("implausible-present")
        let missing = Self.uid("implausible-missing")
        let cache = Self.cache("implausible-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, missing], for: "thumbnail-coverage-v1")
        let loader = RecordingLoader(payloads: [missing: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, missing])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(missing))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func equalCountCheckpointReplacementStillRefetchesRemovedUID() async throws {
        let present = Self.uid("equal-count-present")
        let removed = Self.uid("equal-count-removed")
        let replacement = Self.uid("equal-count-replacement")
        let cache = Self.cache("equal-count-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: removed)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, removed], for: "thumbnail-coverage-v1")

        // Keep the directory file count unchanged while removing one checkpoint member.
        try FileManager.default.removeItem(at: cache.diskURL(for: removed))
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: replacement)
        #expect(cache.diskFileCount() == 2)

        let loader = RecordingLoader(payloads: [removed: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, removed])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(removed))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func equalCountCheckpointDoesNotTrustCorruptedValidatedBlob() async throws {
        let present = Self.uid("equal-count-corrupt-present")
        let corrupted = Self.uid("equal-count-corrupt-member")
        let cache = Self.cache("equal-count-corrupt-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: corrupted)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, corrupted], for: "thumbnail-coverage-v1")

        // `storeToDisk` memoizes both blobs as authenticated. Corrupt one afterward while retaining
        // the same filename and directory count; checkpoint bootstrap must authenticate it again.
        try Data(repeating: 0xA5, count: 64).write(to: cache.diskURL(for: corrupted), options: .atomic)
        #expect(cache.diskFileCount() == 2)

        let loader = RecordingLoader(payloads: [corrupted: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, corrupted])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(corrupted))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func destructiveClearRejectsLateNonCooperativeThumbnailWriter() async throws {
        let uid = Self.uid("late-thumbnail-after-clear")
        let cache = Self.cache("late-thumbnail-after-clear")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }
        await feed.stopPrefetch()
        await cache.clear()
        await loader.release()
        try await Self.waitUntil { await loader.finishedBatches() >= 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(cache.has(uid) == false)
    }

    @Test func ownerTeardownJoinsCancellationIgnoringPrefetchWorker() async throws {
        let uid = Self.uid("owner-teardown-join")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-join"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()

        #expect(returned.value() == 0, "owner teardown must join a cancellation-ignoring loader")
        await loader.release()
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
    }

    @Test func ownerTeardownJoinsCancellationIgnoringDirectDecodeFlight() async throws {
        let uid = Self.uid("owner-teardown-direct-decode")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-direct-decode"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()
        let request = Task { await feed.decoded(for: uid) }

        try await Self.waitUntil { await loader.requestCount() == 1 }
        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()

        #expect(returned.value() == 0, "teardown must join a coalesced direct loader owned by the feed")
        await loader.release()
        _ = await request.value
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
    }

    @Test func ownerTeardownJoinsWorkerRetiredByPrefetchRestart() async throws {
        let firstUID = Self.uid("owner-teardown-restarted-first")
        let secondUID = Self.uid("owner-teardown-restarted-second")
        let payload = Self.pngData(width: 8, height: 8)
        let loader = PerUIDControlledLateLoader(payloads: [firstUID: payload, secondUID: payload])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-restarted"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()

        await feed.startPrefetch([firstUID])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        await loader.release(secondUID)
        await feed.startPrefetch([secondUID])

        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()
        #expect(returned.value() == 0, "teardown must retain workers replaced by a later prefetch")

        await loader.release(firstUID)
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
        #expect(
            await loader.requestCount() == 1,
            "a replacement loader must not bypass the cancellation-ignoring owner's concurrency slot")
    }

    @Test func accountChangeRejectsLateThumbnailOwner() async throws {
        let uid = Self.uid("late-thumbnail-after-account-change")
        let cache = Self.cache("late-thumbnail-after-account-change")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
        await loader.release()
        try await Self.waitUntil { await loader.finishedBatches() == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(cache.has(uid) == false)
        #expect(cache.diskData(for: uid) == nil)
        #expect(feed.memoryDecoded(for: uid) == nil)
        await feed.stopPrefetch()
    }

    @Test func staleDiskProbeCannotPublishAfterAccountSwitch() async throws {
        let uid = Self.uid("stale-disk-probe-after-account-switch")
        let cache = Self.cache("stale-disk-probe-after-account-switch")
        let store = RecordingCoverageStore()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            coverageStore: store
        )
        let probeGate = BlockingDiskProbeHook()
        feed.setDiskProbeHookForTesting { probeGate.wait() }

        await feed.startPrefetch([uid])
        try await Self.waitUntil { probeGate.hasEntered }

        cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        probeGate.release.signal()
        try await Self.waitUntil { probeGate.hasExited }
        await feed.stopPrefetch()

        #expect(store.snapshot.isEmpty, "an old feed must not checkpoint a post-switch disk probe")
    }

    @Test func prefetchStatusReportsIncrementalDiskCoverage() async throws {
        let cached = (0..<2).map { Self.uid("coverage-cached-\($0)") }
        let missing = Self.uid("coverage-missing")
        let cache = Self.cache("coverage")
        for uid in cached { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader(itemErrors: [missing: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch(cached + [missing])
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.diskHit >= cached.count && status.failedItemError == 1
        }

        let status = await feed.prefetchStatus()
        #expect(status.diskThumbnailTotal == 3)
        #expect(status.diskFileCount == 2)
        #expect(status.diskThumbnailCoverageFraction == 2.0 / 3.0)
        #expect(await loader.requestCount() == 1)
    }

    @Test func timeoutDoesNotDoubleCountCompletionOrFailure() async throws {
        let uid = Self.uid("timeout")
        let cache = Self.cache("timeout")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }

        let atTimeout = await feed.prefetchStatus()
        #expect(atTimeout.downloadStarted == 1)
        #expect(atTimeout.downloadCompleted == 0)
        #expect(atTimeout.failed == 1)

        // The uncancellable loader finishes only after the test explicitly releases it. This avoids racing a
        // real-time loader delay against the timeout task when the complete package suite is under heavy load.
        await loader.release()
        // Its bytes land on disk, but the batch was
        // already accounted: failed stays 1, completed stays 0 (never both for one item).
        try await Self.waitUntil { await loader.finishedBatches() >= 1 }
        try await Self.waitUntil { cache.has(uid) }
        let afterLateDelivery = await feed.prefetchStatus()
        #expect(afterLateDelivery.downloadCompleted == 0)
        #expect(afterLateDelivery.failed == 1)
        #expect(afterLateDelivery.downloadStarted == 1)

        // The late-delivered blob is now a disk hit: a new visible request must not re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.requestCount() == 1)
    }

    @Test func timedOutSDKLoaderKeepsItsConcurrencySlotUntilItReturns() async throws {
        let uids = (0..<6).map { Self.uid("timeout-bound-\($0)") }
        let loader = NonCooperativeLoader(delay: .seconds(1))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("timeout-bound"),
            loader: loader,
            configuration: Self.configuration(
                downloadConcurrencyLimit: 1,
                batchSize: 1,
                crawlBackoffSeconds: 0,
                downloadTimeoutSeconds: 0.1
            )
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }
        try await Task.sleep(for: .milliseconds(350))

        #expect(await loader.requestCount() == 1)
        #expect(await feed.prefetchStatus().downloadsInFlight == 1)
        await feed.stopPrefetch()
    }

    @Test func timeoutCancelsCooperativeLoaderAndCrawlContinues() async throws {
        let uids = (0..<3).map { Self.uid("timeout-cancel-\($0)") }
        let loader = CancellationAwareLoader(delay: .seconds(10))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("timeout-cancel"),
            loader: loader,
            configuration: Self.configuration(
                downloadConcurrencyLimit: 1,
                batchSize: 1,
                crawlBackoffSeconds: 0,
                downloadTimeoutSeconds: 0.1
            )
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await loader.cancellations() >= 2 }

        #expect(await loader.requestCount() >= 2)
        #expect(await feed.prefetchStatus().failedTimeout >= 2)
        await feed.stopPrefetch()
    }

    @Test func interactionSignalDoesNotPauseThumbnailPrefetch() async throws {
        let uids = (0..<2).map { Self.uid("interact-\($0)") }
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: Self.cache("interact"), loader: loader, configuration: Self.configuration())

        feed.setUserInteractionActive(true)
        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 2 }
        let status = await feed.prefetchStatus()
        #expect(!status.paused)
        #expect(status.pausedReason == "none")
        #expect(await loader.requestCount() == 2)
        feed.setUserInteractionActive(false)
    }

    @Test func refusedItemsAreQuarantinedUntilNextCrawlStart() async throws {
        let uid = Self.uid("refused")
        let loader = RecordingLoader(itemErrors: [uid: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedItemError == 1 }
        #expect(await loader.requestCount() == 1)

        // Same crawl: the refused uid is quarantined - a new priority request must not re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await feed.prefetchStatus().skippedUnfetchable >= 1 }
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start clears the quarantine and retries exactly once.
        await feed.startPrefetch([uid])
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 2 }
        #expect(await loader.requestCount() == 2)
    }

    @Test func visiblePathDoesNotRefetchBackendRefusedItems() async throws {
        let uid = Self.uid("visible-refused")
        let loader = RecordingLoader(itemErrors: [uid: "Node has no thumbnails"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        // First visible request hits the loader and learns the refusal…
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)
        // …every further visibility is short-circuited for this crawl.
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start retries once (the node may have gained a thumbnail since).
        await feed.startPrefetch([])
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 2)
    }

    @Test func diagnosticsExplainEveryFailure() async throws {
        let refused = Self.uid("diag-refused")
        let loader = RecordingLoader(itemErrors: [refused: "decrypt failed"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("diag"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([refused])
        try await Self.waitUntil { await feed.prefetchStatus().failed == 1 }

        let status = await feed.prefetchStatus()
        // failed=N must decompose into the classified buckets…
        #expect(
            status.failed == status.failedTimeout + status.failedBatchError + status.failedItemError
                + status.failedUnreported)
        #expect(status.failedItemError == 1)
        // …and the human-readable reason must be surfaced.
        #expect(status.lastErrors.joined().contains("decrypt failed"))
    }

    private static func configuration(
        targetPixels: CGFloat = 16,
        downloadConcurrencyLimit: Int = 2,
        batchSize: Int = 2,
        maxConcurrentDecodes: Int = 1,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 0.25,
        downloadTimeoutSeconds: Double = 1
    ) -> ThumbnailFeedCoreConfiguration {
        ThumbnailFeedCoreConfiguration(
            targetPixels: targetPixels,
            downloadConcurrencyLimit: downloadConcurrencyLimit,
            initialDownloadConcurrency: 1,
            minimumDownloadConcurrency: 1,
            batchSize: batchSize,
            decodedMemoryBudgetBytes: 16 * 1024 * 1024,
            maxConcurrentDecodes: maxConcurrentDecodes,
            priorityQueueLimit: 16,
            sequentialScanLimit: 16,
            visibleQuietWindow: visibleQuietWindow,
            crawlBackoffSeconds: crawlBackoffSeconds,
            downloadTimeoutSeconds: downloadTimeoutSeconds
        )
    }

    private static func cache(_ prefix: String) -> ThumbnailCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-feed-core-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = ThumbnailCache(
            namespace: "feed-core-\(prefix)-\(UUID().uuidString)",
            rootDirectory: root
        )
        cache.configure(accountUID: "acct-A", key: feedCacheTestKey)
        return cache
    }

    private static func checkpointStore(for cache: ThumbnailCache) -> FileThumbnailCoverageCheckpointStore {
        FileThumbnailCoverageCheckpointStore(
            directory: cache.coverageCheckpointDirectory(),
            scope: cache.coverageCheckpointScope()
        )
    }

    private static func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "vol", nodeID: "\(id)-\(UUID().uuidString)")
    }

    private static func pngData(width: Int, height: Int) -> Data {
        makePNGData(width: width, height: height)
    }

    /// A decoded thumbnail with a known pixel size has deterministic `decodedCostBytes` (width*height*4) for
    /// cost/eviction assertions.
    private static func decodedThumb(_ width: Int, _ height: Int) -> DecodedThumbnail {
        DecodedThumbnail(image: makeCGImage(width: width, height: height))
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<60 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@Suite("MediaFeedCore platform purity")
struct ThumbnailFeedCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaFeedCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CryptoKit",
        "Foundation",
        "MediaByteCache",
        "MediaDecodingCore",
        "PhotosCore",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "MediaFeedCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(
            seen.subtracting(Self.allowedFrameworkImports).isEmpty,
            "Unexpected MediaFeedCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageOrHardwarePolicyTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            violations.isEmpty,
            "MediaFeedCore must not reference platform UI types or hardware policy:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}

private final class LockedAspects: @unchecked Sendable {
    private let lock = NSLock()
    private var aspects: [PhotoUID: CGFloat] = [:]

    func record(_ uid: PhotoUID, aspect: CGFloat) {
        lock.withLock {
            aspects[uid] = aspect
        }
    }

    func value(for uid: PhotoUID) -> CGFloat? {
        lock.withLock { aspects[uid] }
    }
}

private func makeCGImage(width: Int, height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = 160
        pixels[offset + 1] = 90
        pixels[offset + 2] = 50
        pixels[offset + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makePNGData(width: Int, height: Int) -> Data {
    let image = makeCGImage(width: width, height: height)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
