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
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
            let (stillHost, _, stillPress) = try makePhotoHost(onStart: nil, onStop: nil)
            defer { withExtendedLifetime(stillHost) {} }
            XCTAssertFalse(stillPress.isEnabled)
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
            for other in [
                NSPanGestureRecognizer(), NSMagnificationGestureRecognizer(), NSClickGestureRecognizer(),
                NSPressGestureRecognizer(),
            ] {
                XCTAssertEqual(
                    press.delegate?.gestureRecognizer?(press, shouldRecognizeSimultaneouslyWith: other), true)
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
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.willStartLiveMagnifyNotification] {
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
            press.consume(.changed, at: NSPoint(x: press.allowableMovement, y: 0))
            XCTAssertEqual(calls, ["start"])
            press.consume(.changed, at: NSPoint(x: press.allowableMovement + 1, y: 0))
            XCTAssertEqual(calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testLiveTextQueriesAndMenusUseTheInstalledDelegate() async throws {
            let image = NSImage(size: NSSize(width: 800, height: 200))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 800, height: 200).fill()
            ("LIVE PHOTO" as NSString).draw(
                at: NSPoint(x: 40, y: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            image.unlockFocus()
            let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
            XCTAssertFalse(analysis.transcript.isEmpty)
            var calls: [String] = []
            let (host, scroll, press) = try makePhotoHost(
                onStart: { calls.append("start") }, onStop: { calls.append("stop") }, analysis: analysis, image: image)
            defer { withExtendedLifetime(host) {} }
            let overlay = try XCTUnwrap(
                scroll.documentView?.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
            let delegate = try XCTUnwrap(overlay.delegate)
            let imageView = try XCTUnwrap(scroll.documentView)
            var recognizedPoint: NSPoint?
            for y in stride(from: CGFloat(0), to: overlay.bounds.height, by: 8) {
                for x in stride(from: CGFloat(0), to: overlay.bounds.width, by: 8) {
                    let point = NSPoint(x: x, y: y)
                    if overlay.analysisHasText(at: point) {
                        recognizedPoint = point
                        break
                    }
                }
                if recognizedPoint != nil { break }
            }
            let textPoint = try XCTUnwrap(recognizedPoint, "The displayed analysis must expose a text hit")
            XCTAssertTrue(press.textOwnsPoint(imageView.convert(textPoint, from: overlay)))
            XCTAssertFalse(press.textOwnsPoint(.zero))
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            XCTAssertTrue(delegate.overlayView(overlay, shouldShowMenuForEvent: event, atPoint: .zero))
            press.consume(.began, at: .zero)
            for type: ImageAnalysisOverlayView.InteractionTypes in [.textSelection, .dataDetectors] {
                XCTAssertTrue(delegate.overlayView(overlay, shouldBeginAt: .zero, forAnalysisType: type))
                XCTAssertEqual(calls, ["start"])
            }
            delegate.textSelectionDidChange(overlay)
            XCTAssertEqual(calls, ["start"])
            XCTAssertFalse(delegate.overlayView(overlay, shouldShowMenuForEvent: event, atPoint: .zero))
            let text = overlay.text
            XCTAssertFalse(text.isEmpty)
            overlay.selectedRanges = [text.startIndex..<text.endIndex]
            XCTAssertTrue(overlay.hasActiveTextSelection)
            delegate.textSelectionDidChange(overlay)
            XCTAssertEqual(calls, ["start", "stop"])
            XCTAssertFalse(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
            XCTAssertTrue(delegate.overlayView(overlay, shouldShowMenuForEvent: event, atPoint: .zero))
            overlay.resetSelection()
            delegate.textSelectionDidChange(overlay)
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
        }

        func testMovingOntoUnselectedTextDoesNotStopTheHold() {
            let press = AppKitLivePhotoHoldAdapter()
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            var overText = false
            press.textOwnsPoint = { _ in overText }
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            overText = true
            XCTAssertFalse(press.gestureRecognizerShouldBegin(press))
            press.consume(.changed, at: .zero)
            XCTAssertEqual(calls, ["start"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(calls, ["start", "stop"])
        }

        func testNativeActionMeasuresMovementInWindowPointsAtFiveTimesZoom() throws {
            let press = InjectedAppKitHold()
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            press.allowableMovement = 10
            let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            image.addGestureRecognizer(press)
            let action = try XCTUnwrap(press.action)
            press.injectedState = .began
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: press.target, from: press))
            press.windowPoint = NSPoint(x: 11, y: 0)
            press.injectedState = .changed
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: press.target, from: press))
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
            onStart: (() -> Void)? = {}, onStop: (() -> Void)? = {}, analysis: ImageAnalysis? = nil,
            image: NSImage? = nil
        ) throws -> (NSHostingView<AnyView>, ZoomScrollView, AppKitLivePhotoHoldAdapter) {
            let host = NSHostingView(
                rootView: AnyView(
                    ZoomableImageView(
                        image: image ?? NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "first",
                        onMotionStart: onStart, onMotionStop: onStop, liveTextAnalysis: analysis)))
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

    private final class InjectedAppKitHold: AppKitLivePhotoHoldAdapter {
        var injectedState = NSGestureRecognizer.State.possible
        var windowPoint = NSPoint.zero
        override var state: NSGestureRecognizer.State {
            get { injectedState }
            set { injectedState = newValue }
        }
        override func location(in view: NSView?) -> NSPoint {
            view == nil ? windowPoint : NSPoint(x: windowPoint.x / 5, y: windowPoint.y / 5)
        }
    }

    private final class HoldMagnifyEvent: NSEvent {
        override var phase: NSEvent.Phase { .began }
        override var magnification: CGFloat { -0.1 }
    }
#endif
