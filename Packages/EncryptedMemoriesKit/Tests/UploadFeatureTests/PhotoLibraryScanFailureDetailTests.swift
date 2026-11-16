import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

/// The diagnostics keep one fixed technical wording for a failed scan; the person sees only the localized message.
final class PhotoLibraryScanFailureDetailTests: XCTestCase {
    func testABackendFailureKeepsItsText() {
        let error = UploadError.backend("Photo library scan state could not be saved")
        XCTAssertEqual(
            PhotoLibraryBackupController.scanFailureDetail(error), "Photo library scan state could not be saved")
    }

    func testASystemFailureKeepsOnlyItsDomainAndCode() {
        XCTAssertEqual(
            PhotoLibraryBackupController.scanFailureDetail(CocoaError(.fileWriteUnknown)), "NSCocoaErrorDomain 512")
    }

    func testEveryCatalogSyncFailureKeepsItsTechnicalWording() {
        for error in PhotoLibraryCatalogSyncError.allCases {
            XCTAssertEqual(PhotoLibraryBackupController.scanFailureDetail(error), error.diagnosticText, "\(error)")
        }
    }
}
