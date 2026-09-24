import XCTest

@testable import PhotoViewerFeature

final class ViewerMediaTransitionStyleTests: XCTestCase {
    func testStandardStylePreservesLivePhotoTiming() {
        let style = ViewerMediaTransitionStyle.standard
        XCTAssertEqual(style.opacityDuration, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(style.scaleDuration, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(style.liveMotionScale, 1.04, accuracy: 0.000_001)
    }
}
