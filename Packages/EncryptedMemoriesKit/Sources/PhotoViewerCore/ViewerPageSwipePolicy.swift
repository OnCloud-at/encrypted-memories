import CoreGraphics

/// Portable page direction for viewer navigation. Native adapters translate platform events into this value;
/// the existing viewer model remains the only owner of page and burst selection.
public enum ViewerPageSwipeDirection: Equatable, Sendable {
    case previous
    case next
}

/// Platform-neutral phases used by native pointer and trackpad adapters.
public enum ViewerPageSwipePhase: Equatable, Sendable {
    case mayBegin
    case began
    case changed
    case ended
    case cancelled
}

/// The result of one native gesture event.
public struct ViewerPageSwipeUpdate: Equatable, Sendable {
    /// True while the tracker owns a page gesture. Native adapters then stop forwarding the event to a media
    /// surface that has no horizontal work at fit scale.
    public let consumesEvent: Bool
    /// Non-nil only once, when a completed gesture crosses the page threshold.
    public let direction: ViewerPageSwipeDirection?

    public init(consumesEvent: Bool, direction: ViewerPageSwipeDirection?) {
        self.consumesEvent = consumesEvent
        self.direction = direction
    }
}

/// Shared state machine for a two-finger horizontal page gesture.
///
/// AppKit can expose the same physical gesture either as fluid swipe tracking or as precise scroll events,
/// depending on the user's system preference. The viewer must work in both configurations, so native adapters
/// feed precise deltas into this bounded state machine instead of relying on that preference.
public struct ViewerPageSwipeTracker: Sendable {
    public static let commitDistance: CGFloat = 48

    private enum Axis: Sendable {
        case undetermined
        case horizontal
        case rejected
    }

    private var axis: Axis = .undetermined
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var active = false

    public init() {}

    /// Converts AppKit's preference-adjusted scroll delta back to the device-relative direction used by swipe
    /// gestures. A positive horizontal value means a physical swipe to the left and therefore the next page.
    public static func deviceRelativeDelta(_ reportedDelta: CGFloat, directionWasInverted: Bool) -> CGFloat {
        directionWasInverted ? -reportedDelta : reportedDelta
    }

    public mutating func consume(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: ViewerPageSwipePhase
    ) -> ViewerPageSwipeUpdate {
        guard deltaX.isFinite, deltaY.isFinite else {
            reset()
            return ViewerPageSwipeUpdate(consumesEvent: false, direction: nil)
        }

        switch phase {
        case .mayBegin:
            reset()
            active = true
            return ViewerPageSwipeUpdate(consumesEvent: true, direction: nil)

        case .began:
            reset()
            active = true
            accumulate(deltaX: deltaX, deltaY: deltaY)
            resolveAxisIfPossible()
            return ViewerPageSwipeUpdate(consumesEvent: axis != .rejected, direction: nil)

        case .changed:
            if !active { active = true }
            accumulate(deltaX: deltaX, deltaY: deltaY)
            resolveAxisIfPossible()
            return ViewerPageSwipeUpdate(consumesEvent: axis != .rejected, direction: nil)

        case .ended:
            guard active else {
                reset()
                return ViewerPageSwipeUpdate(consumesEvent: false, direction: nil)
            }
            accumulate(deltaX: deltaX, deltaY: deltaY)
            resolveAxisIfPossible(force: true)
            let consumed = axis == .horizontal
            let direction = completedDirection()
            reset()
            return ViewerPageSwipeUpdate(consumesEvent: consumed, direction: direction)

        case .cancelled:
            let consumed = axis == .horizontal
            reset()
            return ViewerPageSwipeUpdate(consumesEvent: consumed, direction: nil)
        }
    }

    private mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat) {
        accumulatedX += deltaX
        accumulatedY += deltaY
    }

    private mutating func resolveAxisIfPossible(force: Bool = false) {
        guard axis == .undetermined else { return }
        let horizontal = abs(accumulatedX)
        let vertical = abs(accumulatedY)
        guard force || max(horizontal, vertical) >= 3 else { return }
        axis = horizontal > vertical * 1.2 ? .horizontal : .rejected
    }

    private func completedDirection() -> ViewerPageSwipeDirection? {
        guard axis == .horizontal, abs(accumulatedX) >= Self.commitDistance else { return nil }
        return accumulatedX > 0 ? .next : .previous
    }

    private mutating func reset() {
        axis = .undetermined
        accumulatedX = 0
        accumulatedY = 0
        active = false
    }
}
