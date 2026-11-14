import PhotosCore
import TimelineAppleAdapter
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
        let indicator = try nativeIndicator(on: grid)
        indicator.layer.removeAllAnimations()
        indicator.alpha = 1
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

    private func normalLabelRight(on grid: UIKitTimelineGridHostView) -> CGFloat {
        grid.bounds.maxX - grid.safeAreaInsets.right - TimelineScrollDateLabelMotion.indicatorGap
    }

    private func nativeThumb(on grid: UIKitTimelineGridHostView) throws -> CGRect {
        let rect = try XCTUnwrap(grid.scrollView.verticalIndicatorRect)
        return grid.convert(rect, from: grid.scrollView)
    }

    private func nativeIndicator(on grid: UIKitTimelineGridHostView) throws -> UIView {
        let rect = try XCTUnwrap(grid.scrollView.verticalIndicatorRect)
        return try XCTUnwrap(
            grid.scrollView.subviews.first {
                $0.convert($0.bounds, to: grid.scrollView) == rect
            })
    }

    func testATapOnTheRightPhotoAtRestDoesNotShowOrSlideTheLabel() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let indicator = try nativeIndicator(on: grid)
        indicator.layer.removeAllAnimations()
        indicator.alpha = 0
        indicator.isHidden = false
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertFalse(presenter.controller.presentation.isVisible, "a retained invisible thumb frame is not a contact")
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertEqual(presenter.view.transform.tx, 0)
        XCTAssertFalse(presenter.indicatorDragObserver.cancelsTouchesInView)
    }

    func testIndicatorContactUsesEffectiveAlphaAtTouchDownOnly() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let indicator = try nativeIndicator(on: grid)
        indicator.layer.removeAllAnimations()
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        for (alpha, expected) in [(CGFloat(0), false), (CGFloat(Float(0.01)), false), (0.011, true), (1, true)] {
            presenter.controller.hide()
            indicator.alpha = alpha
            presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
            XCTAssertEqual(presenter.controller.policy.isIndicatorDragging, expected, "effective alpha \(alpha)")
            if expected {
                indicator.alpha = 0
                presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 5_000)
                XCTAssertTrue(
                    presenter.controller.policy.isIndicatorDragging, "a held contact survives indicator fading")
            }
            presenter.indicatorDragObserver.finishContact()
        }
        indicator.alpha = 1
        presenter.controller.hide()
        indicator.isHidden = true
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        indicator.isHidden = false
        indicator.alpha = 0.05
        grid.alpha = 0.1
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging, "ancestor alpha multiplies the thumb alpha")
        indicator.alpha = 1
        for hidden in [true, false] {
            presenter.controller.hide()
            grid.isHidden = hidden
            grid.alpha = hidden ? 1 : 0.005
            presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
            XCTAssertFalse(
                presenter.controller.policy.isIndicatorDragging, "hidden or transparent ancestor excludes contact")
            presenter.indicatorDragObserver.finishContact()
        }
        grid.isHidden = false
        grid.alpha = 1
    }

    func testIndicatorContactUsesPresentedOpacityDuringAFlashAndAFade() async throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let indicator = try nativeIndicator(on: grid)
        for (modelAlpha, presentedAlpha, expected) in [(Float(0), Float(0.5), true), (1, 0, false)] {
            presenter.controller.hide()
            indicator.layer.removeAllAnimations()
            indicator.alpha = CGFloat(modelAlpha)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = presentedAlpha
            animation.toValue = presentedAlpha
            animation.duration = 100
            animation.isRemovedOnCompletion = false
            indicator.layer.add(animation, forKey: "opacity")
            CATransaction.flush()
            // Wait only for the render transaction, not for a time-sensitive animation phase.
            for _ in 0..<100 where indicator.layer.presentation()?.opacity != presentedAlpha {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try XCTUnwrap(indicator.layer.presentation()).opacity, presentedAlpha)
            XCTAssertEqual(indicator.layer.opacity, modelAlpha)
            var accepted = false
            presenter.indicatorDragObserver.onContact = { _, _, _ in
                accepted = true
                return true
            }
            let thumb = try nativeThumb(on: grid)
            presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
            XCTAssertEqual(accepted, expected)
            presenter.indicatorDragObserver.finishContact()
        }
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

    func testIndicatorContactAndNativeMovementShowTheHiddenLabelBesideTheContact() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let point = CGPoint(x: grid.bounds.maxX - grid.safeAreaInsets.right - 1, y: try nativeThumb(on: grid).midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 100)
        XCTAssertTrue(presenter.controller.presentation.isVisible)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        XCTAssertTrue(presenter.controller.policy.isDragOffset)
        let normalRight = normalLabelRight(on: grid)
        let offset = TimelineScrollDateLabelGeometry.indicatorDragOffset(
            normalRightX: normalRight, thumbLeftX: try nativeThumb(on: grid).minX,
            contactX: point.x, contactRadius: 18)
        XCTAssertEqual(presenter.view.frame.maxX, normalRight - offset, accuracy: 1)
        XCTAssertLessThan(presenter.view.transform.tx, 0)
        presenter.indicatorDragObserver.finishContact()
        XCTAssertNotNil(presenter.controller.policy.hideDeadline)
        XCTAssertFalse(presenter.controller.policy.isDragOffset, "release returns during linger")
    }

    func testASuppressedLabelDoesNotRecognizeAnIndicatorContact() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.suppress()
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: grid.bounds.maxX - grid.safeAreaInsets.right - 1, y: try nativeThumb(on: grid).midY),
            radius: 18)
        presenter.viewportMoved(.init(), offsetY: 100)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        XCTAssertEqual(presenter.indicatorDragObserver.state, .possible)
    }

    func testContentContactAndHostJumpsDoNotCountAsIndicatorDrags() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: grid.bounds.midX, y: grid.bounds.midY), radius: 18)
        presenter.viewportMoved(.init(), offsetY: 100)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: grid.bounds.maxX - grid.safeAreaInsets.right - 1, y: try nativeThumb(on: grid).midY),
            radius: 18)
        presenter.viewportMoved(.init(isHostDriven: true, isJump: true), offsetY: 500)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        presenter.indicatorDragObserver.finishContact()
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
    }

    func testEdgeContentContactOutsideTheThumbDoesNotForceTheLabel() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: thumb.midX, y: min(grid.bounds.maxY - 20, thumb.maxY + 50)), radius: 0)
        presenter.viewportMoved(.init(), offsetY: 100)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
    }

    func testIndicatorContactSlidesAnAlreadyVisibleLabelAndReleaseRestoresNormalScrolling() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let normalRight = presenter.view.frame.maxX
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 100)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        XCTAssertLessThan(presenter.view.frame.maxX, normalRight)
        presenter.indicatorDragObserver.finishContact()
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
        try showLabel(on: grid)
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
        XCTAssertEqual(presenter.view.frame.maxX, normalRight, accuracy: 0.01)
    }

    func testContactEnvelopeIncludesTheThumbWithoutClaimingTheWholeEdge() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: thumb.minX - 10, y: thumb.midY), radius: 18)
        presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 100)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        presenter.indicatorDragObserver.finishContact()
        presenter.controller.hide()
        presenter.indicatorDragObserver.contactBegan(
            at: CGPoint(x: thumb.midX, y: thumb.maxY + 30), radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
    }

    func testContactResetAndSuppressionDoNotLeaveIndicatorTrackingBehind() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 100)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        presenter.indicatorDragObserver.reset()
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
        XCTAssertEqual(presenter.view.transform.tx, 0)
        presenter.controller.suppress()
        presenter.controller.resume()
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        presenter.viewportMoved(.init(isTracking: true, isDragging: true), offsetY: 200)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        presenter.controller.suppress()
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
        presenter.controller.resume()
        presenter.indicatorDragObserver.finishContact()
        try showLabel(on: grid)
        XCTAssertFalse(presenter.controller.policy.isDragOffset)
        XCTAssertEqual(presenter.view.transform.tx, 0)
    }

    func testNativeMomentumSamplesDoNotCancelAValidatedThumbContact() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        for y in [CGFloat(0), 5_000, 15_000, 25_000] {
            presenter.viewportMoved(.init(isTracking: true, isDragging: true, isDecelerating: true), offsetY: y)
            XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
            XCTAssertTrue(presenter.controller.presentation.isVisible)
            XCTAssertNil(presenter.controller.policy.hideDeadline)
            XCTAssertLessThan(presenter.view.transform.tx, 0)
        }
        presenter.indicatorDragObserver.finishContact()
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
    }

    func testThumbTouchDownStartsTheSlideAndReleaseStartsTheReturn() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertTrue(presenter.controller.policy.isDragOffset, "touch-down must not wait for viewport movement")
        XCTAssertLessThan(presenter.view.transform.tx, 0)
        XCTAssertNotNil(presenter.view.layer.animation(forKey: "transform"), "a visible label slides with animation")
        presenter.indicatorDragObserver.finishContact()
        XCTAssertFalse(presenter.controller.policy.isDragOffset, "release starts the return at once")
        XCTAssertEqual(presenter.view.transform.tx, 0)
    }

    func testLiveFingerPositionPreservesTheCurrentSlide() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18.15)
        let animation = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform"))
        presenter.indicatorDragObserver.contactMoved(at: point, radius: 18.15)
        XCTAssertEqual(presenter.view.layer.animation(forKey: "transform")?.beginTime, animation.beginTime)
        var previousRadius: CGFloat = 18.15
        for (delta, radius) in [(CGFloat(-8), CGFloat(30.25)), (-8.5, 30.25), (-8.5, 42.35), (2, 18.15)] {
            let moved = CGPoint(x: point.x + delta, y: point.y)
            let precedingSlide = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform"))
            presenter.indicatorDragObserver.contactMoved(at: moved, radius: radius)
            XCTAssertEqual(presenter.view.frame.maxX, moved.x - radius - 16.964134412507207, accuracy: 0.001)
            let slide = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform") as? CABasicAnimation)
            XCTAssertTrue(slide.isAdditive)
            if radius == previousRadius {
                XCTAssertEqual(
                    slide.beginTime, precedingSlide.beginTime, "position-only movement keeps the current ease")
                XCTAssertNil(presenter.controller.presentation.slideDuration)
            } else {
                XCTAssertEqual(presenter.controller.presentation.slideDuration, 0.22)
            }
            previousRadius = radius
            XCTAssertEqual(slide.duration, 0.22)
            XCTAssertTrue(presenter.controller.presentation.isVisible)
            XCTAssertNil(presenter.controller.policy.hideDeadline)
        }
        presenter.view.layer.removeAnimation(forKey: "transform")
        presenter.indicatorDragObserver.contactMoved(at: point, radius: previousRadius)
        XCTAssertNil(
            presenter.view.layer.animation(forKey: "transform"), "settled position tracking creates no animation")
        presenter.indicatorDragObserver.finishContact()
        XCTAssertEqual(presenter.view.transform.tx, 0)
        XCTAssertEqual(presenter.view.layer.animation(forKey: "transform")?.duration, 0.22)
        presenter.indicatorDragObserver.contactMoved(at: point, radius: 54.46)
        XCTAssertEqual(presenter.view.transform.tx, 0, "movement after release cannot revive the contact")
    }

    func testRadiusChangesEaseWhileFingerPositionChangesRemainDirect() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18.15)
        presenter.view.layer.removeAnimation(forKey: "transform")
        presenter.indicatorDragObserver.contactMoved(at: point, radius: 30.25)
        XCTAssertEqual(presenter.controller.presentation.slideDuration, 0.22)
        let slide = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform") as? CABasicAnimation)
        XCTAssertTrue(slide.isAdditive)
        XCTAssertEqual(slide.duration, 0.22)
        presenter.indicatorDragObserver.contactMoved(
            at: CGPoint(x: point.x - 1, y: point.y), radius: 30.25)
        XCTAssertNil(presenter.controller.presentation.slideDuration)
        XCTAssertEqual(presenter.view.layer.animation(forKey: "transform")?.beginTime, slide.beginTime)
        presenter.indicatorDragObserver.finishContact()
    }

    func testReduceMotionMovementDoesNotReapplyAnUnchangedGlassShow() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        let witness = CABasicAnimation(keyPath: "opacity")
        witness.duration = 100
        presenter.view.layer.add(witness, forKey: "unchanged-show")
        presenter.indicatorDragObserver.contactMoved(at: CGPoint(x: point.x - 1, y: point.y), radius: 18)
        XCTAssertNotNil(presenter.view.layer.animation(forKey: "unchanged-show"))
        presenter.indicatorDragObserver.finishContact()
    }

    func testASecondSeparatedTouchSampleEndsContactWithoutANativeLayout() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let observer = presenter.indicatorDragObserver
        var forwarded = 0
        let forward = observer.onContact
        observer.onContact = { point, radius, began in
            forwarded += 1
            return forward?(point, radius, began) ?? false
        }
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        observer.contactBegan(at: point, radius: 18)
        observer.contactMoved(at: CGPoint(x: point.x, y: point.y + 100), radius: 18)
        observer.contactMoved(at: CGPoint(x: point.x, y: point.y + 110), radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertEqual(presenter.view.transform.tx, 0)
        let count = forwarded
        observer.contactMoved(at: point, radius: 18)
        XCTAssertEqual(forwarded, count, "no more input is forwarded after the contact ended")
        // Without delivered UITouch events, UIKit normalizes requested cancellation to failed.
        XCTAssertEqual(observer.state, .failed)
    }

    func testMissingThumbEndsContactAndInactiveLayoutsLeaveTheRecognizerAlone() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let observer = presenter.indicatorDragObserver
        let thumb = try nativeThumb(on: grid)
        let state = observer.state
        grid.scrollView.onVerticalIndicatorLayout?(nil)
        XCTAssertEqual(observer.state, state)
        grid.scrollView.onVerticalIndicatorLayout?(grid.scrollView.verticalIndicatorRect)
        observer.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
        grid.scrollView.onVerticalIndicatorLayout?(nil)
        // Without delivered UITouch events, UIKit normalizes requested cancellation to failed.
        XCTAssertEqual(observer.state, .failed)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertEqual(presenter.view.transform.tx, 0)
    }

    func testAnUnchangedReducedMotionTargetClearsAnExistingSlideOnANewPresentation() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        presenter.view.setDragOffset(presenter.controller.presentation.indicatorOffset, duration: 0.22, tracking: false)
        XCTAssertNotNil(presenter.view.layer.animation(forKey: "transform"))
        presenter.controller.setAnchor(flatIndex: 15)
        XCTAssertNil(presenter.view.layer.animation(forKey: "transform"))
        presenter.indicatorDragObserver.finishContact()
    }

    func testPassiveObserverConfigurationAndRetirement() throws {
        let grid = try hostInWindow()
        let observer = grid.scrollDateLabel.indicatorDragObserver
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        let other = UIGestureRecognizer(target: nil, action: nil)
        XCTAssertFalse(observer.canPrevent(other))
        XCTAssertFalse(observer.canBePrevented(by: other))
        grid.scrollDateLabel.retire()
        XCTAssertFalse(observer.isEnabled)
    }

    func testTurningReduceMotionOnDuringTheOnsetClearsTheSlide() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertNotNil(presenter.view.layer.animation(forKey: "transform"))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = 100
        presenter.view.layer.add(fade, forKey: "visibility-fade")
        presenter.setReduceMotion(true)
        XCTAssertNil(presenter.view.layer.animation(forKey: "transform"))
        XCTAssertNil(
            presenter.view.layer.animation(forKey: "visibility-fade"), "the changed fade duration stops the fade")
        // Exercise the shared helper directly too, independent of a simultaneous glass-fade cancellation.
        presenter.view.setDragOffset(30, duration: 0.22, tracking: false)
        presenter.view.setDragOffset(30, duration: nil, tracking: false)
        XCTAssertNil(presenter.view.layer.animation(forKey: "transform"))
        presenter.indicatorDragObserver.finishContact()
    }

    func testDirectLayerTrackingDoesNotCopyThePresentationTree() {
        let layer = PresentationCountingLayer()
        LayerPresentation.setTranslationX(-30, on: layer, duration: nil, tracking: true)
        XCTAssertEqual(layer.presentationReads, 0)
        LayerPresentation.setTranslationX(-40, on: layer, duration: 0.22, tracking: false)
        XCTAssertEqual(layer.presentationReads, 1)
    }

    func testAContentDragThatLeavesTheThumbEndsContactAndCannotRebind() throws {
        for reduceMotion in [false, true] {
            let grid = try hostInWindow()
            grid.setScrollDateLabelEnabled(true, reduceMotion: reduceMotion)
            try showLabel(on: grid)
            // This geometry fixture has no grid items; keep native layout without the empty-grid suppression delegate.
            grid.scrollView.delegate = nil
            grid.scrollView.contentOffset.y = grid.bounds.height * 8
            grid.scrollView.layoutIfNeeded()
            let presenter = grid.scrollDateLabel
            let thumb = try nativeThumb(on: grid)
            let point = CGPoint(x: thumb.midX, y: thumb.midY)
            presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
            XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
            // A normal upward content drag moves the thumb slightly downward, away from the finger.
            presenter.indicatorDragObserver.contactMoved(
                at: CGPoint(x: point.x - 5, y: point.y - 100), radius: 18)
            grid.scrollView.contentOffset.y += 100
            grid.scrollView.layoutIfNeeded()
            let currentThumb = try nativeThumb(on: grid)
            XCTAssertGreaterThan(currentThumb.midY, thumb.midY, "SETUP: the native thumb really drifted")
            XCTAssertFalse(presenter.controller.policy.isIndicatorDragging, "leaving the thumb ends the binding")
            XCTAssertEqual(presenter.view.transform.tx, 0, "the label returns to its normal edge")
            XCTAssertNotNil(presenter.controller.policy.hideDeadline, "release starts the normal linger")
            XCTAssertEqual(presenter.view.layer.animation(forKey: "transform")?.duration, reduceMotion ? nil : 0.22)
            presenter.indicatorDragObserver.contactMoved(
                at: CGPoint(x: currentThumb.midX, y: currentThumb.midY), radius: 30)
            XCTAssertFalse(presenter.controller.policy.isIndicatorDragging, "re-entry in the same touch cannot bind")
            XCTAssertEqual(presenter.view.transform.tx, 0)
            presenter.indicatorDragObserver.finishContact()
        }
    }

    func testAnEngagedScrubKeepsContactInEachNativeCallbackOrder() throws {
        enum CallbackOrder: CaseIterable {
            case touchBeforePan, layoutBeforeTouch, panBeforeTouchBeforeLayout
        }
        for order in CallbackOrder.allCases {
            let grid = try hostInWindow()
            grid.setScrollDateLabelEnabled(true, reduceMotion: true)
            try showLabel(on: grid)
            grid.scrollView.delegate = nil
            // Measure real thumb positions before contact; no inferred track or amplification factor is needed.
            var samples: [(CGFloat, CGPoint)] = []
            for offset in [CGFloat(0), 1_000, 2_000, 3_000] {
                grid.scrollView.contentOffset.y = offset
                grid.scrollView.layoutIfNeeded()
                let thumb = try nativeThumb(on: grid)
                samples.append((offset, CGPoint(x: thumb.midX, y: thumb.midY)))
            }
            grid.scrollView.contentOffset.y = 0
            grid.scrollView.layoutIfNeeded()
            let presenter = grid.scrollDateLabel
            presenter.indicatorDragObserver.contactBegan(at: samples[0].1, radius: 18)
            for (offset, point) in samples.dropFirst() {
                // The touch arrives before the native scroll view updates its geometry.
                if order == .touchBeforePan { presenter.indicatorDragObserver.contactMoved(at: point, radius: 18) }
                grid.scrollView.contentOffset.y = offset
                if order == .panBeforeTouchBeforeLayout {
                    // The native pan changed bounds, but no layout has refreshed the scroll-space thumb yet.
                    presenter.indicatorDragObserver.contactMoved(at: point, radius: 18)
                    XCTAssertTrue(presenter.controller.policy.isIndicatorDragging, "pending layout keeps the contact")
                }
                grid.scrollView.layoutIfNeeded()
                if order == .layoutBeforeTouch { presenter.indicatorDragObserver.contactMoved(at: point, radius: 18) }
                XCTAssertEqual(presenter.indicatorDragObserver.state, .changed)
                let currentThumb = try nativeThumb(on: grid)
                XCTAssertEqual(currentThumb.midY, point.y, accuracy: 0.001)
                XCTAssertTrue(presenter.controller.policy.isIndicatorDragging, "the thumb follows the held finger")
                XCTAssertTrue(presenter.controller.presentation.isVisible)
                XCTAssertNil(presenter.controller.policy.hideDeadline)
            }
            presenter.indicatorDragObserver.finishContact()
            XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
            XCTAssertEqual(presenter.view.transform.tx, 0)
        }
    }

    func testVerticalOffsetRangeIncludesInsetsAndPreservesTheGridFloor() throws {
        let grid = try hostInWindow()
        let scroll = grid.scrollView
        scroll.delegate = nil
        scroll.frame.size.height = 800.125
        scroll.contentInset = UIEdgeInsets(top: 20.25, left: 0, bottom: 30.5, right: 0)
        scroll.contentSize.height = 5_000.25
        XCTAssertEqual(scroll.verticalOffsetRange.lowerBound, -20.25)
        XCTAssertEqual(scroll.verticalOffsetRange.upperBound, 4_230.625)
        XCTAssertEqual(grid.maxContentOffsetY, 4_230.625)
        scroll.contentSize.height = 100
        XCTAssertEqual(scroll.verticalOffsetRange, -20.25 ... -20.25)
        XCTAssertEqual(grid.maxContentOffsetY, 0)
    }

    func testVerticalEndToleranceIsHalfADevicePixel() throws {
        let grid = try hostInWindow()
        let scroll = grid.scrollView
        scroll.delegate = nil
        scroll.contentSize.height = scroll.bounds.height + 100
        for pixels in [CGFloat(0.25), 0.5, 0.75] {
            let inset = pixels / scroll.traitCollection.displayScale
            scroll.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
            for atTop in [true, false] {
                scroll.contentOffset.y = atTop ? 0 : 100
                XCTAssertEqual(scroll.contentOffset.y, atTop ? 0 : 100, "SETUP: native rounding keeps this offset")
                let ends = scroll.clampedVerticalEnds
                XCTAssertEqual(atTop ? ends.top : ends.bottom, pixels <= 0.5)
                XCTAssertFalse(atTop ? ends.bottom : ends.top)
            }
        }
    }

    func testAScrubBeyondEitherTrackEndKeepsContactAndCanReturn() throws {
        for atTop in [true, false] {
            for insetPixels in [CGFloat(0), 0.25] {
                let grid = try hostInWindow()
                grid.setScrollDateLabelEnabled(true, reduceMotion: true)
                try showLabel(on: grid)
                grid.scrollView.delegate = nil
                let scroll = grid.scrollView
                let inset = insetPixels / scroll.traitCollection.displayScale
                // Fractional insets/content make the native end fall between device pixels.
                scroll.contentInset.top += inset
                scroll.contentSize.height += inset
                let range = scroll.verticalOffsetRange
                let boundary = atTop ? range.lowerBound : range.upperBound
                let requestedOffset = boundary + (atTop ? inset : -inset)
                scroll.contentOffset.y = requestedOffset
                scroll.layoutIfNeeded()
                XCTAssertEqual(
                    abs(scroll.contentOffset.y - boundary) * scroll.traitCollection.displayScale,
                    insetPixels, accuracy: 0.001, "SETUP: the actual offset is inside the fractional boundary")
                let thumb = try nativeThumb(on: grid)
                let observer = grid.scrollDateLabel.indicatorDragObserver
                observer.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
                XCTAssertTrue(grid.scrollDateLabel.controller.policy.isIndicatorDragging)
                for distance in [CGFloat(100), 150, 200] {
                    observer.contactMoved(
                        at: CGPoint(x: thumb.midX, y: thumb.midY + (atTop ? -distance : distance)), radius: 18)
                    XCTAssertTrue(
                        grid.scrollDateLabel.controller.policy.isIndicatorDragging,
                        "the clamped side stays open, inset pixels: \(insetPixels)")
                    XCTAssertTrue(grid.scrollDateLabel.controller.presentation.isVisible)
                    XCTAssertEqual(observer.state, .changed)
                    XCTAssertNil(grid.scrollDateLabel.controller.policy.hideDeadline)
                }
                // Overscroll forces a native layout while the finger remains beyond the open end.
                scroll.contentOffset.y = boundary + (atTop ? -2 : 2)
                scroll.layoutIfNeeded()
                XCTAssertTrue(
                    grid.scrollDateLabel.controller.policy.isIndicatorDragging,
                    "layout also keeps the clamped side open")
                let current = try nativeThumb(on: grid)
                observer.contactMoved(at: CGPoint(x: current.midX, y: current.midY), radius: 18)
                XCTAssertTrue(grid.scrollDateLabel.controller.policy.isIndicatorDragging, "the finger can return")
                for distance in [CGFloat(100), 110] {
                    observer.contactMoved(
                        at: CGPoint(x: current.midX, y: current.midY + (atTop ? distance : -distance)), radius: 18)
                }
                XCTAssertFalse(
                    grid.scrollDateLabel.controller.policy.isIndicatorDragging,
                    "the opposite side stays closed even at a clamped end")
            }
        }
    }

    func testAFingerRestingOnTheThumbStaysBoundWhenTheIndicatorFades() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        try nativeIndicator(on: grid).alpha = 0
        for _ in 0..<3 {
            presenter.indicatorDragObserver.contactMoved(at: point, radius: 18)
            grid.scrollView.layoutIfNeeded()
            XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
            XCTAssertNil(presenter.controller.policy.hideDeadline)
        }
        presenter.indicatorDragObserver.finishContact()
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
    }

    func testEqualRadiusContactsFollowTheFingerAtDifferentEligibleXPositions() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        for x in [CGFloat(420), 434, 438] {
            presenter.controller.hide()
            presenter.indicatorDragObserver.contactBegan(
                at: CGPoint(x: thumb.minX + x - 434, y: thumb.midY), radius: 18)
            XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
            XCTAssertEqual(thumb.minX - presenter.view.frame.maxX, 434 - x + 18 + 16.964134412507207, accuracy: 0.001)
            presenter.indicatorDragObserver.finishContact()
        }
    }

    func testHiddenLabelStartsAtTheOffsetWithoutASlideAnimationWhenMotionIsEnabled() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertTrue(presenter.controller.presentation.isVisible)
        XCTAssertEqual(
            thumb.minX - presenter.view.frame.maxX, 18 + 16.964134412507207 - thumb.width / 2, accuracy: 0.001)
        XCTAssertNil(presenter.view.layer.animation(forKey: "transform"), "the hidden label fades in at the target")
    }

    func testDisabledPresenterAndDisabledNativeIndicatorRejectThumbContacts() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        let point = CGPoint(x: thumb.midX, y: thumb.midY)
        presenter.setEnabled(false)
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        presenter.setEnabled(true)
        grid.scrollView.showsVerticalScrollIndicator = false
        presenter.indicatorDragObserver.contactBegan(at: point, radius: 18)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
    }

    func testTheMeasuredContactEnvelopeAndPhysicalEdgeInsetAreIncluded() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        let thumb = try nativeThumb(on: grid)
        XCTAssertGreaterThan(grid.bounds.maxX - thumb.maxX, 1, "SETUP: there is a native trailing inset")
        for (point, radius) in [
            (CGPoint(x: grid.bounds.maxX - 1, y: thumb.midY), CGFloat(0)),
            (CGPoint(x: thumb.minX - 29, y: thumb.midY), 30),
        ] {
            presenter.controller.hide()
            presenter.indicatorDragObserver.contactBegan(at: point, radius: radius)
            XCTAssertTrue(presenter.controller.policy.isIndicatorDragging)
            presenter.indicatorDragObserver.finishContact()
        }
    }

    func testAThumbGrabDuringVisibleFadeOutStillAnimatesTheSlide() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.nonUserMoved(isJump: true)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        XCTAssertFalse(presenter.view.isHidden, "SETUP: the label is still visibly fading out")
        let thumb = try nativeThumb(on: grid)
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertNotNil(presenter.view.layer.animation(forKey: "transform"), "a fading visible label must not jump")
    }

    func testViewportPositionUpdatesPreserveTheHorizontalAnimation() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: false)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        // A long test animation avoids a wall-clock race while exercising the real native layer and layout callback.
        presenter.view.setDragOffset(60, duration: 10, tracking: false)
        let original = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform"))
        let thumb = try XCTUnwrap(grid.scrollView.verticalIndicatorRect)
        let originalY = presenter.view.center.y
        for delta in [CGFloat(10), 20, 30] {
            grid.scrollView.onVerticalIndicatorLayout?(thumb.offsetBy(dx: 0, dy: delta))
            let current = try XCTUnwrap(presenter.view.layer.animation(forKey: "transform"))
            XCTAssertEqual(current.duration, original.duration)
            XCTAssertEqual(current.beginTime, original.beginTime)
            XCTAssertEqual(presenter.view.transform.tx, -60)
        }
        XCTAssertGreaterThan(presenter.view.center.y, originalY, "the vertical viewport position actually changed")
    }

    func testThumbContactDuringAnOffsetAnimationDoesNotShowTheLabel() throws {
        let grid = try hostInWindow()
        grid.setScrollDateLabelEnabled(true, reduceMotion: true)
        try showLabel(on: grid)
        let presenter = grid.scrollDateLabel
        presenter.controller.hide()
        let thumb = try nativeThumb(on: grid)
        grid.scrollView.setContentOffset(CGPoint(x: 0, y: grid.bounds.height * 5), animated: true)
        XCTAssertTrue(grid.scrollView.isScrollAnimating, "SETUP: the offset animation is active")
        presenter.indicatorDragObserver.contactBegan(at: CGPoint(x: thumb.midX, y: thumb.midY), radius: 18)
        XCTAssertFalse(presenter.controller.presentation.isVisible)
        XCTAssertFalse(presenter.controller.policy.isIndicatorDragging)
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

private final class PresentationCountingLayer: CALayer {
    var presentationReads = 0
    override func presentation() -> Self? {
        presentationReads += 1
        return super.presentation()
    }
}
