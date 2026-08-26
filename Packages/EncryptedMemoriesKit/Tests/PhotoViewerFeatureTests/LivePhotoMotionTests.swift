import Foundation
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
        XCTAssertEqual(
            LivePhotoCompositeReadiness.resolve(
                requiresMotion: true,
                isFullResolutionStillReady: true,
                motionState: .idle,
                isMotionRequested: false
            ),
            .notApplicable
        )
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
