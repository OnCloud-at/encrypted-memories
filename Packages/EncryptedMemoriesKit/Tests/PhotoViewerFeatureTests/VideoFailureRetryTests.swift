import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

/// A video failure offers Retry only when a new attempt can change it, and a rate limit stays behind the loading
/// indicator while the viewer asks again.
final class VideoFailureRetryTests: XCTestCase {
    private let fixedFailures: [VideoPlaybackError] = [
        .notVideo, .unsupportedCodec, .streamURLUnavailable, .rangeNotSupported, .decryptionFailed,
    ]
    private let changeableFailures: [VideoPlaybackError] = [
        .metadataUnavailable, .networkUnavailable, .authExpired, .quotaOrRateLimited, .localFileError,
        .playerItemFailed(detail: nil), .timedOut, .unknown(detail: nil),
    ]

    func testOnlyAFailureThatANewAttemptCanChangeOffersRetry() {
        for failure in fixedFailures {
            XCTAssertFalse(failure.isRetryable, "\(failure.token) does not change when the person asks again")
        }
        for failure in changeableFailures {
            XCTAssertTrue(failure.isRetryable, "\(failure.token) can work on another attempt")
        }
    }

    func testOnlyARateLimitIsRetriedSilentlyAndTheWaitsGrow() {
        for failure in fixedFailures + changeableFailures where failure != .quotaOrRateLimited {
            XCTAssertTrue(failure.silentRetryDelays.isEmpty, "\(failure.token) shows its failure at once")
        }
        let delays = VideoPlaybackError.quotaOrRateLimited.silentRetryDelays
        XCTAssertFalse(delays.isEmpty)
        XCTAssertEqual(delays, delays.sorted())
    }

    @MainActor
    func testARateLimitAsksAgainBehindTheLoadingIndicatorAndShowsTheFinalFailure() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit, Self.rateLimit, Self.codec])
        let model = try makeModel(streamer: streamer, delays: [.milliseconds(1), .milliseconds(1)])
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "two silent retries, then the answer of the third attempt")
        XCTAssertEqual(model.videoState, .failed(.unsupportedCodec))
        XCTAssertEqual(model.videoState.errorMessage, VideoPlaybackError.unsupportedCodec.userMessage)
    }

    @MainActor
    func testARateLimitShowsNoFailureWhileTheViewerWaitsToAskAgain() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let consulted = Counter()
        let model = try makeModel(streamer: streamer, delays: [.seconds(60)], consulted: consulted)
        defer { model.stop() }
        model.start()

        try await waitUntil { consulted.value == 1 }
        // The wait starts in the same main-actor step that consulted the delays, so the state shows the wait.
        XCTAssertEqual(model.videoState, .resolving)
        XCTAssertNil(model.videoState.error)
        let calls = await streamer.calls
        XCTAssertEqual(calls, 1)

        // Closing the viewer, or moving to the next item, ends the wait without another attempt.
        model.stop()
        try await Task.sleep(for: .milliseconds(300))
        let callsAfterStop = await streamer.calls
        XCTAssertEqual(callsAfterStop, 1)
    }

    @MainActor
    func testARateLimitThatLastsShowsRetryAfterTheLastSilentRetry() async throws {
        let streamer = ScriptedStreamProvider(failures: [Self.rateLimit])
        let model = try makeModel(streamer: streamer, delays: [.milliseconds(1), .milliseconds(1)])
        defer { model.stop() }
        model.start()

        try await waitUntil { model.videoState.error != nil }
        let calls = await streamer.calls
        XCTAssertEqual(calls, 3, "the first attempt and two silent retries")
        XCTAssertEqual(model.videoState, .failed(.quotaOrRateLimited))
        XCTAssertEqual(model.videoState.error?.isRetryable, true)
    }

    @MainActor
    func testAFixedFailureShowsAtOnceAndOffersNoRetry() async throws {
        for failure in [Self.rangeNotSupported, Self.decryption] {
            let streamer = ScriptedStreamProvider(failures: [failure])
            let model = try makeModel(streamer: streamer, delays: nil)
            model.start()

            try await waitUntil { model.videoState.error != nil }
            let calls = await streamer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.videoState.error?.isRetryable, false)
            model.stop()
        }
    }

    // MARK: - Helpers

    private static let rateLimit = apiError(429)
    private static let rangeNotSupported = apiError(416)
    private static let decryption = NSError(
        domain: "Custom", code: 1, userInfo: [NSLocalizedDescriptionKey: "block decrypt failed"])
    private static let codec = NSError(domain: "AVFoundationErrorDomain", code: -11828)

    private static func apiError(_ status: Int) -> NSError {
        NSError(
            domain: "ProtonAuth", code: status,
            userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for /drive/x"])
    }

    /// `delays` replaces the waits of a rate limit; nil keeps the production waits.
    @MainActor
    private func makeModel(
        streamer: ScriptedStreamProvider, delays: [Duration]?, consulted: Counter = Counter()
    ) throws -> PhotoViewerModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-retry-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n"), captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "video/mp4")
        let provider = FailingPreviewProvider()
        let feed = ThumbnailFeed(
            cache: ThumbnailCache(namespace: "video-retry", rootDirectory: root), loader: provider)
        guard let delays else {
            return PhotoViewerModel(items: [item], index: 0, feed: feed, media: provider, streamer: streamer)
        }
        return PhotoViewerModel(
            items: [item], index: 0, feed: feed, media: provider, streamer: streamer,
            silentRetryDelays: { failure in
                consulted.value += 1
                return failure == .quotaOrRateLimited ? delays : []
            })
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
}

/// Counts the calls of the delay closure, which the model makes on the main actor.
private final class Counter {
    var value = 0
}

private actor ScriptedStreamProvider: VideoStreamProvider {
    private let failures: [any Error]
    private(set) var calls = 0

    init(failures: [any Error]) { self.failures = failures }

    func prefetchEncrypted(for uid: PhotoUID) async throws {}

    /// The failures in order; the last one repeats.
    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        calls += 1
        throw failures[min(calls, failures.count) - 1]
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
