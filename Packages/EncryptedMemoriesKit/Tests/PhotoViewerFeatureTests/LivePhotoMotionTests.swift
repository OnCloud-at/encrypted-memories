import AVFoundation
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
    private func item(isLivePhoto: Bool, relatedVideoID: String?, looping: Bool = false) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n"),
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/heic",
            isLivePhoto: isLivePhoto,
            isLoopingLivePhoto: looping,
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

    func testLoopingPhotosPreloadWithoutAcceptingAPressOrLiveControl() {
        let loop = item(isLivePhoto: true, relatedVideoID: "motion", looping: true)
        XCTAssertTrue(LivePhotoMotionPolicy.shouldPrepare(item: loop, hasStreamer: true))
        XCTAssertFalse(LivePhotoMotionPolicy.acceptsPress(item: loop))
        XCTAssertTrue(LivePhotoMotionPolicy.acceptsPress(item: item(isLivePhoto: true, relatedVideoID: "motion")))
        XCTAssertFalse(LivePhotoMotionPolicy.acceptsPress(item: item(isLivePhoto: false, relatedVideoID: nil)))
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
    func testLoopingPreparationRequestsPlaybackAndIgnoresARelease() {
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true),
            streamer: SuspendedVideoStreamProvider()
        ) { true }
        XCTAssertEqual(controller.loadState, .loading)
        XCTAssertTrue(controller.isPlayRequested, "a looping photo starts without a press")
        controller.stop()
        XCTAssertTrue(controller.isPlayRequested, "a release must not stop an automatic loop")
        controller.teardown()
        XCTAssertFalse(controller.isPlayRequested)
        controller.play()
        XCTAssertTrue(controller.isPlayRequested, "teardown must restore the ordinary idle contract")
    }

    @MainActor
    func testChangingTheSameMotionFromLoopToOrdinaryDropsAutomaticIntent() {
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        let streamer = SuspendedVideoStreamProvider()
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true), streamer: streamer
        ) { true }
        XCTAssertTrue(controller.isPlayRequested)
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion"), streamer: streamer) { true }
        XCTAssertFalse(controller.isPlayRequested)
        XCTAssertEqual(controller.loadState, .loading)
    }

    @MainActor
    func testRealLoopAutoplaysMutedAcrossTwoBoundariesAndClosesItsQueue() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture())
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true),
            streamer: provider
        ) { true }
        try await waitUntil(timeout: .seconds(10)) { await controller.loadState == .ready }
        let player = try XCTUnwrap(controller.player as? AVQueuePlayer)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(player.isMuted)
        let repeated = expectation(description: "three passes cross two loop boundaries")
        repeated.expectedFulfillmentCount = 3
        let observer = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.7, preferredTimescale: 600))], queue: .main
        ) { repeated.fulfill() }
        defer { player.removeTimeObserver(observer) }
        await fulfillment(of: [repeated], timeout: 12)
        controller.play()
        controller.stop()
        XCTAssertTrue(controller.player === player)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(player.isMuted, "a press or release must not unmute the loop")
        controller.teardown()
        XCTAssertNil(controller.player)
        XCTAssertTrue(player.items().isEmpty)
        XCTAssertEqual(player.rate, 0)
        let closed = await provider.closeCount
        let prefetched = await provider.started
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(prefetched, 1)
    }

    @MainActor
    func testTheAppCoverPausesARealLoopAndUncoveringStartsItAgain() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture())
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true), streamer: provider
        ) { true }
        try await waitUntil(timeout: .seconds(10)) { await controller.loadState == .ready }
        let player = try XCTUnwrap(controller.player)
        try await waitForPlayback(of: player)
        controller.setCovered(true)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(player.rate, 0, "a covered loop must not keep decoding")
        controller.setCovered(false)
        XCTAssertTrue(controller.isPlaying)
        try await waitForPlayback(of: player)
    }

    @MainActor
    func testALoopThatFinishesLoadingWhileCoveredStaysPausedUntilUncovered() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture())
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.setCovered(true)
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true), streamer: provider
        ) { true }
        try await waitUntil(timeout: .seconds(10)) { await controller.loadState == .ready }
        let player = try XCTUnwrap(controller.player)
        XCTAssertFalse(controller.isPlaying, "a preload that finishes under the cover must not start")
        XCTAssertEqual(player.rate, 0)
        controller.setCovered(false)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(player.isMuted)
    }

    @MainActor
    func testAPressWhileCoveredDoesNotStartMotionAfterUncover() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture())
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        controller.prepare(for: live, streamer: provider) { true }
        try await waitUntil(timeout: .seconds(10)) { await controller.loadState == .ready }
        let player = try XCTUnwrap(controller.player)
        controller.setCovered(true)
        controller.play()
        controller.play(for: live, streamer: provider) { true }
        XCTAssertFalse(controller.isPlayRequested, "a press under the cover must not stay requested")
        controller.setCovered(false)
        XCTAssertFalse(controller.isPlaying, "uncovering must not start motion without a new press")
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    func testRealOrdinaryMotionWaitsForAPressAndStopsAfterOnePass() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture())
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion"), streamer: provider) { true }
        try await waitUntil(timeout: .seconds(10)) { await controller.loadState == .ready }
        let player = try XCTUnwrap(controller.player)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(player is AVQueuePlayer)
        controller.play()
        XCTAssertFalse(player.isMuted)
        try await waitUntil { await !controller.isPlaying }
        XCTAssertFalse(controller.isPlayRequested)
        controller.teardown()
        let closed = await provider.closeCount
        XCTAssertEqual(closed, 1)
    }

    @MainActor
    func testLateAssetAfterTeardownClosesWithoutChangingIdleState() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture(), waitsForAsset: true)
        let controller = LivePhotoMotionController()
        defer { controller.teardown() }
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion"), streamer: provider) { true }
        do { try await waitUntil { await provider.assetStarted } } catch {
            await provider.releaseAsset()
            throw error
        }
        controller.teardown()
        await provider.releaseAsset()
        try await waitUntil { await provider.closeCount == 1 }
        XCTAssertNil(controller.player)
        XCTAssertEqual(controller.loadState, .idle)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testAssetForAPageThatLeftClosesBeforeAdoption() async throws {
        let provider = MotionPrefetchProbe(url: try motionFixture(), waitsForAsset: true)
        let controller = LivePhotoMotionController()
        var current = true
        defer { controller.teardown() }
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion"), streamer: provider) { current }
        do { try await waitUntil { await provider.assetStarted } } catch {
            await provider.releaseAsset()
            throw error
        }
        current = false
        await provider.releaseAsset()
        try await waitUntil { await provider.closeCount == 1 }
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
    }

    /// Generated 32x32 green/red frames, one second long. No Photos library or network access.
    private func motionFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-clip-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let encoded = """
            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
            """
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let url = root.appendingPathComponent("motion.mov")
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private func waitForPlayback(of player: AVPlayer) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while player.rate == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(player.rate, 0, "the loop must play")
    }

    @MainActor
    private func waitForLoadState(
        _ controller: LivePhotoMotionController, _ state: LivePhotoMotionLoadState
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.loadState != state, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.loadState, state)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
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

    // MARK: - One silent repeat of a failed preparation

    private func liveItem() -> PhotoItem { item(isLivePhoto: true, relatedVideoID: "motion") }

    /// A failure that goes away by itself repeats once behind the loading state. The still stays, the press that
    /// waits for the motion stays, and the viewer shows no failure symbol in between.
    @MainActor
    func testATransientFailureIsRepeatedOnceBehindTheLoadingStateAndThenTheMotionIsReady() async throws {
        let provider = ScriptedMotionProvider(failures: [URLError(.timedOut)], url: try motionFixture())
        let pause = MotionPause(holds: true)
        let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
        defer {
            controller.teardown()
            Task { await pause.release() }
        }
        controller.play(for: liveItem(), streamer: provider) { true }

        try await waitUntil { await pause.requested.count == 1 }
        XCTAssertEqual(controller.loadState, .loading, "the wait shows no failure")
        XCTAssertTrue(controller.isPlayRequested, "the press that waits for the motion stays")
        let callsWhileWaiting = await provider.prefetchCalls
        XCTAssertEqual(callsWhileWaiting, 1)

        await pause.release()
        try await waitForLoadState(controller, .ready)
        let calls = await provider.prefetchCalls
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(controller.player)
        let waits = await pause.requested
        XCTAssertEqual(waits, [.seconds(3)], "one repeat after the first wait of the schedule")
    }

    /// The repeat is one repeat: when it fails too, the symbol stays.
    @MainActor
    func testAFailureThatRepeatsShowsTheSymbolAfterTheRepeat() async throws {
        let provider = ScriptedMotionProvider(
            failures: [URLError(.timedOut), URLError(.timedOut), URLError(.timedOut)], url: try motionFixture())
        let pause = MotionPause(holds: false)
        let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
        defer { controller.teardown() }
        controller.prepare(for: liveItem(), streamer: provider) { true }

        try await waitForLoadState(controller, .failed)
        let calls = await provider.prefetchCalls
        let waits = await pause.requested
        XCTAssertEqual(calls, 2, "the first attempt and one repeat")
        XCTAssertEqual(waits, [.seconds(3)])
    }

    /// A failure that no new attempt changes, or that the failure policy does not repeat by itself, shows the symbol at
    /// once.
    @MainActor
    func testAFailureThatANewAttemptCannotChangeShowsTheSymbolAtOnce() async throws {
        let failures: [any Error] = [
            MotionTypedFailure(video: .decryptionFailed), MotionTypedFailure(video: .malformedContent),
            VideoStreamError.notAVideo, URLError(.notConnectedToInternet), URLError(.dataNotAllowed),
            URLError(.internationalRoamingOff), URLError(.callIsActive), URLError(.serverCertificateUntrusted),
            URLError(.appTransportSecurityRequiresSecureConnection), URLError(.badURL), URLError(.unsupportedURL),
            URLError(.userAuthenticationRequired), URLError(.secureConnectionFailed),
            URLError(.clientCertificateRequired), URLError(.httpTooManyRedirects),
            URLError(.cannotDecodeContentData), URLError(.cancelled),
            MotionCausedFailure(failureCause: .permanent), MotionCausedFailure(failureCause: .authentication),
            MotionCausedFailure(failureCause: .unsupported),
        ]
        for failure in failures {
            let provider = ScriptedMotionProvider(failures: [failure, failure], url: try motionFixture())
            let pause = MotionPause(holds: false)
            let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
            controller.prepare(for: liveItem(), streamer: provider) { true }

            try await waitForLoadState(controller, .failed)
            let calls = await provider.prefetchCalls
            let waits = await pause.requested
            XCTAssertEqual(calls, 1, "\(failure)")
            XCTAssertTrue(waits.isEmpty, "\(failure)")
            controller.teardown()
        }
    }

    /// The failure policy repeats a read that failed for a temporary cause. A failure without a cause repeats once too:
    /// the read changes nothing.
    @MainActor
    func testAFailureThatTheFailurePolicyRepeatsAndAnUnclassifiedFailureRepeatOnce() async throws {
        let failures: [any Error] = [
            MotionCausedFailure(failureCause: .serviceTemporary), MotionCausedFailure(failureCause: .network),
            MotionCausedFailure(failureCause: .rateLimited), MotionCausedFailure(failureCause: .localTransient),
            NSError(domain: "Custom", code: 1), URLError(.networkConnectionLost), URLError(.dnsLookupFailed),
            URLError(.cannotFindHost),
        ]
        for failure in failures {
            let provider = ScriptedMotionProvider(failures: [failure], url: try motionFixture())
            let pause = MotionPause(holds: false)
            let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
            controller.prepare(for: liveItem(), streamer: provider) { true }

            try await waitForLoadState(controller, .ready)
            let calls = await provider.prefetchCalls
            XCTAssertEqual(calls, 2, "\(failure)")
            controller.teardown()
        }
    }

    /// The app lock covers the viewer while the repeat waits. The repeat ends with a ready clip, and no motion starts
    /// until the cover goes away.
    @MainActor
    func testARepeatThatEndsWhileTheAppIsCoveredStartsNoMotion() async throws {
        let provider = ScriptedMotionProvider(failures: [URLError(.timedOut)], url: try motionFixture())
        let pause = MotionPause(holds: true)
        let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
        defer {
            controller.teardown()
            Task { await pause.release() }
        }
        controller.prepare(for: item(isLivePhoto: true, relatedVideoID: "motion", looping: true), streamer: provider) {
            true
        }
        try await waitUntil { await pause.requested.count == 1 }

        controller.setCovered(true)
        await pause.release()
        try await waitForLoadState(controller, .ready)

        XCTAssertNotNil(controller.player)
        XCTAssertFalse(controller.isPlaying, "a covered viewer shows no motion")
        controller.setCovered(false)
        XCTAssertTrue(controller.isPlaying, "the loop starts when the cover goes away")
    }

    /// A page that the person left, or a closed viewer, ends the wait without another attempt.
    @MainActor
    func testTheRepeatEndsWithThePageOrTheViewer() async throws {
        for ending in ["teardown", "pageLeft"] {
            let provider = ScriptedMotionProvider(failures: [URLError(.timedOut)], url: try motionFixture())
            let pause = MotionPause(holds: true)
            let controller = LivePhotoMotionController(repeatPause: { await pause.wait($0) })
            let current = MotionCurrentPage()
            controller.prepare(for: liveItem(), streamer: provider) { current.value }
            try await waitUntil { await pause.requested.count == 1 }

            if ending == "teardown" { controller.teardown() } else { current.value = false }
            await pause.release()
            try await Task.sleep(for: .milliseconds(100))

            let calls = await provider.prefetchCalls
            XCTAssertEqual(calls, 1, ending)
            XCTAssertNotEqual(controller.loadState, .ready, ending)
            controller.teardown()
        }
    }

    @MainActor
    func testMotionPrefetchFailurePublishesTerminalFailure() async {
        let controller = LivePhotoMotionController()
        controller.prepare(
            for: item(isLivePhoto: true, relatedVideoID: "motion"),
            streamer: FailingVideoStreamProvider()
        ) { true }

        // The preparation leaves the main actor for the stream provider. A yield count can run out on a busy
        // machine before it returns, so wait for the state with a deadline.
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.loadState != .failed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(controller.loadState, .failed)
    }
}

private actor MotionPrefetchProbe: VideoStreamProvider {
    private(set) var started = 0
    private(set) var cancelled = 0
    private let url: URL?
    private let lifetime = MotionLifetimeProbe()
    private let waitsForAsset: Bool
    private var assetReleased = false
    private var assetContinuation: CheckedContinuation<Void, Never>?
    private(set) var assetStarted = false
    var closeCount: Int { lifetime.closeCount }

    init(url: URL? = nil, waitsForAsset: Bool = false) {
        self.url = url
        self.waitsForAsset = waitsForAsset
    }

    func releaseAsset() {
        assetReleased = true
        assetContinuation?.resume()
        assetContinuation = nil
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        started += 1
        if url != nil { return }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            if Task.isCancelled { cancelled += 1 }
            throw error
        }
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        guard let url else { throw VideoStreamError.notAVideo }
        if waitsForAsset, !assetReleased {
            assetStarted = true
            // Deliberately ignores task cancellation to challenge the controller's adoption fence.
            await withCheckedContinuation { assetContinuation = $0 }
        }
        return StreamingVideoAsset(asset: AVURLAsset(url: url), retaining: lifetime)
    }
}

private final class MotionLifetimeProbe: VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = 0
    var closeCount: Int { lock.withLock { closed } }
    func close() { lock.withLock { closed += 1 } }
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

private struct MotionTypedFailure: VideoPlaybackClassifiable {
    let video: VideoPlaybackError
    var videoPlaybackError: VideoPlaybackError? { video }
}

private struct MotionCausedFailure: Error, FailureClassifiable {
    let failureCause: FailureCause
}

private final class MotionCurrentPage: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Records the pause before a repeat. A pause that holds ends when the test releases it or the task is cancelled.
private actor MotionPause {
    private(set) var requested: [Duration] = []
    private let holds: Bool
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(holds: Bool) { self.holds = holds }

    func wait(_ duration: Duration) async {
        requested.append(duration)
        guard holds, !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Fails the first prefetches with the given errors, then delivers the motion clip.
private actor ScriptedMotionProvider: VideoStreamProvider {
    private var failures: [any Error]
    private let url: URL
    private let lifetime = MotionClipLifetime()
    private(set) var prefetchCalls = 0

    init(failures: [any Error], url: URL) {
        self.failures = failures
        self.url = url
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        prefetchCalls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
    }

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        StreamingVideoAsset(asset: AVURLAsset(url: url), retaining: lifetime)
    }
}

private final class MotionClipLifetime: VideoStreamLifetime, @unchecked Sendable {
    func close() {}
}
