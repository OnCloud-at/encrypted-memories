import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

/// A video failure offers Retry only when a new attempt can change it, and a rate limit stays behind the loading
/// indicator while the viewer prepares the video and asks again.
final class VideoFailureRetryTests: XCTestCase {
    private let fixedFailures: [VideoPlaybackError] = [
        .notVideo, .unsupportedCodec, .streamURLUnavailable, .decryptionFailed,
    ]
    private let changeableFailures: [VideoPlaybackError] = [
        .metadataUnavailable, .rangeNotSupported, .networkUnavailable, .authExpired, .quotaOrRateLimited,
        .localFileError, .playerItemFailed(detail: nil), .timedOut, .unknown(detail: nil),
    ]

    func testOnlyAFailureThatANewAttemptCannotChangeHidesRetry() {
        for failure in fixedFailures {
            XCTAssertFalse(failure.isRetryable, "\(failure.token) does not change when the person asks again")
        }
        for failure in changeableFailures {
            XCTAssertTrue(failure.isRetryable, "\(failure.token) can work on another attempt")
        }
    }

    func testTheProductionWaitsOfARateLimitAreThreeEightAndTwentySeconds() {
        let production: [Duration] = [.seconds(3), .seconds(8), .seconds(20)]
        XCTAssertEqual(VideoPlaybackError.rateLimitSilentRetryDelays, production)
        XCTAssertEqual(VideoPlaybackError.quotaOrRateLimited.silentRetryDelays, production)
        for failure in fixedFailures + changeableFailures where failure != .quotaOrRateLimited {
            XCTAssertTrue(failure.silentRetryDelays.isEmpty, "\(failure.token) shows its failure at once")
        }
    }

    func testAFailureWithATypedCauseIsClassifiedByItsType() {
        XCTAssertEqual(VideoPlaybackError.classify(TypedFailure(cause: .decryptionFailed)), .decryptionFailed)
        XCTAssertNotEqual(VideoPlaybackError.classify(TypedFailure(cause: nil)), .decryptionFailed)
    }

    // MARK: - Silent retries

    @MainActor
    func testARateLimitIsRetriedWithTheProductionWaitsAndThenShowsTheFailure() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait)
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil || wait.requested.count > 3 }
        let calls = await streamer.calls
        XCTAssertEqual(wait.requested, [.seconds(3), .seconds(8), .seconds(20)])
        XCTAssertEqual(calls, 4, "the first attempt and one attempt after each wait")
        XCTAssertEqual(model.videoState, .failed(.quotaOrRateLimited))
        XCTAssertEqual(model.videoState.error?.isRetryable, true)
    }

    @MainActor
    func testARateLimitAsksAgainBehindTheLoadingIndicatorAndShowsTheFinalFailure() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit, Self.rateLimit, Self.codec])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.milliseconds(1), .milliseconds(1)])
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "two silent retries, then the answer of the third attempt")
        XCTAssertEqual(model.videoState, .failed(.unsupportedCodec))
        XCTAssertEqual(model.videoState.errorMessage, VideoPlaybackError.unsupportedCodec.userMessage)
    }

    @MainActor
    func testARateLimitShowsNoFailureWhileTheViewerWaitsAndAsksAgainWhenTheWaitEnds() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit, Self.codec])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        defer { model.stop() }
        model.start()

        try await waitUntil { wait.requested.count == 1 }
        XCTAssertEqual(model.videoState, .resolving, "the wait shows the loading indicator")
        XCTAssertNil(model.videoState.error)
        let callsWhileWaiting = await streamer.calls
        XCTAssertEqual(callsWhileWaiting, 1)

        wait.release()
        try await waitUntil { model.videoState.error != nil }
        let callsAfterRelease = await streamer.calls
        XCTAssertEqual(callsAfterRelease, 2)
        XCTAssertEqual(model.videoState, .failed(.unsupportedCodec))
    }

    @MainActor
    func testAFixedFailureShowsAtOnceAndHidesRetry() async throws {
        let streamer = ScriptedStreamProvider(failures: [TypedFailure(cause: .decryptionFailed)])
        let wait = ControlledWait()
        let model = try makeModel(streamer: streamer, wait: wait)
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(wait.requested.isEmpty)
        XCTAssertEqual(model.videoState, .failed(.decryptionFailed))
        XCTAssertEqual(model.videoState.error?.isRetryable, false)
    }

    @MainActor
    func testAHostWithoutAStreamProviderHidesRetry() async throws {
        let model = try makeModel(streamer: nil, wait: ControlledWait())
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil }
        XCTAssertEqual(model.videoState, .failed(.streamURLUnavailable))
        XCTAssertEqual(model.videoState.error?.isRetryable, false)
    }

    // MARK: - The wait ends with the viewer

    @MainActor
    func testClosingTheViewerEndsTheWaitWithoutAnotherAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.stop()
        try await waitUntil { wait.ended == 1 }
        await settle(streamer)
        let calls = await streamer.calls
        XCTAssertEqual(wait.ended, 1, "the sleeper ended by cancellation, without a release")
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testAWaitThatEndsAfterTheViewerClosedStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60)])
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.stop()
        wait.release()
        try await waitUntil { wait.ended == 1 }
        await settle(streamer)
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testMovingToAnotherItemEndsTheWaitOfTheOldItem() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true)
        let model = try makeModel(
            items: [Self.video(0), Self.video(1)], streamer: streamer, wait: wait, delays: [.seconds(60)])
        defer { model.stop() }
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.next()
        try await waitUntil { wait.ended == 1 }
        await settle(streamer)
        let oldItemCalls = await streamer.calls(for: "n0")
        XCTAssertEqual(oldItemCalls, 1, "the old item asks no second time")
    }

    @MainActor
    func testAWaitOfTheOldItemThatEndsAfterTheMoveStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(
            items: [Self.video(0), Self.video(1)], streamer: streamer, wait: wait, delays: [.seconds(60)])
        defer { model.stop() }
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.next()
        try await waitUntil { wait.requested.count == 2 }  // the new item waits for its own rate limit
        wait.release()
        try await waitUntil { wait.ended == 2 }
        await settle(streamer)
        let oldItemCalls = await streamer.calls(for: "n0")
        XCTAssertEqual(oldItemCalls, 1, "a stale wait of the old item does not ask again")
    }

    @MainActor
    func testReloadingTheSameItemReplacesTheOldWait() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let model = try makeModel(streamer: streamer, wait: wait, delays: [.seconds(60), .seconds(60)])
        defer { model.stop() }
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        model.retry()  // the same item loads again; the old load is replaced
        try await waitUntil { wait.requested.count == 2 }
        wait.release()  // the stale wait ends first, then the current one
        try await waitUntil { wait.ended == 2 && wait.requested.count == 3 }
        await settle(streamer)
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "first load, reload, and one attempt after the wait of the reload")
    }

    @MainActor
    func testAWaitThatEndsAfterTheSessionChangedStartsNoAttempt() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let wait = ControlledWait(holds: true, endsOnCancellation: false)
        let previewRoot = Self.temporaryRoot(self)
        let previewCache = ThumbnailCache(namespace: "video-retry-session", rootDirectory: previewRoot)
        let model = try makeModel(
            streamer: streamer, wait: wait, delays: [.seconds(60)], previewCache: previewCache)
        defer { model.stop() }
        model.start()
        try await waitUntil { wait.requested.count == 1 }

        previewCache.configure(accountUID: "another-account", key: nil)  // sign-out or account switch
        wait.release()
        try await waitUntil { wait.ended == 1 }
        await settle(streamer)
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Helpers

    private static let rateLimit = NSError(
        domain: "ProtonAuth", code: 429,
        userInfo: [NSLocalizedDescriptionKey: "HTTP 429 for /drive/x"])
    private static let codec = NSError(domain: "AVFoundationErrorDomain", code: -11828)

    private static func video(_ number: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n\(number)"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "video/mp4")
    }

    private static func temporaryRoot(_ test: XCTestCase) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-retry-\(UUID())")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// `delays` replaces the waits of a rate limit; nil keeps the production waits.
    @MainActor
    private func makeModel(
        items: [PhotoItem] = [VideoFailureRetryTests.video(0)], streamer: ScriptedStreamProvider?,
        wait: ControlledWait, delays: [Duration]? = nil, previewCache: ThumbnailCache? = nil
    ) throws -> PhotoViewerModel {
        let provider = FailingPreviewProvider()
        let feed = ThumbnailFeed(
            cache: ThumbnailCache(namespace: "video-retry", rootDirectory: Self.temporaryRoot(self)),
            loader: provider)
        let waitForDelay: (Duration) async -> Void = { await wait.wait($0) }
        guard let delays else {
            return PhotoViewerModel(
                items: items, index: 0, feed: feed, media: provider, streamer: streamer,
                previewCache: previewCache, silentRetryWait: waitForDelay)
        }
        return PhotoViewerModel(
            items: items, index: 0, feed: feed, media: provider, streamer: streamer, previewCache: previewCache,
            silentRetryDelays: { failure in failure == .quotaOrRateLimited ? delays : [] },
            silentRetryWait: waitForDelay)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the viewer did not reach the expected state")
        throw CancellationError()
    }

    /// Lets the main-actor jobs of the model run, and the stream provider answer every call that they started. A job
    /// that a cancelled wait resumed has run after these turns, so an attempt it started shows in `calls`.
    @MainActor
    private func settle(_ streamer: ScriptedStreamProvider) async {
        for _ in 0..<20 {
            await Task.yield()
            _ = await streamer.calls
        }
    }
}

/// An error that names its playback failure, like the typed errors of the Drive backend.
private struct TypedFailure: VideoPlaybackClassifiable {
    let cause: VideoPlaybackError?
    var videoPlaybackError: VideoPlaybackError? { cause }
}

private actor ScriptedStreamProvider: VideoStreamProvider {
    private let failures: [any Error]
    private var nodeIDs: [String] = []

    init(failures: [any Error]) { self.failures = failures }

    var calls: Int { nodeIDs.count }

    func calls(for nodeID: String) -> Int { nodeIDs.filter { $0 == nodeID }.count }

    func prefetchEncrypted(for uid: PhotoUID) async throws {}

    /// The failures in order; the last one repeats.
    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        nodeIDs.append(uid.nodeID)
        throw failures[max(0, min(nodeIDs.count, failures.count) - 1)]
    }
}

/// The wait between two silent retries, which a test holds and releases. `holds: false` returns at once. A held wait
/// ends when the test releases it, or when its task is cancelled unless `endsOnCancellation` is false.
private final class ControlledWait: @unchecked Sendable {
    private let lock = NSLock()
    private let holds: Bool
    private let endsOnCancellation: Bool
    private var delays: [Duration] = []
    private var endedCount = 0
    private var parked: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resumedEarly: Set<Int> = []
    private var nextID = 0

    init(holds: Bool = false, endsOnCancellation: Bool = true) {
        self.holds = holds
        self.endsOnCancellation = endsOnCancellation
    }

    /// The delays that the model asked for, in order.
    var requested: [Duration] { lock.withLock { delays } }
    /// The number of waits that have ended.
    var ended: Int { lock.withLock { endedCount } }

    func wait(_ delay: Duration) async {
        let id = lock.withLock { () -> Int in
            delays.append(delay)
            nextID += 1
            return nextID
        }
        if holds {
            if endsOnCancellation {
                await withTaskCancellationHandler {
                    await park(id)
                } onCancel: {
                    resume(id)
                }
            } else {
                await park(id)
            }
        }
        lock.withLock { endedCount += 1 }
    }

    /// Ends every held wait, the oldest first.
    func release() {
        let ids = lock.withLock { parked.map(\.id) }
        for id in ids { resume(id) }
    }

    private func park(_ id: Int) async {
        await withCheckedContinuation { continuation in
            let early = lock.withLock { () -> Bool in
                if resumedEarly.remove(id) != nil { return true }
                parked.append((id, continuation))
                return false
            }
            if early { continuation.resume() }
        }
    }

    private func resume(_ id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = parked.firstIndex(where: { $0.id == id }) else {
                resumedEarly.insert(id)
                return nil
            }
            return parked.remove(at: index).continuation
        }
        continuation?.resume()
    }
}

private struct FailingPreviewProvider: FullMediaProvider, ThumbnailBatchLoader {
    func preview(for uid: PhotoUID) async throws -> Data { throw VideoStreamError.notAVideo }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw VideoStreamError.notAVideo
    }
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
