import XCTest

@testable import PhotosCore

final class PhotoFilterEmptyStateTests: XCTestCase {
    func testTrashEmptyStateCopyIsShared() {
        let copy = PhotoFilter.trash.emptyStateCopy

        XCTAssertEqual(copy.title, L10n.string("empty.trash_title"))
        XCTAssertEqual(copy.description, L10n.string("empty.trash_description"))
        XCTAssertEqual(copy.systemImage, "trash")
    }

    func testSmartFilterEmptyStateUsesTagCopy() {
        let copy = PhotoFilter.tag(.favorites).emptyStateCopy

        XCTAssertEqual(copy.title, L10n.string("empty.filter_title \(PhotoTag.favorites.title)"))
        XCTAssertEqual(copy.description, L10n.string("empty.filter_description"))
        XCTAssertEqual(copy.systemImage, PhotoTag.favorites.systemImage)
    }
}
