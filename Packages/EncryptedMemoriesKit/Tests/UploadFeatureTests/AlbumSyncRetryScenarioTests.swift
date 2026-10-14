import AlbumSyncCore
import CryptoKit
import Foundation
import XCTest

@testable import UploadCore

/// A retry of Album Sync keeps every photo that an earlier run added, adds every photo that can be added, and lists
/// only the photos whose backup could not finish.
final class AlbumSyncRetryScenarioTests: XCTestCase {
    func testRetriesKeepEveryAddedPhotoAndListOnlyTheBlockedPhoto() async throws {
        let device = try EditScenarioHarness()
        defer { try? device.cleanup() }
        for number in 2...4 {
            device.library.add("asset-\(number)", basename: "IMG_\(number)")
        }
        let assets = Dictionary(uniqueKeysWithValues: device.library.snapshot.map { ($0.identifier, $0) })
        // asset-3: a foreign draft with the same name and other bytes. It stays protected.
        let blockingDraft = device.server.seedDraft(
            name: "IMG_3.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("other-photo-3".utf8))),
            clientUID: "other-uploader")
        // asset-4: a foreign draft with the same name hides an active copy of the same bytes under another name.
        let hiddenCopy = device.server.seedLink(
            digest: Data(Insecure.SHA1.hash(data: try XCTUnwrap(assets["asset-4"]).current)))
        _ = device.server.seedDraft(
            name: "IMG_4.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("other-photo-4".utf8))),
            clientUID: "other-uploader")

        var reports: [AlbumSyncReport] = []
        var memberCounts: [Int] = []
        for _ in 0..<3 {
            reports.append(try await syncAlbum(on: device, identifiers: assets.keys.sorted()))
            memberCounts.append(try await device.server.childMainLinkIDs(albumID: "own-album").count)
        }

        XCTAssertEqual(reports.map(\.attached), [3, 0, 0])
        XCTAssertEqual(reports.map(\.alreadyMember), [0, 3, 3])
        XCTAssertEqual(memberCounts, [3, 3, 3], "A retry never loses a photo that an earlier run added")
        XCTAssertEqual(reports.map(\.unattachable), [1, 1, 1])
        XCTAssertEqual(reports.map(\.incomplete), [0, 0, 0])
        for report in reports {
            XCTAssertEqual(report.problems.map(\.source?.identifier), ["asset-3"])
            XCTAssertEqual(report.problems.first?.issue, .remoteDraft)
        }
        let members = try await device.server.childMainLinkIDs(albumID: "own-album")
        XCTAssertTrue(members.contains(hiddenCopy.nodeID))
        XCTAssertEqual(device.server.links.first { $0.uid == blockingDraft }?.state, .draft)
        XCTAssertEqual(device.server.uploadRequestCount, 2, "Only asset-1 and asset-2 upload, each once")
    }

    /// One Album Sync of the scenario album with the real runner, manifest lookup and mapping store.
    private func syncAlbum(on device: EditScenarioHarness, identifiers: [String]) async throws -> AlbumSyncReport {
        let album = LocalAlbumSummary(id: "local-album", title: "Scenario album", assetCount: identifiers.count)
        let lookup = try XCTUnwrap(
            UploadManifestRemoteLinkLookup(
                manifestURL: device.directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName),
                policy: .conservative))
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(
                url: device.directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        defer { mapping.close() }
        let runner = AlbumSyncRunner(
            localSource: RetryAlbumSource(identifiers: identifiers),
            backup: RetryAlbumBackup(device: device),
            remoteOps: device.server, linkLookup: lookup, mappingStore: mapping)
        do {
            let report = try await runner.sync(album: album, resolution: .attachToExisting(remoteAlbumID: "own-album"))
            await lookup.shutdown()
            return report
        } catch {
            await lookup.shutdown()
            throw error
        }
    }
}

private struct RetryAlbumSource: AlbumSyncLocalAlbumSource {
    let identifiers: [String]
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents { .present(identifiers) }
}

/// Like the album executor, each run starts with an empty queue and backup state, so every photo of the album goes
/// through the duplicate check again. Then it reports the unresolved album rows.
private final class RetryAlbumBackup: AlbumSyncBackupExecuting, @unchecked Sendable {
    let device: EditScenarioHarness
    init(device: EditScenarioHarness) { self.device = device }

    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        try device.resetAlbumSyncScratch(localIdentifiers)
        try await device.enqueue()
        await device.pass()
        let album = Set(localIdentifiers)
        var problems: [String: BackupFailedItem] = [:]
        device.queue.forEachProblemEntry { entry in
            if entry.source.kind == .photoLibraryAsset, album.contains(entry.source.identifier),
                problems[entry.source.identifier] == nil
            {
                problems[entry.source.identifier] = BackupFailedItem(entry: entry)
            }
            return true
        }
        return AlbumSyncBackupReport(
            total: localIdentifiers.count, backedUp: localIdentifiers.count - problems.count,
            failed: problems.count, sourceMissing: 0, skippedRemoteDeletion: 0, problems: problems)
    }

    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await AlbumSyncRemoteProofLookup.remoteLinks(
            for: localIdentifiers, catalog: device.library, queue: device.queue, resolver: device.identityResolver)
    }

    func stop() async {}
}
