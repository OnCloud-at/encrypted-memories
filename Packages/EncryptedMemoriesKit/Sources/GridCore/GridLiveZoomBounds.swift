import CoreGraphics

/// Bounds the visual zoom level during elastic over-zoom past the largest-thumbnail detent.
/// The visual level may be negative, but committed levels remain valid detents. The densest end is clamped.
public enum GridLiveZoomBounds {
    /// Maximum elastic overshoot past the largest detent, in level units.
    public static let maxOverZoom: CGFloat = 0.5

    /// Maps a raw continuous pinch level to the bounded visual level.
    public static func visualLevel(rawLevel x: CGFloat, levelCount: Int, maxOverZoom: CGFloat = maxOverZoom) -> CGFloat
    {
        let densest = CGFloat(max(0, levelCount - 1))
        guard x < 0 else { return min(x, densest) }
        guard maxOverZoom > 0 else { return 0 }
        // The soft over-travel is monotonic and approaches the cap as overshoot grows.
        let over = -x
        return -maxOverZoom * (1 - 1 / (1 + over))
    }

    /// Clamp an already-resolved visual level to the safe live range `[-maxOverZoom, densest]` (used by the
    /// release spring-back, which works directly in visual-level space rather than raw pinch space).
    public static func clampVisual(_ v: CGFloat, levelCount: Int) -> CGFloat {
        let densest = CGFloat(max(0, levelCount - 1))
        return min(max(v, -maxOverZoom), densest)
    }
}
