import CoreGraphics
import PhotoViewerCore
import Testing

/// The viewer arrangement on iPhone Duo: the filmstrip shortens the media only while the two are stacked.
@Suite struct ViewerArrangementGeometryTests {
    private let media = CGRect(x: 0, y: 0, width: 382, height: 644)

    @Test func aStackedFilmstripShortensTheMedia() {
        // Whole display: the arrangement lays the filmstrip over the bottom of the media.
        let filmstrip = CGRect(x: 0, y: 580, width: 382, height: 64)
        #expect(ViewerArrangementGeometry.stackedBottomInset(accessory: filmstrip, media: media) == 64)
    }

    @Test func aFilmstripBesideTheMediaLeavesItWhole() {
        // Book pose: media on the leading part, filmstrip at the bottom of the trailing part.
        let leadingMedia = CGRect(x: 0, y: 0, width: 440, height: 900)
        let filmstrip = CGRect(x: 480, y: 836, width: 440, height: 64)
        #expect(ViewerArrangementGeometry.stackedBottomInset(accessory: filmstrip, media: leadingMedia) == 0)
    }

    @Test func aFilmstripBelowTheMediaLeavesItWhole() {
        // Tabletop pose: media on the top part, filmstrip on the bottom part; touching edges do not overlap.
        let topMedia = CGRect(x: 0, y: 0, width: 900, height: 420)
        let filmstrip = CGRect(x: 0, y: 420, width: 900, height: 64)
        #expect(ViewerArrangementGeometry.stackedBottomInset(accessory: filmstrip, media: topMedia) == 0)
    }

    @Test func aHiddenFilmstripLeavesTheMediaWhole() {
        // The chrome toggle removes the filmstrip; the media refits to the whole area.
        #expect(ViewerArrangementGeometry.stackedBottomInset(accessory: .null, media: media) == 0)
        #expect(ViewerArrangementGeometry.stackedBottomInset(accessory: .zero, media: media) == 0)
    }
}
