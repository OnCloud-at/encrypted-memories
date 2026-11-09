import PhotosCore
import XCTest

@testable import AlbumSyncCore

final class SharedFailureMappingTests: XCTestCase {
    func testAlbumSyncCauses() {
        XCTAssertEqual(AlbumSyncError.nameConflict(existing: []).failureCause, .userDecision)
        XCTAssertEqual(AlbumSyncError.mappingStoreUnavailable.failureCause, .localState)
        XCTAssertEqual(AlbumSyncError.stopped.failureCause, .cancelled)
        XCTAssertEqual(AlbumSyncError.alreadyRunning.failureCause, .unknown)
    }
}
