import CoreGraphics

/// How the viewer's media and its bottom accessory (the filmstrip) share the display.
///
/// On iPhone Duo an overlay arrangement lays the accessory over the media while the display is whole, and puts
/// the two on separate parts of the display while the device is partially open. Only the stacked layout needs
/// the media to end above the accessory, the way the filmstrip has always shortened the media.
public enum ViewerArrangementGeometry {
    /// The bottom inset that keeps the media clear of an accessory stacked over it, or 0 when the accessory lies
    /// beside or below the media. Both frames are in one coordinate space.
    public static func stackedBottomInset(accessory: CGRect, media: CGRect) -> CGFloat {
        guard !accessory.isNull, !media.isNull, !accessory.isEmpty, !media.isEmpty,
            accessory.minX < media.maxX, accessory.maxX > media.minX,
            accessory.minY < media.maxY, accessory.maxY > media.minY
        else { return 0 }
        return media.maxY - accessory.minY
    }
}
