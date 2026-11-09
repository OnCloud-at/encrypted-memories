import PhotosCore
import XCTest

@testable import MLSearchCore

final class SharedFailureMappingTests: XCTestCase {
    func testRuntimeAndInstallerCauses() {
        XCTAssertEqual(MLRuntimeFailure(category: .network).failureCause, .network)
        XCTAssertEqual(MLRuntimeFailure(category: .unknown).failureCause, .unknown)
        XCTAssertEqual(MLRuntimeFailure(category: .incompatibleModel).failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.notDownloadable.failureCause, .unknown)
        XCTAssertEqual(
            MLModelInstallError.insufficientStorage(requiredBytes: 10, availableBytes: 1).failureCause, .deviceStorage)
        XCTAssertEqual(MLModelInstallError.cancelled.failureCause, .cancelled)
        XCTAssertEqual(MLModelInstallError.checksumMismatch(artifact: "x").failureCause, .unknown)
    }
}
