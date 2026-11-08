import Foundation

/// One viewport movement as a scroll host observed it.
public struct TimelineScrollDateLabelMovement: Equatable, Sendable {
    /// The host moved the viewport itself: a jump, restore, placement or its own animated scroll.
    public var isHostDriven: Bool
    /// The movement came from layout: a resize, an inset or content-size change.
    public var isLayout: Bool
    /// A finger touches or drags the scroll view.
    public var isTracking: Bool
    public var isDragging: Bool
    /// The viewport coasts after a flick.
    public var isDecelerating: Bool
    /// The system animates the offset for the person, for example after a keyboard page key.
    public var isSystemAnimation: Bool

    public init(
        isHostDriven: Bool = false, isLayout: Bool = false, isTracking: Bool = false, isDragging: Bool = false,
        isDecelerating: Bool = false, isSystemAnimation: Bool = false
    ) {
        self.isHostDriven = isHostDriven
        self.isLayout = isLayout
        self.isTracking = isTracking
        self.isDragging = isDragging
        self.isDecelerating = isDecelerating
        self.isSystemAnimation = isSystemAnimation
    }
}

extension TimelineScrollDateLabelMovement {
    /// Builds the movement from what a scroll host can observe.
    ///
    /// - `isApplyingProgrammaticScroll`: the host sets the offset right now.
    /// - `hostAnimationActive`: the host started an animated scroll (tab retap, placement).
    /// - `systemJumpActive`: the system scrolls to the top after a status-bar tap.
    /// - `isScrollAnimating`: the scroll view animates an offset change.
    ///
    /// Both jump flags count only while the scroll view still animates. A touch that interrupts the animation ends it
    /// without any callback, so a stale flag must not turn the person's next flick into a jump. Every other offset
    /// animation counts as the person's input, for example a keyboard page key.
    public static func observed(
        isApplyingProgrammaticScroll: Bool, hostAnimationActive: Bool, systemJumpActive: Bool, isLayout: Bool,
        isTracking: Bool, isDragging: Bool, isDecelerating: Bool, isScrollAnimating: Bool
    ) -> TimelineScrollDateLabelMovement {
        let isJump = isScrollAnimating && (hostAnimationActive || systemJumpActive)
        return TimelineScrollDateLabelMovement(
            isHostDriven: isApplyingProgrammaticScroll || isJump, isLayout: isLayout, isTracking: isTracking,
            isDragging: isDragging, isDecelerating: isDecelerating, isSystemAnimation: isScrollAnimating && !isJump)
    }
}

/// Decides whether a viewport movement comes from the person.
///
/// - Host-driven and layout movements never count.
/// - Touch, drag, deceleration and system scroll animations count.
/// - A movement without any of these flags counts only while it continues frame after frame.
public struct TimelineScrollDateLabelInputClassifier: Equatable, Sendable {
    /// The longest gap between two unflagged movements of one continuous gesture.
    public static let continuationWindow: TimeInterval = 0.05

    private var lastUnflaggedTime: TimeInterval?

    public init() {}

    public mutating func isUserMovement(_ movement: TimelineScrollDateLabelMovement, at time: TimeInterval) -> Bool {
        if movement.isHostDriven || movement.isLayout {
            lastUnflaggedTime = nil
            return false
        }
        if movement.isTracking || movement.isDragging || movement.isDecelerating || movement.isSystemAnimation {
            lastUnflaggedTime = nil
            return true
        }
        defer { lastUnflaggedTime = time }
        guard let last = lastUnflaggedTime else { return false }
        return time - last <= Self.continuationWindow
    }
}

/// The state of a scroll host that decides whether its label may show at all.
public struct TimelineScrollDateLabelHostState: Equatable, Sendable {
    public var hasWindow: Bool
    public var isActive: Bool
    public var isBackgrounded: Bool
    /// Pinch, zoom, density or content transitions.
    public var isTransforming: Bool
    public var hasItems: Bool
    /// The content is taller than the viewport.
    public var isScrollable: Bool

    public init(
        hasWindow: Bool, isActive: Bool, isBackgrounded: Bool, isTransforming: Bool, hasItems: Bool,
        isScrollable: Bool
    ) {
        self.hasWindow = hasWindow
        self.isActive = isActive
        self.isBackgrounded = isBackgrounded
        self.isTransforming = isTransforming
        self.hasItems = hasItems
        self.isScrollable = isScrollable
    }

    /// True when the label must stay hidden: no window, an inactive tab, a background scene, a transform, no photos
    /// or content that does not scroll.
    public var suppressesLabel: Bool {
        !hasWindow || !isActive || isBackgrounded || isTransforming || !hasItems || !isScrollable
    }
}
