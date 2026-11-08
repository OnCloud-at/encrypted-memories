#if os(macOS)
    import AppKit
    import PhotoViewerCore
    import SwiftUI
    import VisionKit
    import XCTest
    @testable import PhotoViewerFeature

    @MainActor
    final class LivePhotoHoldAdapterTests: XCTestCase {
        func testPhotoInstallsDirectTouchPressWithoutDelayingPointerEvents() throws {
            let (host, _, press) = try makePhotoHost()
            defer { withExtendedLifetime(host) {} }
            XCTAssertEqual(press.allowedTouchTypes, .direct)
            XCTAssertEqual(press.buttonMask, 0)
            XCTAssertEqual(press.numberOfTouchesRequired, 1)
            XCTAssertEqual(press.minimumPressDuration, LivePhotoHoldPolicy.minimumPressDuration)
            XCTAssertFalse(press.delaysPrimaryMouseButtonEvents)
            XCTAssertFalse(press.delaysSecondaryMouseButtonEvents)
            XCTAssertFalse(press.delaysOtherMouseButtonEvents)
            XCTAssertFalse(press.delaysKeyEvents)
            XCTAssertFalse(press.delaysMagnificationEvents)
            XCTAssertFalse(press.delaysRotationEvents)
            if #available(macOS 27.0, *) { XCTAssertTrue(press.isCancellableByScrollGesture) }
            for other in [NSPanGestureRecognizer(), NSMagnificationGestureRecognizer(), NSClickGestureRecognizer()] {
                XCTAssertFalse(press.canPrevent(other))
                XCTAssertTrue(press.canBePrevented(by: other))
                XCTAssertFalse(press.shouldRequireFailure(of: other))
            }
            press.isEnabled = false
            press.cancel(.scroll)
            XCTAssertFalse(press.isEnabled)
        }

        func testInjectedStatesStartOnceAndStopOnceWithoutAnEarlyStop() {
            let press = AppKitLivePhotoHoldAdapter()
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            for terminal: NSGestureRecognizer.State in [.ended, .cancelled, .failed] {
                calls = []
                for state: NSGestureRecognizer.State in [
                    .possible, .changed, terminal, .began, .began, .changed, terminal, terminal,
                ] {
                    press.consume(state, at: .zero)
                }
                XCTAssertEqual(calls, ["start", "stop"])
            }
        }

        func testNativeScrollAndPinchNotificationsCancelOnlyTheirPhoto() throws {
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.willStartLiveMagnifyNotification] {
                var calls: [String] = []
                let (host, scroll, press) = try makePhotoHost(
                    onStart: { calls.append("start") }, onStop: { calls.append("stop") })
                defer { withExtendedLifetime(host) {} }
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertTrue(calls.isEmpty)
                press.consume(.began, at: .zero)
                NotificationCenter.default.post(name: name, object: NSScrollView())
                XCTAssertEqual(calls, ["start"])
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertEqual(calls, ["start", "stop"])
                press.consume(.changed, at: .zero)
                press.consume(.ended, at: .zero)
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertEqual(calls, ["start", "stop"])
                XCTAssertTrue(press.isEnabled)
            }
        }

        func testLegacyWheelCancelsBeforeNativeScrollHandling() throws {
            var calls: [String] = []
            let (host, scroll, press) = try makePhotoHost(
                onStart: { calls.append("start") }, onStop: { calls.append("stop") })
            defer { withExtendedLifetime(host) {} }
            press.consume(.began, at: .zero)
            let event = try XCTUnwrap(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
            XCTAssertEqual(calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testMagnifyCancelsBeforeNativeZoomHandling() throws {
            var calls: [String] = []
            let (host, scroll, press) = try makePhotoHost(
                onStart: { calls.append("start") }, onStop: { calls.append("stop") })
            defer { withExtendedLifetime(host) {} }
            press.consume(.began, at: .zero)
            scroll.magnify(with: HoldMagnifyEvent())
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testRemovingMotionCallbacksStopsBeforeTheirReplacement() throws {
            var calls: [String] = []
            let (host, _, press) = try makePhotoHost(
                onStart: { calls.append("start") }, onStop: { calls.append("stop") })
            press.consume(.began, at: .zero)
            host.rootView = AnyView(
                ZoomableImageView(
                    image: NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "first"))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(calls, ["start", "stop"])
            XCTAssertFalse(press.isEnabled)
        }

        func testMovementAfterRecognitionStopsAtNativeMovementLimit() {
            let press = AppKitLivePhotoHoldAdapter()
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            press.consume(.began, at: .zero)
            press.consume(.changed, at: NSPoint(x: press.allowableMovement / 2, y: 0))
            XCTAssertEqual(calls, ["start"])
            press.consume(.changed, at: NSPoint(x: press.allowableMovement + 1, y: 0))
            XCTAssertEqual(calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testLiveTextExcludesBeginAndStopsAnActiveHold() {
            let coordinator = ZoomableImageView.Coordinator()
            let press = coordinator.motionHold
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            press.textOwnsPoint = { _ in true }
            XCTAssertFalse(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            press.consume(.ended, at: .zero)
            XCTAssertTrue(calls.isEmpty)
            press.textOwnsPoint = { _ in false }
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            XCTAssertTrue(
                coordinator.overlayView(
                    ImageAnalysisOverlayView(), shouldBeginAt: .zero, forAnalysisType: .textSelection))
            XCTAssertEqual(calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testPageChangeAndTeardownStopTheHostedHold() throws {
            var calls: [String] = []
            let (host, _, press) = try makePhotoHost(
                onStart: { calls.append("start") }, onStop: { calls.append("stop") })
            press.consume(.began, at: .zero)
            host.rootView = AnyView(
                ZoomableImageView(
                    image: NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "next",
                    onMotionStart: { calls.append("start") }, onMotionStop: { calls.append("stop") }))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(calls, ["start", "stop"])
            press.consume(.began, at: .zero)
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(calls, ["start", "stop", "start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop", "start", "stop"])
        }

        private func makePhotoHost(
            onStart: @escaping () -> Void = {}, onStop: @escaping () -> Void = {}
        ) throws -> (NSHostingView<AnyView>, ZoomScrollView, AppKitLivePhotoHoldAdapter) {
            let host = NSHostingView(
                rootView: AnyView(
                    ZoomableImageView(
                        image: NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "first",
                        onMotionStart: onStart, onMotionStop: onStop)))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            host.layoutSubtreeIfNeeded()
            var views = [host as NSView]
            var scroll: ZoomScrollView?
            while let view = views.popLast() {
                if let photoScroll = view as? ZoomScrollView { scroll = photoScroll }
                views += view.subviews
            }
            let photoScroll = try XCTUnwrap(scroll)
            let presses = (photoScroll.documentView?.gestureRecognizers ?? []).filter { $0.name == "LivePhotoHold" }
            XCTAssertEqual(presses.count, 1)
            return (host, photoScroll, try XCTUnwrap(presses.first as? AppKitLivePhotoHoldAdapter))
        }
    }

    private final class HoldMagnifyEvent: NSEvent {
        override var phase: NSEvent.Phase { .began }
        override var magnification: CGFloat { 0.1 }
    }
#endif
