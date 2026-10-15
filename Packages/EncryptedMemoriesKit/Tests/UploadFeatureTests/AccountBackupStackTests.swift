import AlbumSyncCore
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import UploadCore
import XCTest

@MainActor
final class AccountBackupStackTests: XCTestCase {
    func testTheStackOpensTheStoreAndBuildsBothControllersForTheAccount() async throws {
        let directory = try makeAccountDirectory()
        let stack = makeStack(directory)

        let store = try XCTUnwrap(stack.pendingStore, "the pending store opens in the account folder")
        XCTAssertTrue(store.isOperational())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path))
        XCTAssertNotNil(stack.photoBackup.pendingRecorder, "the photo backup records into that store")
        XCTAssertTrue(stack.photoBackup.isAvailable)
        XCTAssertTrue(stack.albumSync.isAvailable)

        await stack.shutdownUnused()
    }

    /// Without readable exclusions a photo that the person deleted before its upload could upload, so a missing store
    /// keeps the photo backup from running.
    func testAMissingStorePreventsBackup() async throws {
        let directory = try makeAccountDirectory()
        // A file where the store's database belongs makes the store fail to open.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName),
            withIntermediateDirectories: true)
        let stack = makeStack(directory)

        XCTAssertNil(stack.pendingStore)
        XCTAssertNil(stack.photoBackup.pendingRecorder)
        XCTAssertFalse(stack.photoBackup.isAvailable, "backup refuses to run without its pending store")

        await stack.shutdownUnused()
    }

    /// A load that was cancelled or replaced closes the stack it built: the photo backup, then its store, then album
    /// sync. Nothing of it stays open for the next account.
    func testAStackThatNeverReachedTheAccountClosesEverything() async throws {
        let directory = try makeAccountDirectory()
        let stack = makeStack(directory)
        let store = try XCTUnwrap(stack.pendingStore)

        await stack.shutdownUnused()

        XCTAssertFalse(store.isOperational(), "the pending store is closed")
        XCTAssertFalse(stack.photoBackup.isAvailable, "the photo backup is shut down")
        XCTAssertFalse(stack.albumSync.isAvailable, "album sync is shut down")
    }

    /// Replacing the account builds a new stack in the new account's folder; the earlier one is untouched until its
    /// owner closes it.
    func testTwoAccountsGetIndependentStacks() async throws {
        let first = makeStack(try makeAccountDirectory())
        let second = makeStack(try makeAccountDirectory())
        let firstStore = try XCTUnwrap(first.pendingStore)
        let secondStore = try XCTUnwrap(second.pendingStore)
        XCTAssertFalse(firstStore === secondStore)

        await first.shutdownUnused()
        XCTAssertFalse(firstStore.isOperational())
        XCTAssertTrue(secondStore.isOperational(), "closing one account's stack leaves the other open")
        XCTAssertTrue(second.photoBackup.isAvailable)

        await second.shutdownUnused()
    }

    private func makeStack(_ directory: URL) -> AccountBackupStack {
        AccountBackupStack(
            accountDataDirectory: directory, databasePolicy: .conservative, identityResolver: nil,
            uploader: MockUploader(), tagAdder: nil, editReplacement: nil, albumOperations: NoRemoteAlbums())
    }

    private func makeAccountDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-backup-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct NoRemoteAlbums: AlbumSyncRemoteAlbumOps {
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
    func createAlbum(name: String) async throws -> String { "remote-1" }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        AlbumSyncAttachResult()
    }
}
