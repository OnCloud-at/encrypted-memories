import Foundation
import PhotosCore
import XCTest

@testable import AlbumCore
@testable import AlbumsFeature

final class AlbumCoverFailureMessageTests: XCTestCase {
    private let generic = "generic cover text"

    private func message(for error: any Error) -> String? {
        AlbumFailurePresentation.coverMessage(for: error) { text in
            text == .albumCover ? generic : "unexpected \(text)"
        }
    }

    func testAlbumOutcomesThatNameTheirReasonShowThatReason() {
        let cause = AlbumWriteCause(URLError(.badServerResponse))
        let errors: [AlbumError] = [
            .unsupported(operation: "cover", gap: "no endpoint"),
            .sharedAlbumReadOnly(.roleDoesNotPermitEditing),
            .sharedAlbumReadOnly(.transportUnsupported),
            .albumCreatedButPhotosNotAdded(albumID: "a", albumName: "Trip", message: "m", cause: cause),
            .partialAdd(succeeded: 1, total: 2, message: "m"),
            .partialAddWithCauses(succeeded: 1, total: 2, message: "m", failures: []),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertEqual(message(for: error), error.errorDescription, "\(error)")
        }
    }

    func testOtherAlbumFailuresShowTheGenericText() {
        let cause = AlbumWriteCause(URLError(.badServerResponse), httpStatus: 500)
        for error: AlbumError in [.backend("internal text"), .requestFailed(cause)] {
            XCTAssertEqual(message(for: error), generic, "\(error)")
        }
        XCTAssertEqual(message(for: URLError(.timedOut)), generic)
    }

    func testCancellationShowsNoAlert() {
        XCTAssertNil(message(for: CancellationError()))
        XCTAssertNil(message(for: URLError(.cancelled)))
        XCTAssertNil(message(for: AlbumError.requestFailed(AlbumWriteCause(CancellationError()))))
    }

    func testAnAlbumOutcomeWinsOverItsUnderlyingCancellation() {
        let error = AlbumError.albumCreatedButPhotosNotAdded(
            albumID: "a", albumName: "Trip", message: "m", cause: AlbumWriteCause(CancellationError()))

        XCTAssertEqual(message(for: error), error.errorDescription)
    }
}
