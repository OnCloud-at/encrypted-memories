import CoreGraphics

/// Deterministic bridge for correcting an out-of-bounds scroll after a zoom commit.
/// It interpolates only the engine-derived Y values and ends exactly at the clamped target.
public enum GridScrollRebase {
    /// Bridge length - within the 120-180 ms spec.
    public static let duration: CFTimeInterval = 0.15
    /// Minimum scroll delta (px) worth animating; below this the clamp is imperceptible, so commit instantly.
    public static let minPx: CGFloat = 1.5

    /// Whether a rebase from `fromY` to `toY` is large enough to animate (else the caller settles instantly).
    public static func shouldArm(fromY: CGFloat, toY: CGFloat) -> Bool { abs(fromY - toY) > minPx }

    /// Quadratic ease-out (no bounce), clamped to `[0, 1]`. Monotonic, `easeOut(0)=0`, `easeOut(1)=1`.
    public static func easeOut(_ progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return 1 - (1 - p) * (1 - p)
    }

    /// The interpolated scroll Y at `progress` (0 = source, 1 = target). `scrollY(_,_, 1) == toY` exactly.
    public static func scrollY(fromY: CGFloat, toY: CGFloat, progress: CGFloat) -> CGFloat {
        let e = easeOut(progress)
        return e >= 1 ? toY : fromY + (toY - fromY) * e
    }

    /// Linear progress for a bridge started at `start`, evaluated at `now`.
    public static func progress(start: CFTimeInterval, now: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, (now - start) / duration)))
    }
}
