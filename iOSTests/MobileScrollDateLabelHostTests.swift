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

    func testTheHostReportsItsOwnScrollsAndLayoutAsNonUserMovement() throws {
        let grid = try hostInWindow()
        XCTAssertFalse(grid.scrollDateLabelMovement.isHostDriven)
        grid.isApplyingProgrammaticScroll = true
        XCTAssertTrue(grid.scrollDateLabelMovement.isHostDriven, "a programmatic jump")
        grid.isApplyingProgrammaticScroll = false
        // The host's animated scroll (Library tab retap) is a jump while its animation runs.
        grid.scrollView.contentSize = CGSize(width: grid.bounds.width, height: grid.bounds.height * 20)
        grid.hostAnimatedScrollActive = true
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: grid.bounds.height * 5), animated: true)
        XCTAssertTrue(grid.scrollView.isScrollAnimating, "SETUP: the offset animation runs")
        XCTAssertTrue(grid.scrollDateLabelMovement.isHostDriven, "the host's animated scroll to the newest photos")
        // A touch can end the animation without the end callback and leave the flag set; once nothing animates, the
        // stale flag no longer makes movement a jump.
        grid.scrollView.setContentOffset(grid.scrollView.contentOffset, animated: false)
        grid.hostAnimatedScrollActive = true
        XCTAssertFalse(grid.scrollView.isScrollAnimating)
        XCTAssertFalse(grid.scrollDateLabelMovement.isHostDriven, "a stale flag must not swallow the next flick")
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
        let controller = grid.scrollDateLabel.controller
        controller.updateHost(
            TimelineScrollDateLabelHostState(
                hasWindow: true, isActive: true, isBackgrounded: false, isTransforming: false, hasItems: true,
                isScrollable: true))
        controller.setIndex(TimelineScrollDateIndex.build(items: photos(), revision: 1))
        controller.setAnchor(flatIndex: 0)
        // The host's real movement description, fed as a continuous movement.
        var offset = 0.0
        for _ in 0..<6 {
            offset += 400
            controller.viewportMoved(grid.scrollDateLabelMovement, offsetY: offset)
            Thread.sleep(forTimeInterval: 0.005)
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

    /// The label already fades out after its linger time; backgrounding or opening a photo must not wait for the fade.
    func testAnImmediateHideStopsARunningFadeOut() async throws {
        final class Time: @unchecked Sendable { var now: TimeInterval = 0 }
        let time = Time()
        let controller = TimelineScrollDateLabelController(
            clock: TimelineScrollDateLabelClock(
                now: { time.now }, sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }))
        let presenter = UIKitTimelineScrollDateLabelPresenter(controller: controller)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scrollView = UIScrollView(frame: host.bounds)
        scrollView.contentSize = CGSize(width: 400, height: 8_000)
        host.addSubview(scrollView)
        presenter.attach(to: host, scrollView: scrollView)
        controller.updateHost(
            TimelineScrollDateLabelHostState(
                hasWindow: true, isActive: true, isBackgrounded: false, isTransforming: false, hasItems: true,
                isScrollable: true))
        controller.setIndex(TimelineScrollDateIndex.build(items: photos(), revision: 1))
        controller.setAnchor(flatIndex: 0)
        var offset = 0.0
        for _ in 0..<12 {
            controller.userMoved(offsetY: offset)
            time.now += 1.0 / 120
            offset += 2_000.0 / 120
        }
        XCTAssertFalse(presenter.view.isHidden, "SETUP: the label shows")
        time.now += 1.5
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.presentation.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.presentation.isVisible, "SETUP: the linger hide started")
        XCTAssertFalse(presenter.view.isHidden, "SETUP: the 0.35 s fade-out still runs")
        controller.suppress()
        XCTAssertTrue(presenter.view.isHidden, "the fade-out stops at once")
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
