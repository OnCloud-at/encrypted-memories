import PhotoViewerCore
import XCTest

final class LivePhotoHoldPolicyTests: XCTestCase {
    func testHoldDurationKeepsMobileTiming() {
        XCTAssertEqual(LivePhotoHoldPolicy.minimumPressDuration, 0.3)
    }

    func testBeginAndTerminalStatesProduceOneStartAndOneStop() {
        for terminal: LivePhotoHoldPolicy.Event in [.ended, .cancelled, .failed] {
            var policy = LivePhotoHoldPolicy()
            XCTAssertNil(policy.consume(.possible))
            XCTAssertNil(policy.consume(.changed))
            XCTAssertNil(policy.consume(terminal))
            XCTAssertEqual(policy.consume(.began), .start)
            XCTAssertNil(policy.consume(.began))
            XCTAssertNil(policy.consume(.changed))
            XCTAssertEqual(policy.consume(terminal), .stop)
            XCTAssertNil(policy.consume(terminal))
            XCTAssertEqual(policy.consume(.began), .start)
        }
    }

    func testEveryInterruptionStopsOnlyAnActiveHold() {
        for event: LivePhotoHoldPolicy.Event in [.scroll, .pan, .pinch, .pageChange, .teardown, .textSelection] {
            var policy = LivePhotoHoldPolicy()
            XCTAssertNil(policy.consume(event))
            XCTAssertEqual(policy.consume(.began), .start)
            XCTAssertEqual(policy.consume(event), .stop)
            XCTAssertNil(policy.consume(event))
            XCTAssertNil(policy.consume(.ended))
        }
    }

    func testTextSelectionExcludesBeginAndStopsAnActiveHold() {
        var policy = LivePhotoHoldPolicy()
        XCTAssertNil(policy.consume(.began, textIsSelected: true))
        XCTAssertNil(policy.consume(.ended))
        XCTAssertEqual(policy.consume(.began), .start)
        XCTAssertEqual(policy.consume(.changed, textIsSelected: true), .stop)
        XCTAssertNil(policy.consume(.ended))
    }
}
