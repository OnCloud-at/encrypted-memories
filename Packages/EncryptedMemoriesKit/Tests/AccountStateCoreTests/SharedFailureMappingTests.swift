import PhotosCore
import XCTest

@testable import AccountStateCore

final class SharedFailureMappingTests: XCTestCase {
    func testAccountStateCauses() {
        XCTAssertEqual(AccountStateDamagedError().failureCause, .unknown)
        XCTAssertEqual(AccountStateReadOnlyError(format: 999).failureCause, .userDecision)
        XCTAssertEqual(AccountStateInvalidChangeError().failureCause, .permanent)
    }
}
