import Foundation
import PhotosCore
import UploadCore
import XCTest

/// The Mac settings add a folder to the backup through this rule: a folder whose bookmark cannot be made shows one short
/// sentence, and no system text reaches the person.
final class BackupFolderRegistrationTests: XCTestCase {
    private struct BookmarkFailure: LocalizedError {
        var errorDescription: String? { "NSCocoaErrorDomain Code=256 The file couldn't be opened. (internal detail)" }
    }

    func testAFolderWhoseBookmarkCannotBeMadeShowsTheShortSentenceNotTheSystemText() {
        let errors: [any Error] = [
            BookmarkFailure(), CocoaError(.fileReadNoPermission), CocoaError(.fileNoSuchFile),
            NSError(domain: NSPOSIXErrorDomain, code: 13),
        ]
        for error in errors {
            let result = BackupFolderRegistration.bookmark(for: URL(fileURLWithPath: "/x")) { _ in throw error }
            guard case .failure(let failure) = result else {
                return XCTFail("a failed bookmark gave a folder: \(error)")
            }
            XCTAssertEqual(failure.message, L10n.string("backup.folder_open_failed"), "\(error)")
            XCTAssertNotEqual(failure.message, "backup.folder_open_failed", "the key has a text")
            XCTAssertFalse(failure.message.contains("NSCocoa"), "\(error)")
        }
    }

    func testAFolderWithABookmarkIsRegisteredWithTheBookmarkOfTheMaker() {
        let url = URL(fileURLWithPath: "/fixture/Photos")
        var asked: [URL] = []
        let result = BackupFolderRegistration.bookmark(for: url) {
            asked.append($0)
            return Data([1, 2, 3])
        }
        XCTAssertEqual(try? result.get(), Data([1, 2, 3]))
        XCTAssertEqual(asked, [url], "the maker is asked once, for the chosen folder")
    }

    /// A folder that was added clears the sentence of an earlier failed add. A message of a sync stays.
    func testAnAddedFolderClearsOnlyTheSentenceOfAFailedAdd() {
        let failed = BackupFolderRegistration.failureMessage
        XCTAssertNil(BackupFolderRegistration.messageAfterSuccessfulAdd(current: failed))
        XCTAssertEqual(BackupFolderRegistration.messageAfterSuccessfulAdd(current: "Sync stopped."), "Sync stopped.")
        XCTAssertNil(BackupFolderRegistration.messageAfterSuccessfulAdd(current: nil))
    }

    func testTheSentenceIsNotTheKeyAndNamesNoSystemDetail() {
        let text = BackupFolderRegistration.failureMessage
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, "backup.folder_open_failed", "the key has a text")
        XCTAssertFalse(text.contains("Cocoa"))
    }
}
