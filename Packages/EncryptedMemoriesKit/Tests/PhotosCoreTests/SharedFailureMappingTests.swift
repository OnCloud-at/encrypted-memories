import XCTest

@testable import PhotosCore

final class SharedFailureMappingTests: XCTestCase {
    func testVideoAndExportCauses() {
        XCTAssertEqual(VideoPlaybackError.networkUnavailable.failureCause, .network)
        XCTAssertEqual(VideoPlaybackError.authExpired.failureCause, .authentication)
        XCTAssertEqual(VideoPlaybackError.streamURLUnavailable.failureCause, .unsupported)
        XCTAssertEqual(VideoPlaybackError.quotaOrRateLimited.failureCause, .rateLimited)
        XCTAssertEqual(VideoPlaybackError.unsupportedCodec.failureCause, .permanent)
        XCTAssertEqual(VideoPlaybackError.metadataUnavailable.failureCause, .unknown)
        XCTAssertEqual(VideoPlaybackError.timedOut.failureCause, .unknown)
        XCTAssertEqual(VideoPlaybackError.localFileError.failureCause, .unknown)
        XCTAssertEqual(VideoPlaybackError.notVideo.failureCause, .permanent)
        XCTAssertEqual(VideoPlaybackError.decryptionFailed.failureCause, .permanent)
        XCTAssertEqual(VideoPlaybackError.malformedContent.failureCause, .permanent)
        XCTAssertEqual(OriginalExportWriter.Failure.lowDisk.failureCause, .deviceStorage)
        XCTAssertEqual(DragOutStagingFailure.cancelled.failureCause, .cancelled)
    }
    func testPartialFavoriteMutationRequiresReconciliation() {
        let uid = PhotoUID(volumeID: "v", nodeID: "n")
        let error = FavoriteMutationError(succeeded: [uid], failed: [], diagnosticMessage: "")
        XCTAssertEqual(error.failureCause, .partialCompletion)
        let unconfirmed = FavoriteMutationError(succeeded: [], failed: [uid], diagnosticMessage: "")
        XCTAssertEqual(unconfirmed.failureCause, .unknown)
    }
}
