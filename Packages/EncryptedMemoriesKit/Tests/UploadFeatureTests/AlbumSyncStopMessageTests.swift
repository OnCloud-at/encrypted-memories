import Foundation
import PhotosCore
import XCTest

@testable import AlbumSyncCore
@testable import PhotoLibraryBackupAdapter

/// After Stop, the message line says that the sync stopped, or that the album finished when the batch that was already
/// sent completed it. Both are information, not errors.
@MainActor
final class AlbumSyncStopMessageTests: XCTestCase {
    private func report(unattachable: Int = 0, incomplete: Int = 0) -> AlbumSyncReport {
        AlbumSyncReport(
            remoteAlbumID: "remote-1", totalAssets: 3, attached: 3 - unattachable, alreadyMember: 0, attachFailed: 0,
            unattachable: unattachable, trashedSkipped: 0, incomplete: incomplete)
    }

    func testAStoppedRunSaysThatTheSyncStopped() {
        XCTAssertEqual(
            AlbumSyncController.messageAfterStop(finished: nil), L10n.string("albumsync.error_stopped"))
    }

    func testAStoppedRunThatFinishedTheAlbumSaysAlbumSynced() {
        XCTAssertEqual(
            AlbumSyncController.messageAfterStop(finished: report()), L10n.string("albumsync.phase_completed"))
    }

    func testAStoppedRunThatEndedWithPhotosThatNeedAttentionAddsNoMessage() {
        XCTAssertNil(AlbumSyncController.messageAfterStop(finished: report(unattachable: 1)))
        XCTAssertNil(AlbumSyncController.messageAfterStop(finished: report(incomplete: 1)))
    }

    func testTheStopTextsAreTheExistingEnglishAndGermanStrings() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) throws -> String? {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key \(key)")
            let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
            return (localization?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        XCTAssertEqual(
            try value("albumsync.error_stopped", "en"),
            "Sync stopped. Progress is saved and the next run continues where it left off.")
        XCTAssertEqual(
            try value("albumsync.error_stopped", "de"),
            "Synchronisierung gestoppt. Der Fortschritt bleibt erhalten, der nächste Lauf setzt fort.")
        XCTAssertEqual(try value("albumsync.phase_completed", "en"), "Album synced")
        XCTAssertEqual(try value("albumsync.phase_completed", "de"), "Album synchronisiert")
    }
}
