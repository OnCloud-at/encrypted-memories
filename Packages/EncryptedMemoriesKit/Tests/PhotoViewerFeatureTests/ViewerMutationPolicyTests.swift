import PhotoViewerCore
import PhotosCore
import XCTest

final class ViewerMutationPolicyTests: XCTestCase {
    func testLibraryItemsMoveToTrash() {
        XCTAssertEqual(ViewerMutationPolicy.action(for: .library), .moveToTrash)
    }

    func testTrashItemsRestore() {
        XCTAssertEqual(ViewerMutationPolicy.action(for: .trash), .restore)
    }

    func testPhotoFilterMapsToOneSharedViewerContext() {
        XCTAssertEqual(ViewerCollectionContext(filter: .all), .library)
        XCTAssertEqual(ViewerCollectionContext(filter: .tag(.favorites)), .library)
        XCTAssertEqual(ViewerCollectionContext(filter: .album(id: "a", title: "Album")), .library)
        XCTAssertEqual(ViewerCollectionContext(filter: .map), .library)
        XCTAssertEqual(ViewerCollectionContext(filter: .trash), .trash)
    }
}
