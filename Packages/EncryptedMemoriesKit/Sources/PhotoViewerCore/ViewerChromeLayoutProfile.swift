import CoreGraphics

/// Geometry of the mobile viewer's filmstrip rows below the media. The bars themselves are native; compact
/// landscape trades filmstrip height for the shorter window.
public struct ViewerChromeLayoutProfile: Equatable, Sendable {
    public let controlSide: CGFloat
    public let filmstripHeight: CGFloat
    public let rowSpacing: CGFloat
    public let bottomPadding: CGFloat

    public static let regular = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 54,
        rowSpacing: 8,
        bottomPadding: 8
    )

    public static let compactLandscape = ViewerChromeLayoutProfile(
        controlSide: 44,
        filmstripHeight: 46,
        rowSpacing: 6,
        bottomPadding: 4
    )
}
