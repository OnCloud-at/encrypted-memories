import XCTest

@testable import PhotoViewerCore

final class ViewerChromePresentationStyleTests: XCTestCase {
    func testStandardStyleUsesShortStableChromeMotion() {
        let style = ViewerChromePresentationStyle.standard

        XCTAssertEqual(style.visibilityDuration, 0.20)
        XCTAssertEqual(style.inspectorDuration, 0.22)
        XCTAssertEqual(style.edgeOffset, 8)
    }
}
