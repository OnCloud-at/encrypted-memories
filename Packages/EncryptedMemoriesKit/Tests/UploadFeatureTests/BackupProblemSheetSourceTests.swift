import AlbumSyncCore
import Foundation
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// The shared state of the macOS and iOS backup problem sheets.
@MainActor
final class BackupProblemSheetSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("problem-sheet-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBackupController() throws -> PhotoLibraryBackupController {
        let suite = "problem-sheet-source-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let backupDirectory = directory.appendingPathComponent("backup", isDirectory: true)
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: backupDirectory))
        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: backupDirectory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil, uploader: MockUploader(), replacementJournal: journal)
        addTeardownBlock { await controller.shutdown() }
        return controller
    }

    /// An album controller with `album-1` selected; its last run counted one photo that needs attention.
    private func makeAlbumController() async throws -> AlbumSyncController {
        let mappings = try XCTUnwrap(
            AlbumSyncMappingStore(url: directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        XCTAssertTrue(mappings.addSelection(AlbumSyncSelection(localAlbumID: "album-1", title: "Trip", addedAt: date)))
        XCTAssertTrue(
            mappings.upsert(
                AlbumSyncMapping(
                    localAlbumID: "album-1", remoteAlbumID: "remote-1", title: "Trip", createdAt: date,
                    lastSyncedAt: date, lastFailedCount: 1)))
        mappings.close()
        let controller = AlbumSyncController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative),
            identityResolver: nil, uploader: MockUploader(),
            remoteOps: RecoveryScenarioRemote(server: EditScenarioServer()))
        addTeardownBlock { await controller.shutdown() }
        try await pollUntilOrFail { controller.selectedAlbumIDs.contains("album-1") }
        return controller
    }

    private let failed = BackupFailedItem(
        id: "failed", filename: "failed.heic", reason: "Reason", isPermanent: false, issue: .network)

    func testAnUnselectedAlbumDoesNotStartFollowingASession() async throws {
        let controller = try await makeAlbumController()
        let source = BackupProblemSheetSource.album(controller, albumID: "album-2")
        let session = source.makeSession()

        await source.follow(session, madeFor: source.id)

        XCTAssertFalse(session.hasRead, "an album outside the selection does not admit a problem-list read")
        XCTAssertFalse(session.isReading)
        await session.shutdown()
    }

    func testASessionMadeForAnotherSourceDoesNotStartFollowing() async throws {
        let controller = try await makeAlbumController()
        let source = BackupProblemSheetSource.album(controller, albumID: "album-1")
        let session = source.makeSession()

        await source.follow(session, madeFor: "another-source")

        XCTAssertFalse(session.hasRead, "a task for another source does not admit a problem-list read")
        XCTAssertFalse(session.isReading)
        await session.shutdown()
    }

    func testPresentationKeepsSourceSelectionAndSessionStatesInTheirExistingOrder() async throws {
        let controller = try await makeAlbumController()
        controller.recordFinishedRun([failed], albumID: "album-1")
        let selected = BackupProblemSheetSource.album(controller, albumID: "album-1")
        let removed = BackupProblemSheetSource.album(controller, albumID: "album-2")
        let backup = BackupProblemSheetSource.backup(try makeBackupController())
        let empty = BackupProblemListSession(read: { BackupProblemSnapshot(items: []) })
        XCTAssertTrue(selected.expectsItems)
        XCTAssertFalse(backup.expectsItems)
        XCTAssertEqual(selected.presentation(of: empty, madeFor: selected.id), .loading)
        XCTAssertEqual(backup.presentation(of: empty, madeFor: backup.id), .loading)
        XCTAssertEqual(removed.presentation(of: empty, madeFor: removed.id), .empty)
        XCTAssertEqual(removed.presentation(of: empty, madeFor: selected.id), .loading)

        empty.requestRefresh()
        await empty.waitUntilIdle()
        XCTAssertEqual(selected.presentation(of: empty, madeFor: selected.id), .unavailable)
        XCTAssertEqual(backup.presentation(of: empty, madeFor: backup.id), .empty)

        let unavailable = BackupProblemListSession(read: { nil })
        unavailable.requestRefresh()
        await unavailable.waitUntilIdle()
        XCTAssertEqual(backup.presentation(of: unavailable, madeFor: backup.id), .unavailable)

        var fails = false
        let populated = BackupProblemListSession(
            now: { 10 }, sleep: { _ in },
            read: { fails ? nil : BackupProblemSnapshot(items: [self.failed]) })
        populated.requestRefresh()
        await populated.waitUntilIdle()
        XCTAssertEqual(selected.presentation(of: populated, madeFor: selected.id), .list)
        XCTAssertEqual(selected.presentation(of: populated, madeFor: "another-source"), .loading)
        XCTAssertEqual(removed.presentation(of: populated, madeFor: removed.id), .empty)
        fails = true
        populated.requestRefresh()
        await populated.waitUntilIdle()
        XCTAssertTrue(populated.isUnavailable)
        XCTAssertEqual(selected.presentation(of: populated, madeFor: selected.id), .list)

        await empty.shutdown()
        await unavailable.shutdown()
        await populated.shutdown()
    }

    func testAnAlbumSessionListsItsRowsOnlyForItsOwnSelectedSource() async throws {
        let controller = try await makeAlbumController()
        controller.recordFinishedRun([failed], albumID: "album-1")
        let selected = BackupProblemSheetSource.album(controller, albumID: "album-1")
        let removed = BackupProblemSheetSource.album(controller, albumID: "album-2")
        XCTAssertEqual(selected.id, "album-\(ObjectIdentifier(controller))-album-1")
        XCTAssertNotEqual(selected.id, removed.id)
        XCTAssertTrue(selected.owns(selected.id))
        XCTAssertFalse(selected.owns(removed.id))
        XCTAssertTrue(removed.owns(removed.id), "ownership does not depend on the album selection")
        XCTAssertNil(selected.backupController)
        XCTAssertTrue(selected.isSelected)
        XCTAssertFalse(removed.isSelected)
        XCTAssertTrue(selected.expectsItems, "the last run counted a photo that needs attention")
        XCTAssertFalse(removed.expectsItems)

        let session = selected.makeSession()
        await selected.follow(session, madeFor: selected.id)
        XCTAssertEqual(session.rows.map(\.item.id), ["failed"])

        XCTAssertEqual(selected.items(of: session, madeFor: selected.id).map(\.id), ["failed"])
        XCTAssertEqual(
            selected.items(of: session, madeFor: removed.id), [],
            "a session that the sheet made for another source shows nothing")
        XCTAssertEqual(
            removed.items(of: session, madeFor: removed.id), [], "an album outside the selection lists nothing")
        XCTAssertFalse(selected.needsNewSession(session, madeFor: selected.id))
        XCTAssertTrue(
            selected.needsNewSession(session, madeFor: removed.id), "a swap to another source needs a session")
        await session.shutdown()
        XCTAssertTrue(selected.needsNewSession(session, madeFor: selected.id), "a retired session is replaced")
    }

    func testTheAlbumFollowKeyChangesWithANewSessionAndANewProblemList() async throws {
        let controller = try await makeAlbumController()
        let source = BackupProblemSheetSource.album(controller, albumID: "album-1")
        let session = source.makeSession()
        let before = source.followKey(for: session)
        XCTAssertEqual(source.followKey(for: session), before, "the key is stable while nothing changes")
        let anotherSession = source.makeSession()
        XCTAssertNotEqual(source.followKey(for: anotherSession), before)
        let anotherSource = BackupProblemSheetSource.album(controller, albumID: "album-2")
        XCTAssertNotEqual(
            anotherSource.followKey(for: session), before, "another source follows even with the same session")

        controller.recordFinishedRun([failed], albumID: "album-1")

        XCTAssertNotEqual(source.followKey(for: session), before, "a new problem list of the album follows again")
        await session.shutdown()
        await anotherSession.shutdown()
    }

    #if DEBUG
        func testTheBackupSourceFollowsItsListAndItsKeyChangesWithTheBackupStatus() async throws {
            let controller = try makeBackupController()
            let source = BackupProblemSheetSource.backup(controller)
            XCTAssertEqual(source.id, "backup-\(ObjectIdentifier(controller))")
            XCTAssertTrue(source.backupController === controller)
            XCTAssertTrue(source.isSelected, "the backup is always the listed source")
            XCTAssertFalse(source.expectsItems, "a new backup counts no photo that needs attention")
            let session = source.makeSession()
            let before = source.followKey(for: session)

            XCTAssertTrue(controller.installFailedItemsFixtureForTesting(kinds: [.unsupported]))

            // The status follows the queue asynchronously.
            try await pollUntilOrFail { source.expectsItems }
            XCTAssertTrue(source.expectsItems, "the backup now counts a photo that needs attention")
            XCTAssertNotEqual(source.followKey(for: session), before, "a new backup status follows again")
            let following = Task { await source.follow(session, madeFor: source.id) }
            try await pollUntilOrFail { session.hasRead && !session.isReading }
            following.cancel()
            await following.value
            XCTAssertEqual(source.items(of: session, madeFor: source.id).map(\.filename), ["unsupported fixture.heic"])
            XCTAssertEqual(source.items(of: session, madeFor: "another-source"), [])
            await session.shutdown()
        }
    #endif
}
