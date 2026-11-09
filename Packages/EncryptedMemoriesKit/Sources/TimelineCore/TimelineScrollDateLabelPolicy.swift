import CoreGraphics
import Foundation

/// Decides when the transient scroll date label is visible. A pure value: the caller passes every time, so tests
/// drive it with exact instants.
///
/// - A brisk user scroll shows the label: the smoothed speed reaches `showSpeed`.
/// - User movement at `sustainSpeed` or faster keeps it, including momentum. The gap between both speeds keeps a
///   stop and restart near the threshold from flickering.
/// - The label hides `linger` seconds after the last such movement.
/// - Marked navigation jumps end the linger. Layout and content-driven adjustments only reset the speed sample.
/// - Pinch, route changes and inactive surfaces hide it at once.
public struct TimelineScrollDateLabelPolicy: Equatable, Sendable {
    public struct Tuning: Equatable, Sendable {
        /// Points per second of smoothed user scrolling that show the label.
        public var showSpeed: Double
        /// Points per second of user scrolling that keep a visible label.
        public var sustainSpeed: Double
        /// Seconds the label stays after the last sustaining movement.
        public var linger: TimeInterval
        /// Time constant of the speed smoothing, in seconds.
        public var smoothing: TimeInterval
        /// Shortest sample interval; several scroll events in one display frame count as one frame.
        public var minimumInterval: TimeInterval
        /// A pause longer than this starts a new speed measurement.
        public var restartInterval: TimeInterval
        /// The two independently tunable duration pairs and their boundary in smoothed points per second.
        public var fadeIn = TimelineScrollDateLabelMotion.fadeIn
        public var fadeOut = TimelineScrollDateLabelMotion.fadeOut
        public var fastFadeSpeed = TimelineScrollDateLabelMotion.fastFadeSpeed

        public init(
            showSpeed: Double, sustainSpeed: Double, linger: TimeInterval, smoothing: TimeInterval,
            minimumInterval: TimeInterval, restartInterval: TimeInterval
        ) {
            self.showSpeed = showSpeed
            self.sustainSpeed = sustainSpeed
            self.linger = linger
            self.smoothing = smoothing
            self.minimumInterval = minimumInterval
            self.restartInterval = restartInterval
        }

        public static let standard = Tuning(
            showSpeed: 600, sustainSpeed: 100, linger: 1.0, smoothing: 0.04,
            minimumInterval: 1.0 / 240.0, restartInterval: 0.25)
    }

    public let tuning: Tuning
    public private(set) var isVisible = false
    /// When a visible label hides if no sustaining movement arrives first.
    public private(set) var hideDeadline: TimeInterval?
    public private(set) var isSuppressed = false
    /// Frozen when visibility changes. Nil means an immediate change, such as suppression.
    public private(set) var fadeDuration: TimeInterval?

    private var lastOffsetY: Double?
    private var lastTime: TimeInterval?
    private var smoothedSpeed: Double = 0
    /// Kept separately because a layout reset or a long linger must not replace the last sustaining movement.
    private var lastSustainingSpeed: Double = 0

    public init(tuning: Tuning = .standard) {
        self.tuning = tuning
    }

    /// A viewport movement that the user drives: finger, momentum, scroll indicator, wheel, trackpad or keyboard.
    public mutating func userMoved(offsetY: Double, at time: TimeInterval) {
        guard !isSuppressed else { return }
        defer {
            lastOffsetY = offsetY
            lastTime = time
        }
        guard let previousY = lastOffsetY, let previousTime = lastTime else { return }
        let elapsed = time - previousTime
        if elapsed > tuning.restartInterval {
            smoothedSpeed = 0  // A long pause starts a new measurement.
        }
        let interval = max(elapsed, tuning.minimumInterval)
        let instant = abs(offsetY - previousY) / interval
        let weight = 1 - exp(-interval / tuning.smoothing)
        smoothedSpeed += (instant - smoothedSpeed) * weight

        if isVisible {
            if smoothedSpeed >= tuning.sustainSpeed {
                lastSustainingSpeed = smoothedSpeed
                hideDeadline = time + tuning.linger
            }
        } else if smoothedSpeed >= tuning.showSpeed {
            isVisible = true
            hideDeadline = time + tuning.linger
            lastSustainingSpeed = smoothedSpeed
            fadeDuration = tuning.fadeIn.duration(for: smoothedSpeed, fastBoundary: tuning.fastFadeSpeed)
        }
    }

    /// A movement without user input. A marked navigation jump ends the linger; layout, resize and content-driven
    /// adjustments leave visibility and the existing deadline unchanged. Every such movement resets the speed sample.
    public mutating func nonUserMoved(isJump: Bool = false) {
        if isJump, isVisible {
            hide(duration: tuning.fadeOut.fast)
        } else {
            resetMeasurement()
        }
    }

    /// Hides the label at once and ignores movement until `resume()`: pinch, route change, inactive surface.
    public mutating func suppress() {
        isSuppressed = true
        hide()
    }

    public mutating func resume() {
        isSuppressed = false
        resetMeasurement()
    }

    /// Hides the label at once, for example when its content became stale.
    public mutating func hide(duration: TimeInterval? = nil) {
        isVisible = false

        hideDeadline = nil
        fadeDuration = duration
        lastSustainingSpeed = 0
        resetMeasurement()
    }

    /// Applies the hide deadline. Returns true when the label changed from visible to hidden.
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Bool {
        guard isVisible, let deadline = hideDeadline, time >= deadline else { return false }
        hide(duration: tuning.fadeOut.duration(for: lastSustainingSpeed, fastBoundary: tuning.fastFadeSpeed))
        return true
    }

    private mutating func resetMeasurement() {
        lastOffsetY = nil
        lastTime = nil
        smoothedSpeed = 0
    }
}

/// Shared timing and spacing of the scroll date label, so every platform looks and moves the same.
public enum TimelineScrollDateLabelMotion {
    public struct FadeDurations: Equatable, Sendable {
        public var slow: TimeInterval
        public var fast: TimeInterval

        public init(slow: TimeInterval, fast: TimeInterval) {
            self.slow = slow
            self.fast = fast
        }

        func duration(for speed: Double, fastBoundary: Double) -> TimeInterval {
            speed >= fastBoundary ? fast : slow
        }
    }

    /// Seconds of each fade; the two pairs can be tuned independently.
    public static let fadeIn = FadeDurations(slow: 0.40, fast: 0.20)
    public static let fadeOut = FadeDurations(slow: 0.70, fast: 0.35)
    /// Boundary at the first smoothed show sample, not at the raw input speed. The visibility threshold stays 600.
    public static let fastFadeSpeed: Double = 650

    /// Points between the label's trailing edge and the scroll host's trailing edge, clear of the indicator.
    public static let indicatorGap: CGFloat = 16
    /// Width of the trailing column that the label can occupy, from the trailing edge, including the indicator gap.
    /// Reserved regions outside this column, such as the crease of an open iPhone Duo, never move the label.
    public static let columnWidth: CGFloat = 240

    /// The leading edge of the label column in a scroll host of `width` points with a trailing safe-area inset.
    public static func columnMinX(width: CGFloat, trailingInset: CGFloat) -> CGFloat {
        width - trailingInset - columnWidth
    }
}

/// Vertical placement of the scroll date label beside the native scroll indicator.
public enum TimelineScrollDateLabelGeometry {
    /// The native thumb owns its track, proportional/minimum length and overscroll squeeze. The adapter forwards
    /// that actual geometry. Only a reserved region or viewport edge can move the label away from its center.
    public static func centerY(
        thumbTop: CGFloat, thumbLength: CGFloat, viewportTop: CGFloat, viewportBottom: CGFloat,
        labelHeight: CGFloat, avoiding bands: [ClosedRange<CGFloat>] = []
    ) -> CGFloat? {
        let desired = thumbTop + thumbLength / 2
        var result: CGFloat?
        var distance = CGFloat.infinity
        forEachFreeSegment(trackTop: viewportTop, trackBottom: viewportBottom, bands: bands) { start, end in
            guard end - start >= labelHeight else { return }
            let center = min(max(desired, start + labelHeight / 2), end - labelHeight / 2)
            let delta = abs(center - desired)
            if delta < distance {
                result = center
                distance = delta
            }
        }
        return result
    }

    /// The vertical bands of reserved regions that reach into the trailing label column (x from `columnMinX` to the
    /// trailing edge), sorted by their top edge. A vertical fold in the middle of an open device stays out of the
    /// column, so it never moves the label; a horizontal fold (tabletop) or a camera does.
    public static func bands(
        avoiding exclusions: [CGRect], trailingColumnFrom columnMinX: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        exclusions.filter { $0.maxX > columnMinX && $0.height > 0 }
            .map { $0.minY...$0.maxY }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Visits the parts of the track that no band covers, top to bottom, without allocating. `bands` must be sorted
    /// by their lower bound.
    private static func forEachFreeSegment(
        trackTop: CGFloat, trackBottom: CGFloat, bands: [ClosedRange<CGFloat>],
        _ visit: (CGFloat, CGFloat) -> Void
    ) {
        var cursor = trackTop
        for band in bands where band.upperBound > cursor && band.lowerBound < trackBottom {
            if band.lowerBound > cursor { visit(cursor, band.lowerBound) }
            cursor = max(cursor, band.upperBound)
        }
        if cursor < trackBottom { visit(cursor, trackBottom) }
    }
}
