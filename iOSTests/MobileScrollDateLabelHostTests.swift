import PhotosCore
import TimelineCore
import UIKit
import XCTest

@testable import TimelineUIKitFeature

/// The iOS grid host's part of the scroll date label (#777): what it reports as user scrolling, when it hides the label,
/// and that the label ends with the host.
@MainActor
final class MobileScrollDateLabelHostTests: XCTestCase {
    private var window: UIWindow?
    private var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        previousKeyWindow?.makeKey()
        window = nil
    }

    private func hostInWindow() throws -> UIKitTimelineGridHostView {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        self.window = window
        let grid = UIKitTimelineGridHostView(frame: controller.view.bounds)
        controller.view.addSubview(grid)
        window.layoutIfNeeded()
        return grid
    }

    private func photos() -> [PhotoItem] {
        let calendar = Calendar(identifier: .gregorian)
        return (0..<30).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"),
                captureTime: calendar.date(from: DateComponents(year: 2026, month: 1 + $0 / 10, day: 3))!,
                mediaType: "image/jpeg")
        }
    }

    /// Makes the label visible through the shared controller, as a brisk scroll on a scrollable library would.
    private func showLabel(on grid: UIKitTimelineGridHostView) throws {
        if grid.scrollView.contentSize.height <= grid.bounds.height {
            grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: grid.bounds.height * 20)
            grid.scrollView.flashScrollIndicators()
            grid.scrollView.layoutIfNeeded()
        }
        let controller = grid.scrollDateLabel.controller
        controller.updateHost(
            TimelineScrollDateLabelHostState(
                hasWindow: true, isActive: true, isBackgrounded: false, isTransforming: false, hasItems: true,
                isScrollable: true))
        controller.setIndex(TimelineScrollDateIndex.build(items: photos(), revision: 1))
        controller.setAnchor(flatIndex: 0)
        var offset = 0.0
        for _ in 0..<6 {
            offset += 400  // At least 1/240 s apart: far above the show speed.
            controller.userMoved(offsetY: offset)
        }
        XCTAssertTrue(controller.presentation.isVisible, "SETUP: the label must be visible")
    }

    private func nativeThumb(on grid: UIKitTimelineGridHostView) throws -> CGRect {
        let rect = try XCTUnwrap(grid.scrollView.verticalIndicatorRect)
        return grid.convert(rect, from: grid.scrollView)
    }

    func testNativeThumbGeometryCentersTheLabelAtFiveFractions() throws {
        let grid = try hostInWindow()
        try showLabel(on: grid)
        grid.window?.layoutIfNeeded()
        for fraction in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: 10_000)
            let low = -grid.scrollView.contentInset.top
            let high = 10_000 + grid.scrollView.contentInset.bottom - grid.bounds.height
            grid.scrollView.setContentOffset(CGPoint(x: 0, y: low + fraction * (high - low)), animated: false)
            grid.scrollView.flashScrollIndicators()
            grid.scrollView.layoutIfNeeded()
            try showLabel(on: grid)
            grid.scrollDateLabel.layout()
            let thumb = try nativeThumb(on: grid)
            XCTAssertEqual(grid.scrollDateLabel.view.frame.midY, thumb.midY, accuracy: 0.01)
        }
    }

    func testTheHostReportsItsOwnScrollsAndLayoutAsNonUserMovement() throws {
        let grid = try hostInWindow()
        XCTAssertFalse(grid.scrollDateLabelMovement.isHostDriven)
        grid.isApplyingProgrammaticScroll = true
        XCTAssertTrue(grid.scrollDateLabelMovement.isHostDriven, "a programmatic adjustment")
        XCTAssertFalse(grid.scrollDateLabelMovement.isJump, "a generic host adjustment only resets speed")
        grid.isApplyingScrollJump = true
        XCTAssertTrue(grid.scrollDateLabelMovement.isJump, "an explicit navigation command marks a jump")
        grid.scrollDateLabelLayoutDepth = 1
        XCTAssertFalse(grid.scrollDateLabelMovement.isJump, "layout is not navigation")
        grid.scrollDateLabelLayoutDepth = 0
        grid.isApplyingScrollJump = false
        grid.isApplyingProgrammaticScroll = false
        // The host's animated scroll (Library tab retap) is a jump while its animation runs.
        grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: grid.bounds.height * 20)
        grid.hostAnimatedScrollActive = true
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: grid.bounds.height * 5), animated: true)
        XCTAssertTrue(grid.scrollView.isScrollAnimating, "SETUP: the offset animation runs")
        XCTAssertTrue(grid.scrollDateLabelMovement.isHostDriven, "the host's animated scroll to the newest photos")
        XCTAssertTrue(grid.scrollDateLabelMovement.isJump)
        // A touch can end the animation without the end callback and leave the flag set; once nothing animates, the
        // stale flag no longer makes movement a jump.
        grid.scrollView.setContentOffset(grid.scrollView.contentOffset, animated: false)
        grid.hostAnimatedScrollActive = true
        XCTAssertFalse(grid.scrollView.isScrollAnimating)
        XCTAssertFalse(grid.scrollDateLabelMovement.isHostDriven, "a stale flag must not swallow the next flick")
        XCTAssertFalse(grid.scrollDateLabelMovement.isJump)
        grid.hostAnimatedScrollActive = false
        grid.scrollDateLabelLayoutDepth = 1
        XCTAssertTrue(grid.scrollDateLabelMovement.isLayout, "a layout pass")
        grid.scrollDateLabelLayoutDepth = 0
        let idle = grid.scrollDateLabelMovement
        XCTAssertFalse(idle.isHostDriven || idle.isLayout || idle.isTracking || idle.isDragging || idle.isDecelerating)
    }

    func testBackgroundInactiveTabAndWindowRemovalHideTheLabelAtOnce() throws {
        let grid = try hostInWindow()
        XCTAssertTrue(grid.scrollDateLabelHostState.hasWindow)
        XCTAssertTrue(grid.scrollDateLabelHostState.isActive)

        try showLabel(on: grid)
        grid.hostSceneDidEnterBackground()
        XCTAssertTrue(grid.scrollDateLabelHostState.isBackgrounded)
        XCTAssertFalse(
            grid.scrollDateLabel.controller.presentation.isVisible, "hidden before the app-switcher snapshot")
        grid.hostSceneWillEnterForeground()
        XCTAssertFalse(grid.scrollDateLabelHostState.isBackgrounded)

        try showLabel(on: grid)
        grid.setActive(false)
        XCTAssertFalse(grid.scrollDateLabelHostState.isActive)
        XCTAssertFalse(grid.scrollDateLabel.controller.presentation.isVisible, "an inactive tab shows no label")
        grid.setActive(true)

        try showLabel(on: grid)
        grid.removeFromSuperview()
        XCTAssertFalse(grid.scrollDateLabelHostState.hasWindow)
        XCTAssertFalse(grid.scrollDateLabel.controller.presentation.isVisible, "a host without a window shows no label")
    }

    /// A flick that interrupts the host's own animated scroll (Library tab retap) gets no end-animation callback.
    func testAFlickThatInterruptsAHostAnimationStillShowsTheLabel() throws {
        let grid = try hostInWindow()
        grid.hostAnimatedScrollActive = true  // As after scrollToLatest(animated: true).
        grid.systemScrollToTopActive = true  // As after a status-bar tap.
        grid.scrollViewWillBeginDragging(grid.scrollView)
        XCTAssertFalse(grid.hostAnimatedScrollActive)
        XCTAssertFalse(grid.systemScrollToTopActive)
        final class Time: @unchecked Sendable { var now: TimeInterval = 0 }
        let time = Time()
        let controller = TimelineScrollDateLabelController(
            clock: .init(now: { time.now }, sleep: { _ in throw CancellationError() }))
        defer { controller.retire() }
        controller.updateHost(
            TimelineScrollDateLabelHostState(
                hasWindow: true, isActive: true, isBackgrounded: false, isTransforming: false, hasItems: true,
                isScrollable: true))
        controller.setIndex(TimelineScrollDateIndex.build(items: photos(), revision: 1))
        controller.setAnchor(flatIndex: 0)
        // Feed the host's observed movement through the shared controller at exact clock intervals.
        var offset = 0.0
        for _ in 0..<6 {
            offset += 400
            controller.viewportMoved(grid.scrollDateLabelMovement, offsetY: offset)
            time.now += 1.0 / 120
        }
        XCTAssertTrue(controller.presentation.isVisible, "the person's flick after the interruption shows the label")
    }

    /// A double tap on the Library tab: the second animated jump replaces the first, and UIKit ends the first inside
    /// the call. The second jump must still count as the host's own movement.
    func testASecondHostJumpThatReplacesTheFirstStaysAJump() throws {
        let grid = try hostInWindow()
        grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: grid.bounds.height * 20)
        grid.setHostContentOffsetY(grid.bounds.height * 5, animated: true)
        XCTAssertTrue(grid.scrollView.isScrollAnimating, "SETUP: the first jump animates")
        grid.setHostContentOffsetY(grid.bounds.height * 10, animated: true)
        XCTAssertTrue(grid.scrollView.isScrollAnimating, "SETUP: the second jump animates")
        XCTAssertTrue(grid.hostAnimatedScrollActive)
        XCTAssertTrue(grid.scrollDateLabelMovement.isHostDriven, "the label stays hidden during the second jump")
        XCTAssertTrue(grid.scrollDateLabelMovement.isJump)
    }

    func testASynchronousNavigationOffsetIsMarkedOnlyDuringTheSet() throws {
        let grid = try hostInWindow()
        grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: grid.bounds.height * 20)
        var movements: [TimelineScrollDateLabelMovement] = []
        let observation = grid.scrollView.observe(\.contentOffset, options: [.new]) { [weak grid] _, _ in
            MainActor.assumeIsolated {
                if let grid { movements.append(grid.scrollDateLabelMovement) }
            }
        }
        defer { observation.invalidate() }
        grid.setHostContentOffsetY(grid.bounds.height * 5, animated: false)
        XCTAssertFalse(movements.isEmpty, "SETUP: the native offset setter reports a movement")
        XCTAssertTrue(movements.allSatisfy { $0.isHostDriven && $0.isJump })
        XCTAssertFalse(grid.isApplyingScrollJump)
        XCTAssertFalse(grid.scrollDateLabelMovement.isJump, "the transient marker ends with the setter")
    }

    func testAMarkedJumpUsesTheFastFadeAndReduceMotionHidesAtOnce() throws {
        let grid = try hostInWindow()
        grid.scrollDateLabel.setReduceMotion(false)
        try showLabel(on: grid)
        let controller = grid.scrollDateLabel.controller
        controller.viewportMoved(.init(isHostDriven: true, isJump: true), offsetY: 50_000)
        XCTAssertFalse(controller.presentation.isVisible, "the linger ends in the same pass")
        XCTAssertEqual(
            controller.presentation.fadeDuration, TimelineScrollDateLabelMotion.fadeOut.fast,
            "a marked jump uses the fast fade")
        XCTAssertFalse(grid.scrollDateLabel.view.isHidden, "the view remains while the fast fade starts")

        grid.scrollDateLabel.setReduceMotion(true)
        try showLabel(on: grid)
        controller.viewportMoved(.init(isHostDriven: true, isJump: true), offsetY: 50_000)
        XCTAssertFalse(controller.presentation.isVisible)
        XCTAssertTrue(grid.scrollDateLabel.view.isHidden, "Reduce Motion applies the hide without a fade")
    }

    /// A tap that stops a jump, or a status-bar tap at the top, ends without a callback; the next offset change
    /// without an animation clears the flags, so a later keyboard page key is the person's input again.
    func testStaleJumpFlagsClearOnTheNextMovementWithoutAnAnimation() throws {
        let grid = try hostInWindow()
        grid.hostAnimatedScrollActive = true
        grid.systemScrollToTopActive = true
        XCTAssertFalse(grid.scrollView.isScrollAnimating)
        grid.scrollViewDidScroll(grid.scrollView)
        XCTAssertFalse(grid.hostAnimatedScrollActive)
        XCTAssertFalse(grid.systemScrollToTopActive)
    }

    /// Suppression stops an already-started fade in the same actor turn, with no animation-deadline race.
    func testAnImmediateHideStopsAnAlreadyStartedFadeOut() throws {
        let grid = try hostInWindow()
        grid.scrollDateLabel.setReduceMotion(false)
        try showLabel(on: grid)
        let controller = grid.scrollDateLabel.controller
        controller.nonUserMoved(isJump: true)
        XCTAssertFalse(controller.presentation.isVisible, "SETUP: the fast jump fade has started")
        XCTAssertFalse(grid.scrollDateLabel.view.isHidden, "the same actor turn precedes animation completion")
        controller.suppress()
        XCTAssertTrue(grid.scrollDateLabel.view.isHidden, "suppression stops the already-running fade at once")
    }

    func testAStatusBarTapIsAJumpUntilItEnds() throws {
        let grid = try hostInWindow()
        XCTAssertTrue(grid.scrollViewShouldScrollToTop(grid.scrollView))
        XCTAssertTrue(grid.systemScrollToTopActive)
        grid.scrollViewDidScrollToTop(grid.scrollView)
        XCTAssertFalse(grid.systemScrollToTopActive)
    }

    func testSuppressionAndRouteHideRemoveTheLabelWithoutAFade() throws {
        let grid = try hostInWindow()
        try showLabel(on: grid)
        XCTAssertFalse(grid.scrollDateLabel.view.isHidden, "SETUP: the label view shows")
        grid.setActive(false)
        XCTAssertTrue(grid.scrollDateLabel.view.isHidden, "an inactive tab removes the label in the same pass")
        grid.setActive(true)
        try showLabel(on: grid)
        XCTAssertFalse(grid.scrollDateLabel.view.isHidden)
        grid.openPhoto(photos()[0])
        XCTAssertTrue(grid.scrollDateLabel.view.isHidden, "opening a photo removes the label in the same pass")
    }

    func testOpeningAPhotoHidesTheLabelBeforeTheViewerOpens() throws {
        let grid = try hostInWindow()
        try showLabel(on: grid)
        var visibleWhenOpened: Bool?
        grid.onOpenPhoto = { _ in visibleWhenOpened = grid.scrollDateLabel.controller.presentation.isVisible }
        grid.openPhoto(photos()[0])
        XCTAssertEqual(visibleWhenOpened, false)
    }

    func testTheLabelEndsWithItsHost() async throws {
        var controller: TimelineScrollDateLabelController?
        weak var released: UIKitTimelineGridHostView?
        autoreleasepool {
            let host = UIKitTimelineGridHostView()
            controller = host.scrollDateLabel.controller
            released = host
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while controller?.isRetired == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(released)
        XCTAssertEqual(controller?.isRetired, true, "deinit retires the label, so no build or fade outlives the host")
    }
}
