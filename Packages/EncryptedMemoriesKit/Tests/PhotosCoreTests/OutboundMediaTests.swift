import Foundation
import PhotosCore
import XCTest

final class OutboundMediaTests: XCTestCase {
    private let capture = Date(timeIntervalSince1970: 1_000)

    private func photo(_ node: String, live: String? = nil) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: capture, mediaType: "image/heic",
            isLivePhoto: live != nil, relatedVideoID: live)
    }

    func testALivePhotoLeavesAsItsStillFollowedByItsMotionVideo() {
        let regular = photo("regular")
        let live = photo("still", live: "motion")

        let files = OutboundMedia.files(for: [regular, live])

        XCTAssertEqual(files.map(\.item.uid.nodeID), ["regular", "still", "motion"])
        XCTAssertEqual(files.map(\.picked.uid.nodeID), ["regular", "still", "still"])
        XCTAssertEqual(files.map(\.isLivePhotoMotion), [false, false, true])
        let motion = files[2].item
        XCTAssertEqual(motion.uid.volumeID, "vol")
        XCTAssertTrue(motion.isVideo)
        XCTAssertFalse(motion.isLivePhoto)
        XCTAssertEqual(motion.captureTime, capture)
    }

    func testEveryFileLeavesOnceAndAPhotoWithoutAMotionVideoLeavesAlone() {
        let live = photo("still", live: "motion")
        let unresolved = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "unresolved"), captureTime: capture, mediaType: "image/heic",
            isLivePhoto: true)
        let selfPaired = photo("self", live: "self")

        let files = OutboundMedia.files(for: [live, live, unresolved, selfPaired])

        XCTAssertEqual(files.map(\.item.uid.nodeID), ["still", "motion", "unresolved", "self"])
        XCTAssertNil(OutboundMedia.livePhotoMotion(of: photo("regular")))
    }

    func testAMotionPairsOnlyWithAStillThatComesBeforeIt() {
        let first = photo("first", live: "first-motion")
        let second = photo("second", live: "second-motion")
        let motionFirst = PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: "second-motion"), captureTime: capture, mediaType: "video/quicktime")
        let items = OutboundMedia.files(for: [first]).map(\.item) + [motionFirst, second]

        XCTAssertEqual(
            OutboundMedia.stillsByMotion(in: items),
            [PhotoUID(volumeID: "vol", nodeID: "first-motion"): first.uid],
            "a motion listed before its still exports under its own name instead of waiting")
    }

    func testDragNamesStayUniqueAndKeepEachMotionWithItsStill() {
        let items = OutboundMedia.files(for: [photo("a", live: "a-motion"), photo("b", live: "b-motion"), photo("c")])
            .map(\.item)
        var names = OutboundFileNames(items: items)
        let own: (PhotoUID) -> String = { $0.nodeID.hasSuffix("motion") ? "FullSizeRender.mov" : "IMG_1.HEIC" }
        func name(_ node: String) -> String { names.name(for: PhotoUID(volumeID: "vol", nodeID: node), own: own) }

        XCTAssertEqual(name("b-motion"), "IMG_1.mov", "a motion asked first names its still first")
        XCTAssertEqual(name("b"), "IMG_1.HEIC")
        XCTAssertEqual(name("a"), "IMG_1 2.HEIC")
        XCTAssertEqual(name("a-motion"), "IMG_1 2.mov")
        XCTAssertEqual(name("c"), "IMG_1 3.HEIC")
        XCTAssertEqual(name("b-motion"), "IMG_1.mov", "the first name holds for the drag")
    }
}
