import PhotosCore
import ProtonAuth
import XCTest

@testable import ProtonDriveBackend

/// The library-open screen shows its title, at most one sentence of the app's own, and Try again only when another
/// attempt with the same session can succeed. Proton is named only for a rejected session, which is proven.
final class LibraryOpenFailurePresentationTests: XCTestCase {
    func testARejectedSessionAsksForANewSignInAndOffersNoRetry() {
        // A surviving 401 means the token refresh already failed to renew the session.
        let presentation = LibraryOpenFailurePresentation(
            for: ProtonAuthError.apiError(code: 401, message: "unauthorized"))

        XCTAssertEqual(presentation.message, L10n.string("auth.sign_in_again"))
        XCTAssertFalse(presentation.isRetryable)
        XCTAssertNotEqual(presentation.message, "auth.sign_in_again", "the key exists in the catalog")
    }

    func testATerminallyLostDriveScopeOffersNoRetryAndNoText() {
        // The marker protocol marks a scope failure that polling the same remote scope cannot recover.
        struct LostScope: Error, LibraryChangeTerminalError {}
        let presentation = LibraryOpenFailurePresentation(for: LostScope())

        XCTAssertEqual(presentation.message, "")
        XCTAssertFalse(presentation.isRetryable)
    }

    func testAnAccountWithoutAPhotosLibraryKeepsRetryBecauseTheLibraryCanAppearLater() {
        let presentation = LibraryOpenFailurePresentation(for: DriveBridgeError.noPhotosShare)

        XCTAssertEqual(presentation.message, L10n.string("error.no_photos_library"))
        XCTAssertNotEqual(presentation.message, "error.no_photos_library", "the key exists in the shared catalog")
        XCTAssertTrue(presentation.isRetryable)
    }

    func testAFailedLibraryCreationKeepsItsOwnSentenceAndRetry() {
        for error in [
            PhotosVolumeBootstrapError.missingSigner, .creationFailed(underlying: URLError(.timedOut)),
        ] {
            let presentation = LibraryOpenFailurePresentation(for: error)

            XCTAssertEqual(presentation.message, L10n.string("error.library_creation_failed"), "\(error)")
            XCTAssertTrue(presentation.isRetryable, "\(error)")
        }
    }

    func testAnUnclearFailureShowsNoTextOfItsOwnAndKeepsRetry() {
        struct UnclearFailure: Error {}
        let errors: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut),
            ProtonAuthError.apiError(code: 500, message: "oops"), ProtonAuthError.apiError(code: 429, message: "slow"),
            ProtonAuthError.invalidResponse, AccountDataRefreshError.unavailable, UnclearFailure(),
        ]
        for error in errors {
            let presentation = LibraryOpenFailurePresentation(for: error)

            XCTAssertEqual(presentation.message, "", "no technical or empty text of the error: \(error)")
            XCTAssertTrue(presentation.isRetryable, "\(error)")
        }
    }

    func testAnOpenFailureNeverShowsTheTextOfTheSystemOrTheServer() {
        let raw = ProtonAuthError.apiError(code: 503, message: "HTTP 503 for /drive/photos/volumes")

        XCTAssertEqual(LibraryOpenFailurePresentation(for: raw).message, "")
        XCTAssertEqual(LibraryLoadFailureMessage.message(for: raw), "")
        XCTAssertEqual(LibraryLoadFailureMessage.message(for: URLError(.cannotFindHost)), "")
    }
}
