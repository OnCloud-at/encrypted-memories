import PhotosCore
import XCTest

@testable import LibraryRuntimeAppleAdapter

final class AppleRuntimeMemoryPolicyTests: XCTestCase {
    func testPreservesStrongestPressureSignal() {
        XCTAssertEqual(
            AppleRuntimeMemoryPolicy.pressure(
                dispatchPressure: .critical,
                memoryWarningLatched: false,
                isBackgrounded: false
            ),
            .critical
        )
        XCTAssertEqual(
            AppleRuntimeMemoryPolicy.pressure(
                dispatchPressure: .normal,
                memoryWarningLatched: true,
                isBackgrounded: false
            ),
            .critical
        )
        XCTAssertEqual(
            AppleRuntimeMemoryPolicy.pressure(
                dispatchPressure: .warning,
                memoryWarningLatched: false,
                isBackgrounded: false
            ),
            .warning
        )
    }

    func testBackgroundReducesNormalBudgetAndForegroundRecovers() {
        XCTAssertEqual(
            AppleRuntimeMemoryPolicy.pressure(
                dispatchPressure: .normal,
                memoryWarningLatched: false,
                isBackgrounded: true
            ),
            .warning
        )
        XCTAssertEqual(
            AppleRuntimeMemoryPolicy.pressure(
                dispatchPressure: .normal,
                memoryWarningLatched: false,
                isBackgrounded: false
            ),
            .normal
        )
    }
}
