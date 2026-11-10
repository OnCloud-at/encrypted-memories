import PhotosCore
import XCTest

@testable import MLSearchCore

final class SharedFailureMappingTests: XCTestCase {
    func testRuntimeAndInstallerCauses() {
        XCTAssertEqual(MLRuntimeFailure(category: .network).failureCause, .network)
        for category in [
            MLRuntimeFailureCategory.missingModel, .incompatibleModel, .invalidOutputSchema,
            .invalidStaticInputContract,
        ] {
            XCTAssertEqual(MLRuntimeFailure(category: category).failureCause, .permanent)
        }
        XCTAssertEqual(MLRuntimeFailure(category: .temporaryResource).failureCause, .localTransient)
        XCTAssertEqual(MLRuntimeFailure(category: .retryableRuntimeState).failureCause, .localTransient)
        XCTAssertEqual(MLModelInstallError.licenseProhibitsDistribution.failureCause, .unsupported)
        XCTAssertEqual(MLRuntimeFailure(category: .unknown).failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.notDownloadable.failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.unsafeArtifactPath("x").failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.sizeMismatch(artifact: "x", expected: 1, actual: 2).failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.artifactMissing("x").failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.ambiguousModelArtifact.failureCause, .unknown)
        XCTAssertEqual(MLModelInstallError.installRecordUnreadable.failureCause, .unknown)
        XCTAssertEqual(
            MLModelInstallError.insufficientStorage(requiredBytes: 10, availableBytes: 1).failureCause, .deviceStorage)
        XCTAssertEqual(MLModelInstallError.cancelled.failureCause, .cancelled)
        XCTAssertEqual(MLModelInstallError.checksumMismatch(artifact: "x").failureCause, .unknown)
    }
}
