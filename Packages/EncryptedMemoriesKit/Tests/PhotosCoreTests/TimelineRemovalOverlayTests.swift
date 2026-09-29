import XCTest

@testable import PhotosCore

final class TimelineRemovalOverlayTests: XCTestCase {
    private let photo = PhotoUID(volumeID: "v", nodeID: "photo")

    func testATrashedPhotoLeavesTheLibraryRoutesAndShowsInTheTrash() {
        var overlay = TimelineRemovalOverlay()

        overlay.trashed([photo])

        XCTAssertEqual(overlay.hidden(on: .all), [photo])
        XCTAssertEqual(overlay.hidden(on: .tag(.favorites)), [photo])
        XCTAssertTrue(overlay.hidden(on: .trash).isEmpty)
    }

    func testARestoredPhotoReturnsToTheLibraryAndLeavesTheTrash() {
        var overlay = TimelineRemovalOverlay()
        overlay.trashed([photo])

        overlay.restored([photo])

        XCTAssertTrue(overlay.hidden(on: .all).isEmpty)
        XCTAssertEqual(overlay.hidden(on: .trash), [photo])
    }

    func testTrashingARestoredPhotoAgainShowsItInTheTrashAgain() {
        var overlay = TimelineRemovalOverlay()
        overlay.trashed([photo])
        overlay.restored([photo])

        overlay.trashed([photo])

        XCTAssertEqual(overlay.hidden(on: .all), [photo])
        XCTAssertTrue(overlay.hidden(on: .trash).isEmpty)
    }

    func testEmptyingTheTrashHidesItsPhotosFromTheTrashOnly() {
        var overlay = TimelineRemovalOverlay()
        overlay.trashed([photo])

        overlay.trashEmptied([photo])

        XCTAssertEqual(overlay.hidden(on: .trash), [photo])
        XCTAssertEqual(overlay.hidden(on: .all), [photo])
    }
}
