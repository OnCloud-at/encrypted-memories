import Foundation
import PhotosCore
import XCTest

@testable import AlbumCore

final class SharedFailureMappingTests: XCTestCase {
    func testAlbumErrorKeepsUnknownAndLocalCapabilitySeparate() {
        XCTAssertEqual(AlbumError.unsupported(operation: "x", gap: "x").failureCause, .unsupported)
        XCTAssertEqual(AlbumError.backend("unknown").failureCause, .unknown)
    }
    func testKnownAlbumCausesAndPartialResults() {
        XCTAssertEqual(AlbumError.requestFailed(AlbumWriteCause(URLError(.timedOut))).failureCause, .network)
        XCTAssertEqual(AlbumError.requestFailed(AlbumWriteCause(CancellationError())).failureCause, .cancelled)
        let cancelledWrite = AlbumError.requestFailed(AlbumWriteCause(URLError(.cancelled)))
        XCTAssertEqual(cancelledWrite.failureCause, .cancelled)
        let policy = FailurePolicy.resolve(cancelledWrite.failureCause, situation: .awaitedByPerson, safety: .mutation)
        XCTAssertEqual(policy.retry, .afterReconciliation)
        XCTAssertEqual(policy.presentation, .alert)
        XCTAssertEqual(
            AlbumError.requestFailed(AlbumWriteCause(URLError(.badServerResponse), httpStatus: 503)).failureCause,
            .serviceTemporary)
        XCTAssertEqual(AlbumError.sharedAlbumReadOnly(.transportUnsupported).failureCause, .unsupported)
        XCTAssertEqual(AlbumError.partialAdd(succeeded: 1, total: 2, message: "").failureCause, .partialCompletion)
        XCTAssertEqual(
            AlbumError.albumCreatedButPhotosNotAdded(albumID: "id", albumName: "name", message: "").failureCause,
            .partialCompletion
        )
    }
    func testAdditionalAlbumCauses() {
        XCTAssertEqual(
            AlbumError.partialAddWithCauses(succeeded: 1, total: 2, message: "", failures: []).failureCause,
            .partialCompletion)
        XCTAssertEqual(AlbumError.sharedAlbumReadOnly(.roleDoesNotPermitEditing).failureCause, .permission)
        XCTAssertEqual(AlbumError.requestFailed(AlbumWriteCause(URLError(.badURL))).failureCause, .unknown)
        XCTAssertEqual(
            AlbumError.requestFailed(AlbumWriteCause(URLError(.badServerResponse), httpStatus: 403)).failureCause,
            .unknown)
        XCTAssertEqual(
            AlbumError.requestFailed(AlbumWriteCause(URLError(.badServerResponse), httpStatus: 429)).failureCause,
            .rateLimited)
    }
}
