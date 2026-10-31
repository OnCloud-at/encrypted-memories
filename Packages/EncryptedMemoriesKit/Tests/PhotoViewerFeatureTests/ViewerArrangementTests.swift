import PhotoViewerCore
import XCTest

/// The viewer reads the system's folded layout only from the z-index the overlay arrangement gives its two parts.
/// Measured on the iPhone Duo simulator (iOS 27.1): closed and fully open, the lower part has z-index 1 and the media 0;
/// partly open, the lower part drops to 0 and the two parts lie side by side.
final class ViewerArrangementTests: XCTestCase {
    func testALowerPartAboveTheMediaIsTheWholeDisplay() {
        XCTAssertFalse(ViewerArrangement.isSideBySide(lowerPartZIndex: 1, mediaZIndex: 0))
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: false, compactLandscape: false), .regular)
        XCTAssertEqual(
            ViewerChromeLayoutProfile.resolve(sideBySide: false, compactLandscape: true), .compactLandscape)
    }

    func testPartsOnOneLevelAreTheFoldedLayout() {
        XCTAssertTrue(ViewerArrangement.isSideBySide(lowerPartZIndex: 0, mediaZIndex: 0))
        // Only the order counts, not the absolute values.
        XCTAssertTrue(ViewerArrangement.isSideBySide(lowerPartZIndex: 2, mediaZIndex: 3))
        XCTAssertFalse(ViewerArrangement.isSideBySide(lowerPartZIndex: 3, mediaZIndex: 2))
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: true, compactLandscape: false), .folded)
        XCTAssertEqual(ViewerChromeLayoutProfile.resolve(sideBySide: true, compactLandscape: true), .folded)
    }

    /// The owner's values for the folded layout, and the unchanged values of the flat layouts.
    func testTheFoldedLayoutHasATallerFilmstripAndTheDetails() {
        XCTAssertEqual(ViewerChromeLayoutProfile.folded.filmstripItemSide, 60)
        XCTAssertTrue(ViewerChromeLayoutProfile.folded.showsDetails)
        for flat in [ViewerChromeLayoutProfile.regular, .compactLandscape] {
            XCTAssertEqual(flat.filmstripItemSide, 46)
            XCTAssertFalse(flat.showsDetails)
        }
        // The stacked lower part keeps today's filmstrip rows: 8 + 54 + 8 and 6 + 46 + 4.
        XCTAssertEqual(ViewerChromeLayoutProfile.regular.stackedLowerPartHeight, 70)
        XCTAssertEqual(ViewerChromeLayoutProfile.compactLandscape.stackedLowerPartHeight, 56)
    }
}
