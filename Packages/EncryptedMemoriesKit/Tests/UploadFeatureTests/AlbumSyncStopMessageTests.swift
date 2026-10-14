import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import AlbumSyncCore
@testable import PhotoLibraryBackupAdapter

/// After Stop, the message line says that the sync stopped, or that the album finished when the batch that was already
/// sent completed it. Both are information, not errors.
@MainActor
final class AlbumSyncStopMessageTests: XCTestCase {
    private struct NoRemoteAlbums: AlbumSyncRemoteAlbumOps {
        func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
        func createAlbum(name: String) async throws -> String { "remote-1" }
        func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
        func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
            AlbumSyncAttachResult()
        }
    }

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

    func testAnErrorAfterAStopMessageShowsAsAnErrorAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-stop-message-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let controller = AlbumSyncController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
            identityResolver: nil, uploader: MockUploader(), remoteOps: NoRemoteAlbums())
        addTeardownBlock { await controller.shutdown() }
        XCTAssertEqual(controller.lastMessageStyle, .error)

        controller.setMessage(L10n.string("albumsync.error_stopped"), style: .information)
        XCTAssertEqual(controller.lastMessageStyle, .information)
        controller.setMessage(AlbumSyncError.alreadyRunning.errorDescription)

        XCTAssertEqual(controller.lastMessage, AlbumSyncError.alreadyRunning.errorDescription)
        XCTAssertEqual(controller.lastMessageStyle, .error, "a real error stays red")
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
