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
        XCTAssertEqual(AlbumError.requestFailed(AlbumWriteCause(URLError(.cancelled))).failureCause, .cancelled)
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
}
