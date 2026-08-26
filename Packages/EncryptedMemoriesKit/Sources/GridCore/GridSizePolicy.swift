import CoreGraphics

// MARK: - GridSizePolicy
//
// Provides reference slot sizes for the grid density ladder. The settled grid supplies its nominal column count
// to the geometry engine; the reference side remains the shared calibration value for that level.
public enum GridSizePolicy {
    /// Discrete viewport size classes used by the reference-size policy.
    public enum SizeClass: String, Equatable, Sendable, CaseIterable {
        case compact, regular, wide, ultra
    }

    /// Width used to derive the regular reference slot sizes.
    public static let referenceWidth: CGFloat = 1280

    /// Sub-pixel adjustment that keeps exact-fill column calculations stable at `referenceWidth`.
    public static let epsilon: CGFloat = 0.5

    /// Scale applied to the regular reference size for a viewport class.
    public static func scale(_ sizeClass: SizeClass) -> CGFloat {
        switch sizeClass {
        case .compact: return 0.62
        case .regular: return 1.0
        case .wide: return 1.15
        case .ultra: return 1.30
        }
    }

    /// Reference photo side in points for a density level and viewport class.
    public static func slotSide(nominalColumns: Int, gap: CGFloat, sizeClass: SizeClass = .regular) -> CGFloat {
        let nc = CGFloat(max(1, nominalColumns))
        let base = (referenceWidth + gap) / nc - gap - epsilon  // exact-fill at W_ref, minus the FP nudge
        return max(1, base * scale(sizeClass))
    }

    /// Resolves the current viewport policy. The shipped policy uses the regular class for every width.
    public static func sizeClass(forWidth width: CGFloat) -> SizeClass { .regular }

    /// Optional per-level column cap. `nil` means that no cap applies.
    public static func maxColumns(forLevelID levelID: Int) -> Int? { nil }
}
