import CoreGraphics

/// Slot-size-derived thumbnail corner radius shared by every grid host.
/// Small slots use sharp corners. Larger slots ramp continuously to the configured base radius.
package enum GridCornerRadiusPolicy {
    /// Slot sides at or below this draw perfectly sharp corners (radius 0).
    package static let sharpMaxSidePoints: CGFloat = 64
    /// Radius gained per point of slot side above `sharpMaxSidePoints` (the continuous ramp slope).
    package static let radiusPerPointAboveCutoff: CGFloat = 0.2

    /// Corner radius in points for a square slot with the given side, ramping from zero to `base`.
    /// Monotonic non-decreasing in `side`, never exceeds `base`, and never exceeds `side / 2`.
    package static func radius(
        forSlotSidePoints side: CGFloat,
        base: CGFloat = GridVisualConstants.thumbnailCornerRadius
    ) -> CGFloat {
        guard base > 0, side > sharpMaxSidePoints else { return 0 }
        let ramped = (side - sharpMaxSidePoints) * radiusPerPointAboveCutoff
        return min(min(base, ramped), side * 0.5)
    }
}
