import Foundation
import PhotoViewerCore
import PhotosCore
import XCTest

final class SeriesFavoritesSelectionTests: XCTestCase {
    private func item(_ id: String) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: "image/heic",
            tags: [.bursts],
            burstMemberIDs: ["a", "b", "c", "d"]
        )
    }

    private func selection(focused: String? = "b", canKeepOnlyFavorites: Bool = true) -> SeriesFavoritesSelection {
        SeriesFavoritesSelection(
            items: ["a", "b", "c", "d"].map(item),
            focusedUID: focused.map { PhotoUID(volumeID: "v", nodeID: $0) },
            canKeepOnlyFavorites: canKeepOnlyFavorites
        )
    }

    func testOpensOnTheViewerPhotoAndFallsBackToTheFirstPhoto() {
        XCTAssertEqual(selection().focusedItem?.uid.nodeID, "b")
        XCTAssertEqual(selection(focused: "missing").focusedIndex, 0)
        XCTAssertEqual(selection(focused: nil).focusedIndex, 0)
    }

    func testFocusAcceptsOnlyAnotherPhotoOfTheSeries() {
        var model = selection()
        XCTAssertTrue(model.focus(index: 3))
        XCTAssertEqual(model.focusedItem?.uid.nodeID, "d")
        XCTAssertFalse(model.focus(index: 3), "the same photo is not a change")
        XCTAssertFalse(model.focus(index: 4))
        XCTAssertFalse(model.focus(index: -1))
        XCTAssertEqual(model.focusedIndex, 3)
    }

    func testConfirmOnlyClosesWhileNoFavoriteIsMarked() {
        var model = selection()
        XCTAssertEqual(model.confirmation, .close)

        model.toggleFavorite(item("c").uid)
        XCTAssertEqual(model.confirmation, .choose(favoriteCount: 1))
        model.toggleFavorite(item("c").uid)
        XCTAssertEqual(model.confirmation, .close, "a second tap removes the mark")
    }

    func testFavoritesAreReportedInSeriesOrderWhateverTheTapOrder() {
        var model = selection()
        for id in ["d", "a", "c"] { model.toggleFavorite(item(id).uid) }

        XCTAssertEqual(model.orderedFavoriteUIDs.map(\.nodeID), ["a", "c", "d"])
        XCTAssertEqual(model.confirmation, .choose(favoriteCount: 3))
        XCTAssertTrue(model.isFavorite(item("a").uid))
        XCTAssertFalse(model.isFavorite(item("b").uid))
    }

    func testPhotoOutsideTheSeriesCannotBecomeAFavorite() {
        var model = selection()
        model.toggleFavorite(PhotoUID(volumeID: "v", nodeID: "elsewhere"))
        model.toggleFavorite(PhotoUID(volumeID: "other-volume", nodeID: "a"))
        XCTAssertTrue(model.favoriteUIDs.isEmpty)
    }

    func testSeriesOutsideTheOwnLibraryIsBrowseOnly() {
        var model = selection(canKeepOnlyFavorites: false)
        model.toggleFavorite(item("a").uid)

        XCTAssertTrue(model.favoriteUIDs.isEmpty, "a shared-album series accepts no marks")
        XCTAssertEqual(model.confirmation, .close, "and it never offers Keep Only Favorites")
        XCTAssertTrue(model.focus(index: 2), "browsing still works")
    }
}
