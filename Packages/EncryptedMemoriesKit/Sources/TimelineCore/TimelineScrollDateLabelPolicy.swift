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
    private var lastOffsetY: Double?
    private var lastTime: TimeInterval?
    private var smoothedSpeed: Double = 0

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
            if smoothedSpeed >= tuning.sustainSpeed { hideDeadline = time + tuning.linger }
        } else if smoothedSpeed >= tuning.showSpeed {
            isVisible = true
            hideDeadline = time + tuning.linger
        }
    }

    /// A movement without user input. A marked navigation jump ends the linger; layout, resize and content-driven
    /// adjustments leave visibility and the existing deadline unchanged. Every such movement resets the speed sample.
    public mutating func nonUserMoved(isJump: Bool = false) {
        if isJump {
            hide()
            return
        }
        resetMeasurement()
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
    public mutating func hide() {
        isVisible = false
        hideDeadline = nil
        resetMeasurement()
    }

    /// Applies the hide deadline. Returns true when the label changed from visible to hidden.
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Bool {
        guard isVisible, let deadline = hideDeadline, time >= deadline else { return false }
        hide()
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
    /// Seconds of the gentle fade in.
    public static let fadeIn: TimeInterval = 0.2
    /// Seconds of the fade out.
    public static let fadeOut: TimeInterval = 0.35
    /// Points between the label's trailing edge and the scroll host's trailing edge, clear of the indicator.
    public static let indicatorGap: CGFloat = 16
    /// Points the label keeps from the ends of the indicator track.
    public static let trackMargin: CGFloat = 2
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
    /// The label centre in viewport coordinates. It follows the scroll indicator: the scroll fraction maps onto the
    /// indicator track (`trackTop`...`trackBottom`). Bands that the label must not cover, such as a fold, are
    /// skipped: the track becomes the free segments that can hold the label, in order. Returns nil when no segment
    /// can hold the label.
    public static func centerY(
        offsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat,
        trackTop: CGFloat, trackBottom: CGFloat, labelHeight: CGFloat,
        avoiding bands: [ClosedRange<CGFloat>] = []
    ) -> CGFloat? {
        let range = maxOffsetY - minOffsetY
        let fraction = range > 0 ? min(max((offsetY - minOffsetY) / range, 0), 1) : 0
        // Usable length of each free segment: the distance the label centre can travel inside it.
        var total: CGFloat = 0
        forEachFreeSegment(trackTop: trackTop, trackBottom: trackBottom, bands: bands) { start, end in
            total += max(0, end - start - labelHeight)
            return false
        }
        var result: CGFloat?
        var lastFittingEnd: CGFloat?
        var remaining = fraction * total
        forEachFreeSegment(trackTop: trackTop, trackBottom: trackBottom, bands: bands) { start, end in
            guard end - start >= labelHeight else { return false }
            lastFittingEnd = end
            let usable = end - start - labelHeight
            if remaining <= usable {
                result = start + labelHeight / 2 + remaining
                return true
            }
            remaining -= usable
            return false
        }
        // Subtracting the segment lengths can leave a rounding step at the very end of the track; that position is
        // the end of the last segment that holds the label.
        return result ?? lastFittingEnd.map { $0 - labelHeight / 2 }
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
    /// by their lower bound. The visitor returns true to stop.
    private static func forEachFreeSegment(
        trackTop: CGFloat, trackBottom: CGFloat, bands: [ClosedRange<CGFloat>],
        _ visit: (CGFloat, CGFloat) -> Bool
    ) {
        var cursor = trackTop
        for band in bands where band.upperBound > cursor && band.lowerBound < trackBottom {
            if band.lowerBound > cursor, visit(cursor, band.lowerBound) { return }
            cursor = max(cursor, band.upperBound)
        }
        if cursor < trackBottom { _ = visit(cursor, trackBottom) }
    }
}
