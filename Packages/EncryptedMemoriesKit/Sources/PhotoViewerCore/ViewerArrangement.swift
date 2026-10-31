/// How the viewer's media and its lower part (the filmstrip, and the details in the folded layout) share the display.
///
/// An overlay arrangement lays the lower part over the media while the display is whole, and puts the two on separate
/// parts of the display when the system selects the folded layout of a partly open device: the media above and the
/// lower part below in tabletop, the media leading and the lower part trailing in book pose. The system reports this
/// through each part's z-index in the arrangement (`overlayArrangementZIndex`): the lower part lies above the media
/// only while the display is whole. The viewer never reads the device or the hinge angle.
public enum ViewerArrangement {
    /// Whether the system put the two parts side by side: the lower part no longer lies above the media.
    public static func isSideBySide(lowerPartZIndex: Int, mediaZIndex: Int) -> Bool {
        lowerPartZIndex <= mediaZIndex
    }
}
