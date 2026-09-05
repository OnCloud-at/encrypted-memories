import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerFeature
import PhotosCore
import XCTest

@testable import PhotoViewerCore

/// Locks the shared Live Photo motion policy + controller both platforms drive, so the "when do we prepare a
/// motion clip" rule and the safe idle behavior can never drift between macOS and iOS.
final class LivePhotoMotionTests: XCTestCase {
    private func item(isLivePhoto: Bool, relatedVideoID: String?) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n"),
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/heic",
            isLivePhoto: isLivePhoto,
            relatedVideoID: relatedVideoID
        )
    }

    func testShouldPrepareOnlyForLivePhotoWithPairedVideoAndStreamer() {
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        XCTAssertTrue(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: true))
    }

    func testShouldNotPrepareWithoutStreamer() {
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: false))
    }

    func testShouldNotPrepareForNonLiveItem() {
        let still = item(isLivePhoto: false, relatedVideoID: "motion")
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: still, hasStreamer: true))
    }

    func testShouldNotPrepareWhenNoPairedVideo() {
        // A Live Photo whose backend path has not enriched the paired video id yet cannot be prepared.
        let live = item(isLivePhoto: true, relatedVideoID: nil)
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: true))
    }

    func testCompositeReadinessWaitsForFullResolutionStillAndMotion() {
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: false,
                motionState: .ready
            ),
            .loading
        )
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: true,
                motionState: .loading
            ),
            .loading,
            "a sharp still must not hide loading while the paired motion clip is unavailable"
        )
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: true,
                motionState: .ready
            ),
            .ready
        )
    }

    func testCompositeReadinessDoesNotSpinForeverAfterMotionFailure() {
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: false,
                didFullResolutionStillFail: true,
                motionState: .loading
            ),
            .failed
        )
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: true,
                motionState: .failed
            ),
            .failed
        )
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: false,
                isFullResolutionStillReady: false,
                motionState: .idle
            ),
            .notApplicable
        )
    }

    func testCompositeReadinessIsIdleUntilMotionIsRequested() {
        for state in [LivePhotoMotionLoadState.idle, .loading, .ready, .failed] {
            XCTAssertEqual(
                LivePhotoCompositeReadiness.resolve(
                    requiresMotion: true,
                    isFullResolutionStillReady: true,
                    motionState: state,
                    isMotionRequested: false
                ),
                .notApplicable,
                "silent preloading must not cover the still image with a motion spinner"
            )
        }
    }

    @MainActor
    func testRepeatedPreparationAndPressReuseTheCurrentPreload() async throws {
        let controller = LivePhotoMotionController()
        let streamer = MotionPrefetchProbe()
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        defer { controller.teardown() }

        controller.prepare(for: live, streamer: streamer) { true }
        try await waitUntil { await streamer.started == 1 }
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isPlayRequested)

        controller.play(for: live, streamer: streamer) { true }
        controller.prepare(for: live, streamer: streamer) { true }
        XCTAssertTrue(controller.isPlayRequested, "appearance updates must preserve a press during preload")
        let started = await streamer.started
        XCTAssertEqual(started, 1)
        controller.stop()
        XCTAssertEqual(controller.loadState, .loading, "releasing a press must keep the current page preloading")
        controller.teardown()
        try await waitUntil { await streamer.cancelled == 1 }
        XCTAssertEqual(controller.loadState, .idle)
    }

    @MainActor
    func testNonCurrentItemDoesNotStartPreloading() async {
        let controller = LivePhotoMotionController()
        let streamer = MotionPrefetchProbe()
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion"), streamer: streamer) { false }
        XCTAssertEqual(controller.loadState, .idle)
        let started = await streamer.started
        XCTAssertEqual(started, 0)
    }

    @MainActor
    func testMacViewerOpeningPreloadsWithoutAPlaybackRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-preload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let streamer = MotionPrefetchProbe()
        let model = PhotoViewerModel(
            items: [item(isLivePhoto: true, relatedVideoID: "motion")], index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "motion-preload", rootDirectory: root),
                loader: MotionPreviewProvider()
            ),
            media: MotionPreviewProvider(), streamer: streamer
        )
        defer { model.stop() }
        model.start()
        try await waitUntil { await streamer.started == 1 }
        XCTAssertEqual(model.motion.loadState, .loading)
        XCTAssertFalse(model.motion.isPlayRequested)
        XCTAssertEqual(model.livePhotoReadiness, .notApplicable)
        model.stop()
        try await waitUntil { await streamer.cancelled == 1 }
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("motion provider did not reach its expected lifecycle boundary")
        throw CancellationError()
    }

    @MainActor
    func testControllerIdleOperationsAreSafeNoOps() {
        // With no prepared player, play retains intent; stop/teardown must clear it and leave the state clean.
        let controller = LivePhotoMotionController()
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
        controller.play()
        XCTAssertTrue(controller.isPlayRequested, "a press that begins during preload must remain pending")
        XCTAssertFalse(controller.isPlaying, "play() with no player must stay stopped")
        controller.stop()
        XCTAssertFalse(controller.isPlayRequested)
        controller.teardown()
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testPrepareForNonLiveItemLeavesNoPlayer() {
        // No streamer + non-Live item to shouldPrepare is false, so the controller stays idle.
        let controller = LivePhotoMotionController()
        controller.prepare(for: item(isLivePhoto: false, relatedVideoID: nil), streamer: nil) { true }
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlayRequested)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testPreparingMotionPublishesLoadingUntilTeardown() {
        let controller = LivePhotoMotionController()
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion"),
            streamer: SuspendedVideoStreamProvider()
        ) { true }

        XCTAssertEqual(controller.loadState, .loading)

        controller.teardown()
        XCTAssertEqual(controller.loadState, .idle)
    }

    @MainActor
    func testPlayRequestStartsPreparationForAnEligibleLivePhoto() {
        let controller = LivePhotoMotionController()
        let live = item(isLivePhoto: true, relatedVideoID: "motion")

        XCTAssertEqual(controller.loadState, .idle)
        controller.play(for: live, streamer: SuspendedVideoStreamProvider()) { true }

        XCTAssertEqual(controller.loadState, .loading)
        XCTAssertTrue(controller.isPlayRequested)
    }

    @MainActor
    func testMotionPrefetchFailurePublishesTerminalFailure() async {
        let controller = LivePhotoMotionController()
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion"),
            streamer: FailingVideoStreamProvider()
        ) { true }

        for _ in 0..<100 where controller.loadState != .failed {
            await Task.yield()
        }

        XCTAssertEqual(controller.loadState, .failed)
    }
}

private actor MotionPrefetchProbe: VideoStreamProvider {
    private(set) var started = 0
    private(set) var cancelled = 0

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        started += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            if Task.isCancelled { cancelled += 1 }
            throw error
        }
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        throw VideoStreamError.notAVideo
    }
}

private struct MotionPreviewProvider: FullMediaProvider, ThumbnailBatchLoader {
    func preview(for uid: PhotoUID) async throws -> Data { throw VideoStreamError.notAVideo }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw VideoStreamError.notAVideo
    }
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private struct SuspendedVideoStreamProvider: VideoStreamProvider {
    func prefetchEncrypted(for uid: PhotoUID) async throws {
        try await Task.sleep(for: .seconds(60))
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        throw VideoStreamError.notAVideo
    }
}

private struct FailingVideoStreamProvider: VideoStreamProvider {
    func prefetchEncrypted(for uid: PhotoUID) async throws {
        throw VideoStreamError.notAVideo
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        throw VideoStreamError.notAVideo
    }
}
