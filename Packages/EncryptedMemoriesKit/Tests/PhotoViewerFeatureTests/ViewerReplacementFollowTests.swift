import PhotosCore
import XCTest

@testable import PhotoViewerCore

final class ViewerReplacementFollowTests: XCTestCase {
    /// A kept page finds its photo after a follow; two pages that became one keep the open page.
    func testKeptPageFindsItsPhotoAfterTheCollectionShrank() {
        let after = ["t"].map(uid)
        XCTAssertEqual(ViewerReplacementFollow.newIndex(of: uid("t"), near: 1, count: 1, uidAt: { after[$0] }), 0)
        let shifted = ["a", "b", "t", "c"].map(uid)
        XCTAssertEqual(ViewerReplacementFollow.newIndex(of: uid("t"), near: 3, count: 4, uidAt: { shifted[$0] }), 2)
        XCTAssertEqual(ViewerReplacementFollow.newIndex(of: uid("c"), near: 0, count: 4, uidAt: { shifted[$0] }), 3)
        XCTAssertNil(ViewerReplacementFollow.newIndex(of: uid("gone"), near: 2, count: 4, uidAt: { shifted[$0] }))
        XCTAssertNil(ViewerReplacementFollow.newIndex(of: uid("t"), near: 0, count: 0, uidAt: { _ in uid("x") }))
    }

    func testOpenPhotoFollowsItsEditAtTheSamePage() throws {
        let items = [item("a"), item("u0"), item("b")]
        let followed = try XCTUnwrap(
            follow(items, current: 1, replacements: ["u0": "t"], timeline: ["a", "t", "b"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "t", "b"])
        XCTAssertEqual(followed.pages.index(of: uid("t")), 1)
        XCTAssertNil(followed.pages.index(of: uid("u0")))
        XCTAssertEqual(followed.current, 1)
        XCTAssertEqual(followed.arrived, [uid("t")])
    }

    func testFollowsTheWholeChainToTheUploadedEdit() throws {
        let items = [item("a"), item("u0"), item("b")]
        let followed = try XCTUnwrap(
            follow(items, current: 1, replacements: ["u0": "t", "t": "u1"], timeline: ["a", "u1", "b"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "u1", "b"])
    }

    func testDeletedPhotoWithoutReplacementStays() {
        let items = [item("a"), item("u0"), item("b")]

        XCTAssertNil(follow(items, current: 1, replacements: ["x": "t"], timeline: ["a", "t", "b"]))
    }

    func testPhotoThatStillShowsIsNotSwapped() {
        let items = [item("a"), item("u0"), item("b")]

        XCTAssertNil(follow(items, current: 1, replacements: ["u0": "t"], timeline: ["a", "u0", "t", "b"]))
    }

    func testOpenPhotoMovesToItsReplacementThatAlreadyHasAPage() throws {
        let items = [item("a"), item("u0"), item("t")]
        let followed = try XCTUnwrap(follow(items, current: 1, replacements: ["u0": "t"], timeline: ["a", "t"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "t"])
        XCTAssertEqual(followed.current, 1)
        XCTAssertEqual(followed.pages.index(of: uid("t")), 1)
        XCTAssertNil(followed.pages.index(of: uid("u0")))
        XCTAssertEqual(followed.arrived, [])
    }

    func testOpenPageKeepsItsPhotoWhenAnEarlierPageLeaves() throws {
        let items = [item("u0"), item("a"), item("t")]
        let followed = try XCTUnwrap(follow(items, current: 1, replacements: ["u0": "t"], timeline: ["a", "t"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "t"])
        XCTAssertEqual(followed.current, 0, "the open page still shows a")
        XCTAssertEqual(followed.pages.index(of: uid("a")), 0)
    }

    func testOpenPageWinsASharedReplacement() throws {
        let items = [item("u0"), item("a"), item("v0")]
        let followed = try XCTUnwrap(
            follow(items, current: 2, replacements: ["u0": "t", "v0": "t"], timeline: ["a", "t"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "t"])
        XCTAssertEqual(followed.current, 1)
        XCTAssertEqual(followed.arrived, [uid("t")])
    }

    func testAReturningTileArrivesSoTheViewerDropsItsOldImage() throws {
        // A second edit reuses the tile UID: u0 -> t -> u1 -> t.
        let items = [item("a"), item("u1")]
        let followed = try XCTUnwrap(
            follow(items, current: 1, replacements: ["u1": "t", "t": "u1"], timeline: ["a", "t"]))

        XCTAssertEqual(followed.items.map(\.uid.nodeID), ["a", "t"])
        XCTAssertEqual(followed.current, 1)
        XCTAssertEqual(followed.arrived, [uid("t")])
    }

    private func follow(
        _ items: [PhotoItem], current: Int, replacements: [String: String], timeline: [String]
    ) -> ViewerReplacementFollow.Followed? {
        ViewerReplacementFollow.follow(
            items,
            pages: ViewerPageIndex(orderedUIDs: items.map(\.uid)),
            current: current,
            replacements: Dictionary(uniqueKeysWithValues: replacements.map { (uid($0.key), uid($0.value)) }),
            timeline: TimelineSnapshot(trustingOrderOf: timeline.map { item($0) }))
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: id) }

    private func item(_ id: String) -> PhotoItem {
        PhotoItem(uid: uid(id), captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
    }
}
