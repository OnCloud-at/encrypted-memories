import CoreGraphics
import PhotoViewerCore
import PhotosCore
import XCTest

/// Locks the shared bounded viewer-loading policy: the display decode size is screen-bounded (never the full
/// original just because a page appeared), and the load window is the current page only.
final class ViewerImageLoadPolicyTests: XCTestCase {
    func testDisplayMaxPixelSizeIsScreenBoundedWithHeadroomAndClamped() {
        // Screen-fit × headroom for a normal phone viewport at 3×: 900pt × 3 × 2 = 5400, clamped to the ceiling.
        let phone = ViewerImageLoadPolicy.displayMaxPixelSize(
            viewportPoints: CGSize(width: 400, height: 900), scale: 3)
        XCTAssertEqual(phone, ViewerImageLoadPolicy.maxDisplayPixelSize)

        // A small viewport stays below the ceiling: 400pt × 2 × 2 = 1600.
        let small = ViewerImageLoadPolicy.displayMaxPixelSize(
            viewportPoints: CGSize(width: 300, height: 400), scale: 2)
        XCTAssertEqual(small, 1600)
        XCTAssertLessThan(small, ViewerImageLoadPolicy.maxDisplayPixelSize)

        // Never unbounded: it never exceeds the ceiling.
        XCTAssertLessThanOrEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: CGSize(width: 5000, height: 5000), scale: 3),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
    }

    func testDisplayMaxPixelSizeFallsBackToCeilingForUnknownViewport() {
        // Zero / degenerate viewport or scale must still yield a bounded decode (the ceiling), never 0 or unbounded.
        XCTAssertEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: .zero, scale: 3),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
        XCTAssertEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: CGSize(width: 400, height: 900), scale: 0),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
    }

    func testLoadWindowIsCurrentPageOnly() {
        XCTAssertTrue(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 0))
        // Neighbours (swipe-preview pages) do not load their display image - no fetch/decode fan-out.
        XCTAssertFalse(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 1))
        XCTAssertFalse(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 3))
        XCTAssertEqual(ViewerImageLoadPolicy.loadNeighborRadius, 0)
    }

    func testLoadIdentityTracksOnlyTheBoundedDisplayCap() {
        let uid = PhotoUID(volumeID: "v", nodeID: "n")
        XCTAssertEqual(
            ViewerImageLoadPolicy.LoadIdentity(uid: uid, isCurrent: true, maxPixelSize: 3072),
            ViewerImageLoadPolicy.LoadIdentity(uid: uid, isCurrent: true, maxPixelSize: 3072)
        )
        XCTAssertNotEqual(
            ViewerImageLoadPolicy.LoadIdentity(uid: uid, isCurrent: true, maxPixelSize: 720),
            ViewerImageLoadPolicy.LoadIdentity(uid: uid, isCurrent: true, maxPixelSize: 3072),
            "a transition-sized first decode must self-upgrade when the full viewer viewport arrives"
        )
    }

    func testVisibleImageQualityNeverMovesBackward() {
        XCTAssertFalse(
            ViewerImageLoadPolicy.shouldReplaceDisplayedImage(
                currentLongestPixelSide: 1_024,
                candidateLongestPixelSide: 720
            ))
        XCTAssertTrue(
            ViewerImageLoadPolicy.shouldReplaceDisplayedImage(
                currentLongestPixelSide: 1_024,
                candidateLongestPixelSide: 1_024
            ))
        XCTAssertTrue(
            ViewerImageLoadPolicy.shouldReplaceDisplayedImage(
                currentLongestPixelSide: 1_024,
                candidateLongestPixelSide: 3_072
            ))
    }
}
