import CoreGraphics

/// Shared semantics for pinch-to-close while the media is unzoomed.
/// A pinch-in follows the fingers, then either restores the viewer or closes it at release.
/// Platform adapters own recognizers and animation plumbing; this type owns thresholds and release decisions.
public enum ViewerPinchDismissPolicy {
    /// Pinch-in engages only below this gesture scale - a zoom-intent (scale up) or noise around 1.0
    /// never grabs the media.
    public static let engagementScale: CGFloat = 0.98

    /// Releasing below this display scale dismisses the viewer; at or above it the media springs back.
    public static let dismissScale: CGFloat = 0.72

    /// The media never visually shrinks below this while attached to the fingers.
    public static let minimumDisplayScale: CGFloat = 0.35

    /// Spring-back animation parameters (duration seconds, damping 0…1).
    public static let springBackDuration: Double = 0.35
    public static let springBackDamping: CGFloat = 0.8

    /// Whether a pinch may take the media at all: only when it is not already zoomed/panned (the zoom
    /// gesture owns that regime) and the fingers actually moved inward.
    public static func engages(gestureScale: CGFloat, isZoomedIn: Bool) -> Bool {
        guard !isZoomedIn, gestureScale.isFinite, gestureScale > 0 else { return false }
        return gestureScale < engagementScale
    }

    /// The on-screen scale for a raw gesture scale while attached: follows the fingers 1:1, floored so
    /// the media never collapses to nothing mid-gesture, and capped at rest size (pinching back out past
    /// 1.0 simply returns it to rest, it never zooms).
    public static func displayScale(gestureScale: CGFloat) -> CGFloat {
        guard gestureScale.isFinite, gestureScale > 0 else { return 1 }
        return min(1, max(minimumDisplayScale, gestureScale))
    }

    /// The release decision: past the dismiss threshold the viewer closes, otherwise it springs back.
    public static func shouldDismiss(releaseScale: CGFloat) -> Bool {
        guard releaseScale.isFinite, releaseScale > 0 else { return false }
        return releaseScale < dismissScale
    }
}
