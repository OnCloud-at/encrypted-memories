import CoreGraphics

/// Geometry of the mobile viewer's filmstrip rows below the media. The bars themselves are native; compact
/// landscape trades filmstrip height for the shorter window. The folded layout of a partly open device gives the
/// lower part to a slightly taller filmstrip and the photo details.
public struct ViewerChromeLayoutProfile: Equatable, Sendable {
    public let controlSide: CGFloat
    public let filmstripHeight: CGFloat
    public let filmstripItemSide: CGFloat
    public let rowSpacing: CGFloat
    public let bottomPadding: CGFloat
    /// Whether the lower part shows the date and time, the place and the albums of the photo.
    public let showsDetails: Bool
    /// The insets of the details beside and above and below them.
    public let detailsHorizontalPadding: CGFloat
    public let detailsVerticalPadding: CGFloat
    /// The space between the date row, the place and the album chips.
    public let detailsGroupSpacing: CGFloat
    /// The space between the date and the time: beside each other, or stacked when the row is too narrow.
    public let detailsTitleSpacing: CGFloat
    public let detailsStackedTitleSpacing: CGFloat
    /// The album chips: their spacing, their insets and the longest title width before it truncates.
    public let albumChipSpacing: CGFloat
    public let albumChipHorizontalPadding: CGFloat
    public let albumChipVerticalPadding: CGFloat
    public let albumChipMaxWidth: CGFloat

    /// The height of the filmstrip row while it lies over the media: its top spacing, the strip and its bottom
    /// padding. The media ends this far above the bottom of its area.
    public var stackedLowerPartHeight: CGFloat { rowSpacing + filmstripHeight + bottomPadding }

    public static let regular = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 54,
        filmstripItemSide: 46,
        rowSpacing: 8,
        bottomPadding: 8,
        showsDetails: false,
        detailsHorizontalPadding: 0,
        detailsVerticalPadding: 0,
        detailsGroupSpacing: 0,
        detailsTitleSpacing: 0,
        detailsStackedTitleSpacing: 0,
        albumChipSpacing: 0,
        albumChipHorizontalPadding: 0,
        albumChipVerticalPadding: 0,
        albumChipMaxWidth: 0
    )

    public static let compactLandscape = ViewerChromeLayoutProfile(
        controlSide: 44,
        filmstripHeight: 46,
        filmstripItemSide: 46,
        rowSpacing: 6,
        bottomPadding: 4,
        showsDetails: false,
        detailsHorizontalPadding: 0,
        detailsVerticalPadding: 0,
        detailsGroupSpacing: 0,
        detailsTitleSpacing: 0,
        detailsStackedTitleSpacing: 0,
        albumChipSpacing: 0,
        albumChipHorizontalPadding: 0,
        albumChipVerticalPadding: 0,
        albumChipMaxWidth: 0
    )

    public static let folded = ViewerChromeLayoutProfile(
        controlSide: 52,
        filmstripHeight: 68,
        filmstripItemSide: 60,
        rowSpacing: 8,
        bottomPadding: 8,
        showsDetails: true,
        detailsHorizontalPadding: 20,
        detailsVerticalPadding: 12,
        detailsGroupSpacing: 12,
        detailsTitleSpacing: 8,
        detailsStackedTitleSpacing: 2,
        albumChipSpacing: 8,
        albumChipHorizontalPadding: 12,
        albumChipVerticalPadding: 6,
        albumChipMaxWidth: 240
    )

    /// The profile for the lower part. `sideBySide` is the system's folded arrangement, read from the z-index it gives
    /// the media and the lower part (`ViewerArrangement`); it is never derived from the device.
    public static func resolve(sideBySide: Bool, compactLandscape: Bool) -> ViewerChromeLayoutProfile {
        if sideBySide { return .folded }
        return compactLandscape ? .compactLandscape : .regular
    }
}
