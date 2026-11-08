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
            let probe = LivePhotoHoldProbe()
            let press = probe.press
            for terminal: NSGestureRecognizer.State in [.ended, .cancelled, .failed] {
                probe.calls = []
                for state: NSGestureRecognizer.State in [
                    .possible, .changed, terminal, .began, .began, .changed, terminal, terminal,
                ] {
                    press.consume(state, at: .zero)
                }
                XCTAssertEqual(probe.calls, ["start", "stop"])
            }
        }

        func testNativeScrollAndPinchNotificationsCancelOnlyTheirPhoto() throws {
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.willStartLiveMagnifyNotification] {
                let probe = LivePhotoHoldProbe()
                let (host, scroll, press) = try makePhotoHost(onStart: probe.onStart, onStop: probe.onStop)
                defer { withExtendedLifetime(host) {} }
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertTrue(probe.calls.isEmpty)
                press.consume(.began, at: .zero)
                NotificationCenter.default.post(name: name, object: NSScrollView())
                XCTAssertEqual(probe.calls, ["start"])
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertEqual(probe.calls, ["start", "stop"])
                press.consume(.changed, at: .zero)
                press.consume(.ended, at: .zero)
                NotificationCenter.default.post(name: name, object: scroll)
                XCTAssertEqual(probe.calls, ["start", "stop"])
                XCTAssertTrue(press.isEnabled)
            }
        }

        func testLegacyWheelCancelsBeforeNativeScrollHandling() throws {
            let probe = LivePhotoHoldProbe()
            let (host, scroll, press) = try makePhotoHost(onStart: probe.onStart, onStop: probe.onStop)
            defer { withExtendedLifetime(host) {} }
            press.consume(.began, at: .zero)
            let event = try XCTUnwrap(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
            XCTAssertEqual(probe.calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(probe.calls, ["start", "stop"])
        }

        func testMagnifyCancelsBeforeNativeZoomHandling() throws {
            let probe = LivePhotoHoldProbe()
            let (host, scroll, press) = try makePhotoHost(onStart: probe.onStart, onStop: probe.onStop)
            defer { withExtendedLifetime(host) {} }
            press.consume(.began, at: .zero)
            scroll.magnify(with: HoldMagnifyEvent())
            XCTAssertEqual(probe.calls, ["start", "stop"])
        }

        func testRemovingMotionCallbacksStopsBeforeTheirReplacement() async throws {
            let probe = LivePhotoHoldProbe()
            let (host, _, press) = try makePhotoHost(onStart: probe.onStart, onStop: probe.onStop)
            press.consume(.began, at: .zero)
            host.rootView = AnyView(
                ZoomableImageView(
                    image: NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "first"))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.calls, ["start"])
            await probe.finishViewUpdates()
            XCTAssertEqual(probe.calls, ["start", "stop"])
            XCTAssertFalse(press.isEnabled)
        }

        func testMovementAfterRecognitionStopsAtNativeMovementLimit() {
            let probe = LivePhotoHoldProbe()
            let press = probe.press
            press.consume(.began, at: .zero)
            press.consume(.changed, at: NSPoint(x: press.allowableMovement, y: 0))
            XCTAssertEqual(probe.calls, ["start"])
            press.consume(.changed, at: NSPoint(x: press.allowableMovement + 1, y: 0))
            XCTAssertEqual(probe.calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(probe.calls, ["start", "stop"])
        }

        func testLiveTextQueriesAndMenusUseTheInstalledDelegate() async throws {
            guard ImageAnalyzer.isSupported else {
                throw XCTSkip("VisionKit image analysis is unsupported on this host")
            }
            let image = NSImage(size: NSSize(width: 800, height: 200))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 800, height: 200).fill()
            ("LIVE PHOTO" as NSString).draw(
                at: NSPoint(x: 40, y: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            image.unlockFocus()
            let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
            guard !analysis.transcript.isEmpty else {
                throw XCTSkip("VisionKit returned no text for the known-text image on this host")
            }
            let probe = LivePhotoHoldProbe()
            let (host, scroll, press) = try makePhotoHost(
                onStart: probe.onStart, onStop: probe.onStop, analysis: analysis, image: image)
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
                XCTAssertEqual(probe.calls, ["start"])
            }
            delegate.textSelectionDidChange(overlay)
            XCTAssertEqual(probe.calls, ["start"])
            XCTAssertFalse(delegate.overlayView(overlay, shouldShowMenuForEvent: event, atPoint: .zero))
            let text = overlay.text
            XCTAssertFalse(text.isEmpty)
            overlay.selectedRanges = [text.startIndex..<text.endIndex]
            XCTAssertTrue(overlay.hasActiveTextSelection)
            delegate.textSelectionDidChange(overlay)
            XCTAssertEqual(probe.calls, ["start", "stop"])
            XCTAssertFalse(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            XCTAssertEqual(probe.calls, ["start", "stop"])
            XCTAssertTrue(delegate.overlayView(overlay, shouldShowMenuForEvent: event, atPoint: .zero))
            overlay.resetSelection()
            delegate.textSelectionDidChange(overlay)
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
        }

        func testMovingOntoUnselectedTextDoesNotStopTheHold() {
            let probe = LivePhotoHoldProbe()
            let press = probe.press
            var overText = false
            press.textOwnsPoint = { _ in overText }
            XCTAssertTrue(press.gestureRecognizerShouldBegin(press))
            press.consume(.began, at: .zero)
            overText = true
            XCTAssertFalse(press.gestureRecognizerShouldBegin(press))
            press.consume(.changed, at: .zero)
            XCTAssertEqual(probe.calls, ["start"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(probe.calls, ["start", "stop"])
        }

        func testNativeActionMeasuresMovementInWindowPointsAtFiveTimesZoom() throws {
            let press = InjectedAppKitHold()
            let probe = LivePhotoHoldProbe(press: press)
            press.allowableMovement = 10
            let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            image.addGestureRecognizer(press)
            let action = try XCTUnwrap(press.action)
            press.injectedState = .began
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: press.target, from: press))
            press.windowPoint = NSPoint(x: 11, y: 0)
            press.injectedState = .changed
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: press.target, from: press))
            XCTAssertEqual(probe.calls, ["start", "stop"])
        }

        func testPageChangeAndTeardownStopTheHostedHold() async throws {
            let probe = LivePhotoHoldProbe()
            let next = LivePhotoHoldProbe()
            let (host, _, press) = try makePhotoHost(onStart: probe.onStart, onStop: probe.onStop)
            press.consume(.began, at: .zero)
            host.rootView = AnyView(
                ZoomableImageView(
                    image: NSImage(size: NSSize(width: 40, height: 40)), itemIdentity: "next",
                    onMotionStart: next.onStart, onMotionStop: next.onStop))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.calls, ["start"])
            XCTAssertEqual(next.calls, [])
            await probe.finishViewUpdates()
            XCTAssertEqual(probe.calls, ["start", "stop"])
            XCTAssertEqual(next.calls, [])
            press.consume(.began, at: .zero)
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.calls, ["start", "stop"])
            XCTAssertEqual(next.calls, ["start"])
            await probe.finishViewUpdates()
            XCTAssertEqual(next.calls, ["start", "stop"])
            press.consume(.ended, at: .zero)
            XCTAssertEqual(next.calls, ["start", "stop"])
        }

        func testPendingCancellationResetsTheNativePressBeforeItBegins() {
            let press = InjectedAppKitHold()
            let probe = LivePhotoHoldProbe(press: press)
            for event: LivePhotoHoldPolicy.Event in [.scroll, .pinch, .pageChange, .teardown] {
                press.enabledWrites = []
                press.cancel(event)
                XCTAssertEqual(press.enabledWrites, [false, true])
                XCTAssertTrue(probe.calls.isEmpty)
            }
        }

        func testUnchangedEligibilityDoesNotWriteEnabledState() {
            let press = InjectedAppKitHold()
            let probe = LivePhotoHoldProbe(press: press, began: true)
            press.enabledWrites = []
            press.updateCallbacks(start: press.onStart, stop: press.onStop)
            XCTAssertEqual(press.enabledWrites, [])
            XCTAssertEqual(probe.calls, ["start"])
            press.isEnabled = false
            press.enabledWrites = []
            press.updateCallbacks(start: nil, stop: nil)
            XCTAssertEqual(press.enabledWrites, [])
        }

        func testTouchDownOriginIncludesMovementBeforeRecognitionAndResets() throws {
            let press = InjectedAppKitHold()
            let probe = LivePhotoHoldProbe(press: press)
            let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            image.addGestureRecognizer(press)
            press.allowableMovement = 10
            let touch = HoldTouch()
            touch.touchType = .indirect
            XCTAssertEqual(press.delegate?.gestureRecognizer?(press, shouldReceive: touch), true)
            XCTAssertEqual(touch.locationQueries, 0)
            touch.touchType = .direct
            XCTAssertEqual(press.delegate?.gestureRecognizer?(press, shouldReceive: touch), true)
            touch.point = NSPoint(x: 5, y: 0)
            XCTAssertEqual(press.delegate?.gestureRecognizer?(press, shouldReceive: touch), true)
            press.consume(.began, at: NSPoint(x: 10, y: 0))
            press.consume(.changed, at: NSPoint(x: 11, y: 0))
            XCTAssertEqual(probe.calls, ["start", "stop"])
            probe.calls = []
            // Failed pre-threshold recognition must not leave the first touch's origin behind.
            touch.point = NSPoint(x: 100, y: 0)
            XCTAssertEqual(press.delegate?.gestureRecognizer?(press, shouldReceive: touch), true)
            press.simulateNativeReset()
            touch.point = NSPoint(x: 200, y: 0)
            XCTAssertEqual(press.delegate?.gestureRecognizer?(press, shouldReceive: touch), true)
            press.consume(.began, at: touch.point)
            press.consume(.changed, at: touch.point)
            XCTAssertEqual(probe.calls, ["start"])
            press.consume(.ended, at: touch.point)
        }

        func testNonmovingMagnifyEventsDoNotCancelTheHold() {
            for movingPhase: NSEvent.Phase in [[], .began, .changed] {
                let probe = LivePhotoHoldProbe(began: true)
                let scroll = ZoomScrollView()
                scroll.motionHold = probe.press
                let event = HoldMagnifyEvent()
                for phase: NSEvent.Phase in [[], .mayBegin, .began, .changed, .ended, .cancelled, .stationary] {
                    event.eventPhase = phase
                    event.eventMagnification = 0
                    scroll.magnify(with: event)
                    XCTAssertEqual(probe.calls, ["start"])
                }
                event.eventMagnification = -0.1
                for phase: NSEvent.Phase in [.mayBegin, .ended, .cancelled, .stationary] {
                    event.eventPhase = phase
                    scroll.magnify(with: event)
                    XCTAssertEqual(probe.calls, ["start"])
                }
                event.eventPhase = movingPhase
                scroll.magnify(with: event)
                XCTAssertEqual(probe.calls, ["start", "stop"])
            }
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
        var enabledWrites: [Bool] = []
        override var isEnabled: Bool {
            get { super.isEnabled }
            set {
                enabledWrites.append(newValue)
                super.isEnabled = newValue
            }
        }
        func simulateNativeReset() { reset() }
        override var state: NSGestureRecognizer.State {
            get { injectedState }
            set { injectedState = newValue }
        }
        override func location(in view: NSView?) -> NSPoint {
            view == nil ? windowPoint : NSPoint(x: windowPoint.x / 5, y: windowPoint.y / 5)
        }
    }

    private final class HoldTouch: NSTouch, @unchecked Sendable {
        var point = NSPoint.zero
        var touchType = NSTouch.TouchType.direct
        var locationQueries = 0
        override var type: NSTouch.TouchType { touchType }
        override func location(in view: NSView?) -> NSPoint {
            locationQueries += 1
            return point
        }
    }

    private final class HoldMagnifyEvent: NSEvent {
        var eventPhase: NSEvent.Phase = .began
        var eventMagnification: CGFloat = -0.1
        override var phase: NSEvent.Phase { eventPhase }
        override var magnification: CGFloat { eventMagnification }
    }
#endif
