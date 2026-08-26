import CoreGraphics

/// Computes the effective upload-pixel cap from slot geometry, display scale, headroom, and the platform cap.
///
/// Dense slots use less than the cap; sparse slots reach the cap.
package enum GridTextureUploadSizing {
    /// Returns device-pixel side times `headroom`, clamped to `[floor, cap]`.
    ///
    /// The result is at least 1 and never exceeds `cap`.
    package static func uploadPixels(
        slotSidePoints: CGFloat,
        backingScale: CGFloat,
        headroom: CGFloat,
        floor: Int,
        cap: Int
    ) -> Int {
        let cap = max(1, cap)
        let native = max(0, slotSidePoints) * max(1, backingScale)
        let target = Int((native * max(1, headroom)).rounded())
        let lowerBound = min(max(1, floor), cap)
        return min(cap, max(lowerBound, target))
    }
}
