import CoreGraphics

/// Maps a cumulative pinch-gesture scale onto discrete grid density steps.
///
/// Shared policy for mapping a discrete pinch to level changes. The recognizer supplies cumulative scale;
/// this policy returns the number of ladder steps. Positive steps zoom in, and negative steps zoom out.
public enum GridPinchDensityPolicy {
    /// Finger-scale ratio worth one density step.
    public static let scaleRatioPerStep: CGFloat = 2.0

    /// Recognizer scales are clamped into this range so a degenerate reading (0, ∞) cannot produce a
    /// runaway step count; ±4 steps is already beyond any production ladder.
    public static let clampedScaleRange: ClosedRange<CGFloat> = 1.0 / 16.0...16.0

    /// The number of ladder steps a cumulative gesture scale is worth (rounded to the nearest step, so
    /// each step commits at the geometric midpoint between step anchors).
    public static func levelSteps(pinchScale: CGFloat) -> Int {
        Int(continuousLevelDelta(pinchScale: pinchScale).rounded())
    }

    /// Continuous ladder displacement for live pinch rendering. Positive means zoom IN (toward lower level ids),
    /// negative means zoom OUT. Hosts that can render intermediate frames should feed this directly into the shared
    /// `GridZoomTransaction`; hosts that only commit discrete changes should use `levelSteps`.
    public static func continuousLevelDelta(pinchScale: CGFloat) -> CGFloat {
        guard pinchScale.isFinite, pinchScale > 0 else { return 0 }
        let clamped = min(max(pinchScale, clampedScaleRange.lowerBound), clampedScaleRange.upperBound)
        return log2(clamped) / log2(scaleRatioPerStep)
    }

    /// AppKit trackpad input: `NSEvent.magnification` accumulates additively (a running sum of per-event
    /// deltas, not a scale factor), so the macOS host maps it linearly - this much accumulated magnification
    /// is worth one density step. Lives beside the UIKit scale tuning so the two platform curves cannot
    /// drift apart unseen.
    public static let magnificationPerLevel: CGFloat = 0.42

    /// Continuous ladder displacement for a cumulative AppKit `magnification` sum. Positive means zoom IN
    /// (toward lower level ids), mirroring `continuousLevelDelta(pinchScale:)` for UIKit's multiplicative scale.
    public static func continuousLevelDelta(magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite else { return 0 }
        return magnification / magnificationPerLevel
    }
}
