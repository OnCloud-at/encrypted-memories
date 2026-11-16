import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter

final class PhotoLibraryCatalogSyncErrorTests: XCTestCase {
    /// The wording that the catalog sync threw as `UploadError.backend` text before the typed cases. The diagnostics
    /// keep reading exactly this text.
    private static let diagnosticTexts: [PhotoLibraryCatalogSyncError: String] = [
        .scanStateNotSaved: "Photo library scan state could not be saved",
        .scanStateNotReset: "Photo library scan state could not be reset",
        .scanStateUnavailable: "Photo library scan state is unavailable",
        .scanSnapshotNotStarted: "Photo library scan snapshot could not be started",
        .scanSnapshotNotSaved: "Photo library scan snapshot could not be saved",
        .scanSnapshotNotPublished: "Photo library scan snapshot could not be published",
        .scanSnapshotUnavailable: "Photo library scan snapshot is unavailable",
        .scanSnapshotNotRead: "Photo library scan snapshot could not be read",
        .scanSnapshotIncomplete: "Photo library scan snapshot is incomplete",
        .removalsNotSaved: "Photo library removals could not be saved",
        .scanProgressNotSaved: "Photo library scan progress could not be saved",
        .removalSweepNotSaved: "Photo library removal sweep could not be saved",
        .scanNotCompleted: "Photo library scan could not be completed",
        .catalogUnavailable: "Photo library catalog is unavailable",
        .catalogNotRead: "Photo library catalog could not be read",
        .catalogNotUpdated: "Photo library catalog could not be updated",
        .catalogClassificationIncomplete: "Photo library catalog classification was incomplete",
        .localStateUnavailable: L10n.string("backup.error_local_state_unavailable"),
    ]

    func testEveryCaseKeepsItsTechnicalWordingForTheDiagnostics() {
        XCTAssertEqual(Set(PhotoLibraryCatalogSyncError.allCases), Set(Self.diagnosticTexts.keys))
        for error in PhotoLibraryCatalogSyncError.allCases {
            XCTAssertEqual(error.diagnosticText, Self.diagnosticTexts[error], "\(error)")
        }
    }

    func testEveryCaseShowsOnlyTheLocalizedLocalStateMessage() {
        let message = L10n.string("backup.error_local_state_unavailable")
        for error in PhotoLibraryCatalogSyncError.allCases {
            XCTAssertEqual(error.errorDescription, message, "\(error)")
            XCTAssertEqual(error.localizedDescription, message, "\(error)")
        }
    }

    func testEveryCaseIsALocalStateFailure() {
        for error in PhotoLibraryCatalogSyncError.allCases {
            XCTAssertEqual(error.failureCause, .localState, "\(error)")
        }
    }
}
