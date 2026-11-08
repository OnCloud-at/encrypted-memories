import AppKit
import PhotoViewerCore
import XCTest

@testable import PhotoViewerFeature

/// Drives the real `ZoomScrollView.scrollWheel(with:)` with synthetic trackpad events (precise deltas with scroll
/// phases), so the wiring between the AppKit view and the shared page swipe policy runs for real.
@MainActor
final class ZoomScrollViewScrollWheelTests: XCTestCase {
    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    private func makeView() -> (ZoomScrollView, SwipeLog) {
        let log = SwipeLog()
        let view = ZoomScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.allowsMagnification = true
        view.minMagnification = 1
        view.maxMagnification = 10
        view.onPageSwipe = { log.directions.append($0) }
        let imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        imageView.image = NSImage(size: NSSize(width: 400, height: 300))
        view.documentView = imageView
        return (view, log)
    }

    private func event(deltaX: Int32, deltaY: Int32 = 0, phase: Phase, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// The direction that the policy must report for a rightward trackpad movement, whatever the system scroll setting.
    private func expectedDirection(for event: NSEvent) -> ViewerPageSwipeDirection {
        event.isDirectionInvertedFromDevice ? .previous : .next
    }

    private func swipe(_ view: ZoomScrollView) throws -> ViewerPageSwipeDirection {
        let begin = try event(deltaX: 0, phase: .began)
        view.scrollWheel(with: begin)
        view.scrollWheel(with: try event(deltaX: 30, deltaY: 2, phase: .changed))
        view.scrollWheel(with: try event(deltaX: 22, deltaY: 1, phase: .ended))
        return expectedDirection(for: begin)
    }

    func testHoldIgnoresNonmovingScrollPhasesAndStopsOnMovement() throws {
        for phase: Phase in [.mayBegin, .began, .changed, .ended, .cancelled] {
            let (view, _) = makeView()
            let press = AppKitLivePhotoHoldAdapter()
            view.motionHold = press
            var calls: [String] = []
            press.onStart = { calls.append("start") }
            press.onStop = { calls.append("stop") }
            press.consume(.began, at: .zero)
            view.scrollWheel(with: try event(deltaX: 0, phase: phase))
            XCTAssertEqual(calls, ["start"], "Zero delta at \(phase)")
            if phase == .mayBegin || phase == .ended || phase == .cancelled {
                view.scrollWheel(with: try event(deltaX: 10, phase: phase))
                XCTAssertEqual(calls, ["start"], "No moving phase at \(phase)")
            }
            view.scrollWheel(with: try event(deltaX: 10, phase: .changed))
            XCTAssertEqual(calls, ["start", "stop"])
        }
    }

    func testHoldStopsForBothMovementAxesAndMovingMomentumOnly() throws {
        // CGMomentumScrollPhase uses begin=1, continue=2, end=3, unlike CGScrollPhase.ended=4.
        for momentum: Int64 in [0, 1, 2] {
            for horizontal in [false, true] {
                let (view, _) = makeView()
                let press = AppKitLivePhotoHoldAdapter()
                view.motionHold = press
                var calls: [String] = []
                press.onStart = { calls.append("start") }
                press.onStop = { calls.append("stop") }
                press.consume(.began, at: .zero)
                view.scrollWheel(with: try event(deltaX: 0, phase: .began, momentum: momentum))
                XCTAssertEqual(calls, ["start"])
                view.scrollWheel(
                    with: try event(
                        deltaX: horizontal ? 10 : 0, deltaY: horizontal ? 0 : 10, phase: .began, momentum: momentum))
                XCTAssertEqual(calls, ["start", "stop"])
            }
        }
        let (view, _) = makeView()
        let press = AppKitLivePhotoHoldAdapter()
        view.motionHold = press
        var calls: [String] = []
        press.onStart = { calls.append("start") }
        press.onStop = { calls.append("stop") }
        press.consume(.began, at: .zero)
        view.scrollWheel(with: try event(deltaX: 10, phase: .changed, momentum: 3))
        XCTAssertEqual(calls, ["start"])
    }

    func testACompletedTrackpadSwipeAtFitScaleReportsOnePageSwipe() throws {
        let (view, log) = makeView()

        let expected = try swipe(view)

        XCTAssertEqual(log.directions, [expected])
    }

    func testAShortSwipeAtFitScaleReportsNoPageSwipe() throws {
        let (view, log) = makeView()

        view.scrollWheel(with: try event(deltaX: 0, phase: .began))
        view.scrollWheel(with: try event(deltaX: 4, phase: .changed))
        view.scrollWheel(with: try event(deltaX: 2, phase: .ended))

        XCTAssertEqual(log.directions, [])
    }

    func testAZoomedImageKeepsTheScrollForPanningAndReportsNoPageSwipe() throws {
        let (view, log) = makeView()
        view.magnification = 3
        XCTAssertGreaterThan(view.magnification, view.minMagnification + 0.001)

        _ = try swipe(view)

        XCTAssertEqual(log.directions, [])
    }
}

@MainActor
private final class SwipeLog {
    var directions: [ViewerPageSwipeDirection] = []
}
