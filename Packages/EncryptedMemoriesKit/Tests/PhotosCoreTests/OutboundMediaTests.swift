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
}
