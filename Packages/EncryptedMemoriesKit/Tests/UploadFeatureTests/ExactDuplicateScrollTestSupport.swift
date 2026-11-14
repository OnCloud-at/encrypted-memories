#if os(macOS)
    import AppKit
    import XCTest

    /// Continuous pixel scroll events for the native Duplicates tests.
    @MainActor
    enum ExactDuplicateScrollTestSupport {
        /// The phase field of a CGEvent takes Core Graphics values. AppKit numbers its phases differently:
        /// its changed value reads as ended there, and its ended value reads as cancelled.
        static let phases: [CGScrollPhase] = [.began, .changed, .changed, .changed, .changed, .ended]

        static func event(deltaX: Int32, deltaY: Int32, phase: CGScrollPhase) throws -> NSEvent {
            let event = try XCTUnwrap(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: deltaY, wheel2: deltaX, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
    }
#endif
