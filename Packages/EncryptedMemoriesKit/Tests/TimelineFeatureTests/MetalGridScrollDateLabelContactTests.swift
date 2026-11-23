import AppKit
import MetalKit
import PhotosCore
import SwiftUI
import Testing
import TimelineCore

@testable import TimelineFeature

/// A finger on the native knob of a Mac touch display (#777): the passive observer, the visible-knob check at
/// touch-down, the slide away from the finger and its return, and the contact's geometry. The tests call the
/// observer's contact methods that its touch-event decoding calls; AppKit has no public initializer for a direct
/// touch event, so the decoding itself stays a manual check on touch hardware.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalGridScrollDateLabelContactTests {
    typealias Fixture = MetalGridScrollDateLabelTests.Fixture

    private static let fallback = TimelineScrollDateLabelMotion.indicatorFallbackRadius
    private static let threshold = TimelineScrollDateLabelMotion.indicatorContactAlphaThreshold

    // MARK: - Touch-down

    @Test func aTouchOnTheVisibleKnobShowsAndOffsetsTheHiddenLabelWithoutMovement() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        #expect(!label.controller.presentation.isVisible, "SETUP: the label is hidden")
        let knob = try fixture.visibleKnob(of: label)
        let point = CGPoint(x: knob.midX, y: knob.midY)
        label.contactObserver.contactBegan(at: point)

        #expect(label.controller.presentation.isVisible, "a touch on the visible knob shows the label at once")
        #expect(label.controller.policy.isIndicatorDragging)
        let expected = TimelineScrollDateLabelGeometry.indicatorDragOffset(
            normalRightX: fixture.normalLabelRight(of: label), thumbLeftX: knob.minX, contactX: point.x,
            contactRadius: Self.fallback)
        #expect(expected > 0, "SETUP: the finger reaches into the label's place")
        #expect(abs(label.controller.policy.indicatorOffset - expected) < 0.000_1, "zero radius uses the fallback")
        #expect(abs(label.dragOffset - expected) < 0.000_1, "the label slides left of the finger")
        #expect(abs(label.view.frame.maxX - fixture.normalLabelRight(of: label)) <= 1, "the frame keeps its place")
        #expect(abs(label.view.frame.midY - knob.midY) <= 0.5, "beside the knob")
        #expect(label.contactObserver.state == .possible, "the observer never recognizes, so it cancels nothing")
        label.contactObserver.finishContact()
    }

    @Test func aZeroRadiusUsesTheSharedFallbackEnvelope() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: (knob.minY - Self.fallback).nextDown))
        #expect(!label.controller.policy.isIndicatorDragging, "just outside the fallback envelope")
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.minY - Self.fallback))
        #expect(label.controller.policy.isIndicatorDragging, "the fallback envelope's edge")
        label.contactObserver.finishContact()
    }

    @Test func liveXFollowsDirectlyAndKeepsTheOnsetSlide() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel(reduceMotion: false)
        try await fixture.flick()
        fixture.endLiveScroll()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        let onset = try #require(
            label.slideView.layer?.animation(forKey: "transform") as? CABasicAnimation, "a visible label slides out")
        #expect(onset.duration == TimelineScrollDateLabelMotion.indicatorSlideOut && onset.isAdditive)
        let frame = label.view.frame
        for x in [knob.midX - 6, knob.midX - 12, knob.midX - 3] {
            label.contactObserver.contactMoved(at: CGPoint(x: x, y: knob.midY))
            let expected = TimelineScrollDateLabelGeometry.indicatorDragOffset(
                normalRightX: fixture.normalLabelRight(of: label), thumbLeftX: knob.minX, contactX: x,
                contactRadius: Self.fallback)
            #expect(abs(label.dragOffset - expected) < 0.000_1, "follows the finger at \(x)")
            #expect(label.controller.presentation.slideDuration == nil, "position changes track directly")
            #expect(
                label.slideView.layer?.animation(forKey: "transform")?.beginTime == onset.beginTime,
                "a live position keeps the running onset")
            #expect(label.view.frame == frame, "the vertical layout stays independent of the slide")
        }
        label.contactObserver.finishContact()
    }

    // MARK: - Return

    @Test func releaseCancelAndResetReturnTheLabelWithTheSharedSlide() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel(reduceMotion: false)
        try await fixture.flick()
        fixture.endLiveScroll()
        let observer = label.contactObserver
        let ends: [(String, () -> Void)] = [
            ("release or cancel", { observer.finishContact() }),
            ("reset", { observer.reset() }),
        ]
        for (name, end) in ends {
            let knob = try fixture.visibleKnob(of: label)
            observer.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
            #expect(label.dragOffset > 0, "SETUP: \(name) starts from a slide")
            end()
            #expect(!label.controller.policy.isIndicatorDragging, "\(name) ends the contact")
            #expect(label.dragOffset == 0, "\(name) returns the label")
            let slide = try #require(label.slideView.layer?.animation(forKey: "transform") as? CABasicAnimation)
            #expect(slide.duration == TimelineScrollDateLabelMotion.indicatorSlideBack, "\(name) eases back")
            #expect(label.controller.policy.hideDeadline != nil, "\(name) starts the usual linger")
            #expect(!observer.isHoldingContact)
        }
    }

    @Test func retirementEndsTheContactAndStopsObserving() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        #expect(label.controller.policy.isIndicatorDragging, "SETUP: held")
        fixture.host.retireScrollDateLabel()
        #expect(!label.contactObserver.isEnabled)
        #expect(!label.contactObserver.isHoldingContact)
        #expect(!label.controller.policy.isIndicatorDragging)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        #expect(!label.contactObserver.isHoldingContact, "a retired observer takes no contact")
    }

    @Test func reduceMotionSlidesAndReturnsAtOnce() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel(reduceMotion: true)
        try await fixture.flick()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        #expect(label.dragOffset > 0)
        #expect(label.slideView.layer?.animation(forKey: "transform") == nil, "no slide animation")
        label.contactObserver.finishContact()
        #expect(label.dragOffset == 0)
        #expect(label.slideView.layer?.animation(forKey: "transform") == nil, "no return animation")
    }

    // MARK: - Visibility at touch-down

    @Test func onlyAVisibleKnobAcceptsATouch() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        let point = CGPoint(x: knob.midX, y: knob.midY)
        let knobLayer = try #require(fixture.scrollView.verticalScroller?.knobLayer)
        for (opacity, accepted) in [(Float(0), false), (Self.threshold, false), (Self.threshold.nextUp, true)] {
            label.controller.hide()
            try fixture.setKnobOpacity(opacity)
            label.contactObserver.contactBegan(at: point)
            #expect(label.controller.policy.isIndicatorDragging == accepted, "knob opacity \(opacity)")
            label.contactObserver.finishContact()
        }
        try fixture.setKnobOpacity(1)
        fixture.scrollView.alphaValue = 0.005
        label.contactObserver.contactBegan(at: point)
        #expect(!label.controller.policy.isIndicatorDragging, "an ancestor's alpha multiplies the knob's")
        fixture.scrollView.alphaValue = 1
        fixture.scrollView.isHidden = true
        label.contactObserver.contactBegan(at: point)
        #expect(!label.controller.policy.isIndicatorDragging, "a hidden ancestor hides the knob")
        fixture.scrollView.isHidden = false
        try fixture.setKnobOpacity(1)  // AppKit fades the knob again when its scroll view reappears.
        label.contactObserver.contactBegan(at: point)
        #expect(label.controller.policy.isIndicatorDragging, "SETUP: the visible knob accepts again")
        #expect(knobLayer.superlayer != nil, "the same knob layer")
        label.contactObserver.finishContact()
    }

    @Test func aKnobLayerThatCannotBeIdentifiedFailsClosed() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        let point = CGPoint(x: knob.midX, y: knob.midY)
        let scroller = try #require(fixture.scrollView.verticalScroller)
        let knobLayer = try #require(scroller.knobLayer)
        #expect(scroller.renderedKnobOpacity > Self.threshold, "SETUP: the identified knob is visible")

        // A second layer with the knob's frame: the knob is ambiguous.
        let twin = CALayer()
        twin.frame = knobLayer.frame
        knobLayer.superlayer?.addSublayer(twin)
        #expect(scroller.knobLayer == nil)
        label.contactObserver.contactBegan(at: point)
        #expect(!label.controller.policy.isIndicatorDragging, "an ambiguous knob takes no contact")
        twin.removeFromSuperlayer()

        // No layer with the knob's frame.
        let frame = knobLayer.frame
        knobLayer.frame = frame.offsetBy(dx: 0, dy: 1)
        #expect(scroller.knobLayer == nil)
        label.contactObserver.contactBegan(at: point)
        #expect(!label.controller.policy.isIndicatorDragging, "an unknown knob layout takes no contact")
        knobLayer.frame = frame
        #expect(scroller.knobLayer === knobLayer)
    }

    @Test func aMissingKnobTakesNoContactAndEndsAHold() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        let point = CGPoint(x: knob.midX, y: knob.midY)
        label.contactObserver.contactBegan(at: point)
        #expect(label.controller.policy.isIndicatorDragging, "SETUP: held")
        fixture.scrollView.hasVerticalScroller = false
        fixture.layoutHost()
        #expect(label.contactObserver.thumbRect == nil)
        #expect(!label.controller.policy.isIndicatorDragging, "the knob left: the hold ends")
        label.contactObserver.contactBegan(at: point)
        #expect(!label.controller.policy.isIndicatorDragging, "no knob, no contact")
    }

    @Test func thePresentedKnobOpacityDecidesNotTheModelValue() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        let point = CGPoint(x: knob.midX, y: knob.midY)
        let knobLayer = try #require(fixture.scrollView.verticalScroller?.knobLayer)
        // Core Animation keeps a presentation layer only for a window on screen.
        fixture.window.orderFrontRegardless()
        defer { fixture.window.orderOut(nil) }
        for (model, presented, accepted) in [(Float(0), Float(0.5), true), (1, 0, false)] {
            label.controller.hide()
            try fixture.setKnobOpacity(model)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = presented
            animation.toValue = presented
            animation.duration = 100
            animation.isRemovedOnCompletion = false
            knobLayer.add(animation, forKey: "test-opacity")
            CATransaction.flush()
            // Wait only for the render transaction, not for a time-sensitive animation phase.
            for _ in 0..<200 where knobLayer.presentation()?.opacity != presented {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(knobLayer.presentation()?.opacity == presented, "SETUP: the presentation runs")
            #expect(knobLayer.opacity == model)
            label.contactObserver.contactBegan(at: point)
            #expect(label.controller.policy.isIndicatorDragging == accepted, "presented \(presented), model \(model)")
            label.contactObserver.finishContact()
            knobLayer.removeAnimation(forKey: "test-opacity")
        }
    }

    @Test func anAcceptedHoldSurvivesTheKnobFading() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        try fixture.setKnobOpacity(0)
        let moved = try fixture.dragKnob(of: label, by: 40, fingerFirst: true)
        #expect(label.controller.policy.isIndicatorDragging, "the knob faded, the finger still holds it")
        #expect(label.contactObserver.isHoldingContact)
        #expect(moved > 0)
        label.contactObserver.finishContact()
    }

    // MARK: - Contact geometry

    @Test(arguments: [true, false])
    func aHeldContactFollowsTheKnobInEitherCallbackOrder(fingerFirst: Bool) async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        var travelled: CGFloat = 0
        for _ in 0..<4 {
            travelled += try fixture.dragKnob(of: label, by: 60, fingerFirst: fingerFirst)
            #expect(label.contactObserver.isHoldingContact, "finger first: \(fingerFirst)")
        }
        #expect(travelled > 60, "SETUP: the knob travelled")
        #expect(label.controller.policy.isIndicatorDragging)
        #expect(label.controller.policy.indicatorOffset > 0, "SETUP: the finger holds the label aside")
        #expect(
            abs(label.dragOffset - label.controller.policy.indicatorOffset) < 0.000_1,
            "the vertical relayout beside the moving knob keeps the slide")
        let knobNow = try #require(label.contactObserver.thumbRect)
        #expect(abs(label.view.frame.midY - knobNow.midY) <= 0.5, "the label still follows the knob vertically")
        let snapshot = try #require(label.contactObserver.thumbRect)
        let independent = try #require(fixture.knobRectInOverlay(of: label))
        #expect(snapshot == independent, "the observer and the label share the knob in overlay coordinates")
        label.contactObserver.finishContact()
    }

    @Test func anOrdinaryPanLeavesTheKnobEndsTheContactAndNeverBindsAgain() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        var forwarded = 0
        let forward = label.contactObserver.onContact
        label.contactObserver.onContact = { point, began in
            forwarded += 1
            return forward?(point, began) ?? false
        }
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: knob.midY + 100))
        #expect(label.contactObserver.isHoldingContact, "one sample may precede the knob")
        label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: knob.midY + 110))
        #expect(!label.contactObserver.isHoldingContact, "the knob did not follow: an ordinary pan")
        #expect(!label.controller.policy.isIndicatorDragging)
        #expect(label.dragOffset == 0)
        let count = forwarded
        label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: knob.midY))
        #expect(forwarded == count, "the same touch never binds again")
        #expect(!label.controller.policy.isIndicatorDragging)
    }

    @Test func bothClampedTrackEndsKeepTheHoldAndTheReturn() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        for (name, y, beyond) in [("top", CGFloat(0), CGFloat(-200)), ("bottom", fixture.maxScrollY, 2_000)] {
            fixture.scrollClip(toY: y)
            #expect(
                name == "top"
                    ? fixture.scrollView.clampedVerticalEnds.top : fixture.scrollView.clampedVerticalEnds.bottom,
                "SETUP: at the \(name) end")
            let knob = try fixture.visibleKnob(of: label)
            label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
            label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: beyond))
            label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: beyond * 1.5))
            fixture.scrollClip(toY: y)  // The clamped knob does not move.
            #expect(label.contactObserver.isHoldingContact, "beyond the \(name) end")
            label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: knob.midY))
            #expect(label.contactObserver.isHoldingContact, "the finger returns from beyond the \(name) end")
            #expect(label.controller.policy.isIndicatorDragging)
            label.contactObserver.finishContact()
            #expect(label.dragOffset == 0, "release at the \(name) end returns the label")

            // The opposite side stays closed.
            label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
            let opposite: CGFloat = name == "top" ? 2_000 : -200
            label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: opposite))
            label.contactObserver.contactMoved(at: CGPoint(x: knob.midX, y: opposite * 1.5))
            #expect(!label.contactObserver.isHoldingContact, "the side opposite the \(name) end stays closed")
        }
    }

    @Test func endpointsWithinHalfADevicePixelCountAsClamped() throws {
        _ = NSApplication.shared
        let window = VisibilityWindow()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1_300.25))
        scrollView.documentView = document
        window.contentView = scrollView
        defer { window.contentView = nil }
        let scale = window.backingScaleFactor
        let pixel = 1 / scale
        let end = document.frame.height - scrollView.contentView.bounds.height
        #expect(end.truncatingRemainder(dividingBy: 1) == 0.25, "SETUP: a fractional bottom end")
        for (offset, bottom) in [
            (end, true), (end - pixel / 4, true), (end - pixel / 2, true), ((end - pixel / 2).nextDown, false),
        ] {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
            #expect(scrollView.contentView.bounds.origin.y == offset, "SETUP: the clip sits exactly at \(offset)")
            #expect(scrollView.clampedVerticalEnds.bottom == bottom, "\(end - offset) points from the end")
            #expect(!scrollView.clampedVerticalEnds.top)
        }
        for (offset, top) in [(pixel / 4, true), (pixel / 2, true), ((pixel / 2).nextUp, false)] {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
            #expect(scrollView.contentView.bounds.origin.y == offset, "SETUP: the clip sits exactly at \(offset)")
            #expect(scrollView.clampedVerticalEnds.top == top, "\(offset) points from the top")
        }
    }

    @Test func anUnflippedDocumentStartsAtTheBottomEnd() throws {
        _ = NSApplication.shared
        let window = VisibilityWindow()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_300))
        scrollView.documentView = document
        window.contentView = scrollView
        defer { window.contentView = nil }
        scrollView.contentView.setBoundsOrigin(.zero)
        #expect(scrollView.clampedVerticalEnds == (top: false, bottom: true), "origin zero is the content's bottom")
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1_000))
        #expect(scrollView.clampedVerticalEnds == (top: true, bottom: false), "the far origin is the content's top")
    }

    // MARK: - Pointer and trackpad

    @Test func theObserverIsPassiveAndDirectTouchOnly() throws {
        let fixture = try Fixture()
        let observer = fixture.label.contactObserver
        #expect(observer.view === fixture.host, "it watches the host and the scroller inside it")
        #expect(observer.allowedTouchTypes == .direct, "indirect trackpad touches never reach it")
        #expect(!observer.delaysPrimaryMouseButtonEvents && !observer.delaysSecondaryMouseButtonEvents)
        #expect(!observer.delaysOtherMouseButtonEvents && !observer.delaysKeyEvents)
        #expect(!observer.delaysMagnificationEvents && !observer.delaysRotationEvents)
        if #available(macOS 27, *) {
            #expect(!observer.isCancellableByScrollGesture, "a scroll gesture never ends a held knob")
        }
        let other = NSGestureRecognizer(target: nil, action: nil)
        #expect(!observer.canPrevent(other) && !observer.canBePrevented(by: other))
    }

    @Test func pointerAndTrackpadInputNeverEnterContactMode() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        let observer = label.contactObserver
        let inWindow = label.overlay.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
        // The window hands mouse events to a gesture recognizer through these handlers. The test calls them directly:
        // a real mouse-down on the knob would start the scroller's own tracking loop. Today the observer keeps the
        // base handlers, so this guards against a future mouse handler that starts a contact.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                    windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
            switch type {
            case .leftMouseDown: observer.mouseDown(with: event)
            case .leftMouseDragged: observer.mouseDragged(with: event)
            default: observer.mouseUp(with: event)
            }
            #expect(!observer.isHoldingContact, "a mouse \(type) on the knob is not a finger")
            #expect(!label.controller.policy.isIndicatorDragging)
        }
        // A trackpad scroll over the visible knob is the ordinary label path.
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: a brisk trackpad scroll shows the label")
        #expect(!label.controller.policy.isIndicatorDragging, "a trackpad scroll is not a knob contact")
        #expect(label.dragOffset == 0)
    }

    /// A window resize while a finger holds the knob resizes the slide container. AppKit then resets the container's
    /// layer transform, so the container sets the slide again and the label stays left of the finger.
    @Test func aWindowResizeKeepsTheSlideOfAHeldContact() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        let held = label.controller.presentation.indicatorOffset
        #expect(held > 0, "SETUP: the label slides left of the finger")
        #expect(abs(label.dragOffset - held) < 0.000_1, "SETUP: the slide is applied")
        let before = label.slideView.frame.size
        // A few points of width: the grid keeps its columns, so the knob stays under the finger. A larger resize
        // reflows the grid, moves the knob away from the finger and ends the hold.
        fixture.window.setContentSize(NSSize(width: before.width + 4, height: before.height))
        fixture.layoutHost()
        #expect(label.slideView.frame.width == before.width + 4, "SETUP: the container follows the overlay's width")
        #expect(label.contactObserver.thumbRect?.minY == knob.minY, "SETUP: the knob keeps its place")
        #expect(label.controller.policy.isIndicatorDragging, "SETUP: the finger still holds the knob")
        #expect(
            abs(label.dragOffset - label.controller.presentation.indicatorOffset) < 0.000_1,
            "the resize keeps the slide: \(label.dragOffset) for \(label.controller.presentation.indicatorOffset)")
        #expect(label.dragOffset > 0)
        label.contactObserver.finishContact()
    }

    /// AppKit reports one knob move several times: on the reflect, in the tile pass and in the host's layout. When the
    /// knob moves before the finger sample arrives, a repeated report of the same knob keeps the hold.
    @Test func aRepeatedKnobReportKeepsAHoldWhileTheFingerCatchesUp() async throws {
        let fixture = try Fixture()
        let label = try await fixture.enabledLabel()
        let knob = try fixture.visibleKnob(of: label)
        label.contactObserver.contactBegan(at: CGPoint(x: knob.midX, y: knob.midY))
        #expect(label.contactObserver.isHoldingContact, "SETUP: the finger holds the knob")
        let travel = knob.height + Self.fallback * 2 + 4
        let track = label.overlay.bounds.height - knob.height
        fixture.scrollClip(toY: fixture.clipView.bounds.origin.y + travel / max(track, 1) * fixture.maxScrollY)
        let moved = try #require(label.contactObserver.thumbRect)
        #expect(moved.minY > knob.maxY + Self.fallback, "SETUP: the knob moved away from the finger")
        #expect(label.contactObserver.isHoldingContact, "SETUP: the previous knob still aligns with the finger")
        label.scrollersReflected()
        fixture.layoutHost()
        #expect(label.contactObserver.isHoldingContact, "a repeated report of the same knob keeps the hold")
        label.contactObserver.contactMoved(at: CGPoint(x: moved.midX, y: moved.midY))
        #expect(label.contactObserver.isHoldingContact, "the finger catches up with the knob")
        label.contactObserver.finishContact()
    }

    // MARK: - Date scrubber

    @Test func theScrubberReservesItsDormantColumnItsExpandedColumnOrItsPill() {
        let dormant = TimelineDateScrubber.dormantWidth + TimelineDateScrubber.trailingMargin
        let expanded = TimelineDateScrubber.expandedWidth + TimelineDateScrubber.trailingMargin
        #expect(TimelineDateScrubber.trailingReservation(isExpanded: false, pillWidth: nil) == dormant)
        #expect(TimelineDateScrubber.trailingReservation(isExpanded: false, pillWidth: 200) == dormant)
        #expect(TimelineDateScrubber.trailingReservation(isExpanded: true, pillWidth: nil) == expanded)
        #expect(TimelineDateScrubber.trailingReservation(isExpanded: true, pillWidth: 60) == expanded)
        let wide: CGFloat = 130
        #expect(
            TimelineDateScrubber.trailingReservation(isExpanded: true, pillWidth: wide)
                == TimelineDateScrubber.trailingMargin + TimelineDateScrubber.pillCenterInset + wide / 2)
    }

    /// Every month's actual pill, in English and German, at the narrowest window with the widest sidebar: the label
    /// stays clear of the expanded scrubber and its pill, and inside the grid.
    @Test(arguments: ["en_US", "de_AT"])
    func theLabelNeverOverlapsTheExpandedScrubberOrItsPill(localeID: String) async throws {
        let fixture = try Fixture()
        fixture.window.setContentSize(NSSize(width: 720, height: 600))  // The app's minimum window width.
        fixture.layoutHost()
        let label = try await fixture.enabledLabel()
        try await fixture.flick()
        #expect(label.controller.presentation.isVisible, "SETUP: the label shows")
        let locale = Locale(identifier: localeID)
        let width = label.overlay.bounds.width
        #expect(width == 720, "SETUP: the narrowest grid")
        let wideMonths = fixture.monthTexts(style: .wide, locale: locale)
        let pillMonths = fixture.monthTexts(style: .abbreviated, locale: locale)
        #expect(wideMonths.count == 12 && pillMonths.count == 12, "SETUP: twelve months")
        for (pillText, labelText) in zip(pillMonths, wideMonths) {
            let pillWidth = Self.pillWidth(pillText)
            let reservation = TimelineDateScrubber.trailingReservation(isExpanded: true, pillWidth: pillWidth)
            let pillMinX =
                width - TimelineDateScrubber.trailingMargin - TimelineDateScrubber.pillCenterInset
                - pillWidth / 2
            let columnMinX = width - TimelineDateScrubber.trailingMargin - TimelineDateScrubber.expandedWidth
            label.setTrailingInset(reservation)
            label.view.setText(labelText)
            label.layout()
            let frame = label.view.frame
            #expect(frame.maxX <= pillMinX - TimelineScrollDateLabelMotion.indicatorGap + 1, "clear of \(pillText)")
            #expect(frame.maxX <= columnMinX, "clear of the expanded column with \(pillText)")
            #expect(frame.minX >= SidebarMetrics.maxWidth, "\(labelText) stays right of the widest sidebar")
            #expect(frame.width >= label.view.labelSize.width - 1, "\(labelText) keeps its full width")
        }
    }

    /// The scrubber keeps the pointer routing it had: the native knob strip right of the scrubber and the track above
    /// and below it reach the grid, the scrubber's column reaches the scrubber. The label adds no hit target.
    @Test func theScrubberAndTheKnobKeepTheirPointerRouting() throws {
        _ = NSApplication.shared
        let grid = RoutingProbeView()
        let markers = (0..<3).map {
            TimelineDateMarker(index: $0, date: Date(timeIntervalSince1970: 0), text: "M\($0)", granularity: .month)
        }
        let root = ZStack(alignment: .trailing) {
            RoutingProbeRepresentable(view: grid)
            TimelineDateScrubber(markers: markers) { _ in }
        }
        let hosting = NSHostingView(rootView: root)
        let window = VisibilityWindow()
        window.setContentSize(NSSize(width: 600, height: 500))
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        hosting.layoutSubtreeIfNeeded()
        func hit(fromTrailing x: CGFloat, fromTop y: CGFloat) -> NSView? {
            hosting.hitTest(NSPoint(x: 600 - x, y: hosting.isFlipped ? y : 500 - y))
        }
        #expect(hit(fromTrailing: 4, fromTop: 250) === grid, "the knob strip right of the scrubber reaches the grid")
        #expect(hit(fromTrailing: 4, fromTop: 40) === grid, "the knob above the scrubber reaches the grid")
        #expect(hit(fromTrailing: 20, fromTop: 250) !== grid, "the scrubber's column belongs to the scrubber")
        #expect(hit(fromTrailing: 300, fromTop: 250) === grid, "the photos reach the grid")
    }

    /// The hosted scrubber reports the trailing width it covers as soon as it appears.
    @Test func theHostedScrubberReportsItsReservationWhenItAppears() async throws {
        _ = NSApplication.shared
        final class Reports { var values: [CGFloat] = [] }
        let reports = Reports()
        let markers = (0..<3).map {
            TimelineDateMarker(index: $0, date: Date(timeIntervalSince1970: 0), text: "M\($0)", granularity: .month)
        }
        let scrubber = TimelineDateScrubber(
            markers: markers, onTrailingReservationChange: { reports.values.append($0) }, onJump: { _ in })
        let hosting = NSHostingView(rootView: scrubber)
        let window = VisibilityWindow()
        window.setContentSize(NSSize(width: 600, height: 500))
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let deadline = ContinuousClock.now + .seconds(2)
        while reports.values.isEmpty, ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reports.values == [TimelineDateScrubber.dormantTrailingReservation])
    }

    private static func pillWidth(_ text: String) -> CGFloat {
        let hosting = NSHostingView(rootView: TimelineDateScrubberPill(text: text))
        return hosting.fittingSize.width
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class RoutingProbeView: NSView {}

private struct RoutingProbeRepresentable: NSViewRepresentable {
    let view: RoutingProbeView
    func makeNSView(context: Context) -> RoutingProbeView { view }
    func updateNSView(_ nsView: RoutingProbeView, context: Context) {}
}

extension MetalGridScrollDateLabelTests.Fixture {
    /// The knob in overlay coordinates after making its layer visible, as a scroll or a flash does.
    func visibleKnob(of label: MetalGridScrollDateLabelPresenter) throws -> CGRect {
        label.scrollersReflected()
        try setKnobOpacity(1)
        return try #require(label.contactObserver.thumbRect, "SETUP: the scroller has a knob")
    }

    func setKnobOpacity(_ opacity: Float) throws {
        guard let layer = scrollView.verticalScroller?.knobLayer else {
            Issue.record("SETUP: the scroller has no knob layer")
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }

    func normalLabelRight(of label: MetalGridScrollDateLabelPresenter) -> CGFloat {
        label.overlay.bounds.width - label.trailingInset - TimelineScrollDateLabelMotion.indicatorGap
    }

    /// Moves the finger and the knob together by about `points` of knob travel, in either order. Returns the knob's
    /// actual travel.
    func dragKnob(
        of label: MetalGridScrollDateLabelPresenter, by points: CGFloat, fingerFirst: Bool
    ) throws -> CGFloat {
        let before = try #require(label.contactObserver.thumbRect)
        let track = label.overlay.bounds.height - before.height
        let content = points / max(track, 1) * maxScrollY
        // Predict the knob's travel from the scroller's own proportion, then move the finger by it.
        let targetY = min(max(0, clipView.bounds.origin.y + content), maxScrollY)
        if fingerFirst {
            let predicted = (targetY - clipView.bounds.origin.y) / max(maxScrollY, 1) * track
            label.contactObserver.contactMoved(at: CGPoint(x: before.midX, y: before.midY + predicted))
            scrollClip(toY: targetY)
            label.contactObserver.contactMoved(
                at: CGPoint(x: before.midX, y: (label.contactObserver.thumbRect ?? before).midY))
        } else {
            scrollClip(toY: targetY)
            label.contactObserver.contactMoved(
                at: CGPoint(x: before.midX, y: (label.contactObserver.thumbRect ?? before).midY))
        }
        return (label.contactObserver.thumbRect?.midY ?? before.midY) - before.midY
    }

    func monthTexts(style: TimelineDateMarker.MonthStyle, locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let months = (1...12).map { month in
            PhotoItem(
                uid: PhotoUID(volumeID: "months", nodeID: "\(month)"),
                captureTime: calendar.date(from: DateComponents(year: 2025, month: month, day: 3))!,
                mediaType: "image/jpeg")
        }
        return TimelineDateMarkers.markers(
            items: months, granularity: .month, monthStyle: style, calendar: calendar, locale: locale
        ).map(\.text)
    }
}
