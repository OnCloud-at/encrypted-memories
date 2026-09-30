import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

private actor SeededBackupLibrarySupportSource: LibrarySyncSupportSource {
    func librarySyncSupportSnapshot(now: Date) -> LibrarySyncSupportSnapshot? {
        LibrarySyncSupportSnapshot(
            lastSuccessfulLoad: .init(timestamp: now, sourcePath: .cache),
            lastFailedLoad: .init(timestamp: now, sourcePath: .authoritative, errorKind: .network),
            storedEventCursorAgeSeconds: 60, storedPhotoCount: 4, listedPhotoCount: 5,
            photosTrashedHereAwaitingLibrary: 1)
    }
}

final class BackupSupportDiagnosticsTests: XCTestCase {
    func testSeededStoresExportCountsWithoutPrivateContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = SupportDiagnosticsSources()
        let library = SeededBackupLibrarySupportSource()
        sources.registerLibrary(library)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        defer { queue.close() }
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        sources.registerQueue(queue, key: "private-store-path")
        sources.registerEditReplacements(journal, key: "private-journal-path")
        let now = Date()
        let privateValues = [
            "private-asset", "private-file.jpg", "/private/person/photo", "private-node", "private-volume",
            "Seed Person", "seed@example.invalid",
        ]
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: privateValues[0])
        let rows: [(UploadBackupSyncQueueState, UploadSourceIdentity.Resource, BackupIssueKind?)] = [
            (.discovered, .primary, nil),
            (.queuedForUpload, .livePairedVideo, .network),
            (.blockedByDraft, .photoKit(role: "fullSizePhoto", ordinal: 0), .remoteDraft),
            (.failedPermanent, .init(rawValue: privateValues[2]), .permission),
            (.needsRemoteReconciliation, .primary, .localState),
            (.failed, .primary, nil),
        ]
        for (index, row) in rows.enumerated() {
            let issue = row.2.map { BackupIssueRecord(kind: $0, detail: privateValues.joined(separator: " ")) }
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: UploadSourceIdentity(
                            kind: row.0 == .failed ? .fileURL : source.kind,
                            identifier: row.0 == .failed ? privateValues[2] : source.identifier,
                            resource: row.1),
                        revision: .init(rawValue: Int64(index)), originalFilename: privateValues[1],
                        state: row.0, lastError: row.0 == .failed ? privateValues[2] : issue?.persistedValue,
                        updatedAt: now)))
        }
        try journal.addSuperseded(PhotoUID(volumeID: privateValues[4], nodeID: privateValues[3]), for: source)
        try journal.addSuperseded(PhotoUID(volumeID: privateValues[4], nodeID: "private-retired"), for: source)
        try journal.settle(["private-retired"], related: ["private-related"], trashed: true, for: source)
        try journal.prepareToRetire([privateValues[3]: ["private-intent"]], for: source)

        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(report["librarySync"] as? [String: Any])
        let backup = try XCTUnwrap(report["backup"] as? [String: Any])
        let queues = try XCTUnwrap(backup["queues"] as? [[String: Any]])
        let snapshot = try XCTUnwrap(queues.first)
        XCTAssertEqual(snapshot["total"] as? Int, 6)
        XCTAssertEqual(snapshot["isAvailable"] as? Bool, true)
        let states = try XCTUnwrap(snapshot["countsByState"] as? [[String: Any]])
        XCTAssertEqual(states.first { $0["state"] as? String == "blockedByDraft" }?["count"] as? Int, 1)
        let resources = try XCTUnwrap(snapshot["countsByResourceKind"] as? [[String: Any]])
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "primary" }?["count"] as? Int, 3)
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "other" }?["count"] as? Int, 1)
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "fullSizePhoto" }?["count"] as? Int, 1)
        let waiting = try XCTUnwrap(snapshot["waitingByReason"] as? [[String: Any]])
        XCTAssertEqual(waiting.first { $0["reason"] as? String == "network" }?["count"] as? Int, 1)
        XCTAssertEqual(waiting.first { $0["reason"] as? String == "unclassified" }?["count"] as? Int, 1)
        let parked = try XCTUnwrap(snapshot["parkedByReason"] as? [[String: Any]])
        XCTAssertEqual(parked.first { $0["reason"] as? String == "permission" }?["count"] as? Int, 1)
        let replacements = try XCTUnwrap(backup["editReplacements"] as? [[String: Any]])
        XCTAssertEqual(replacements.first?["sourcesWithSupersededEntries"] as? Int, 1)
        XCTAssertEqual(replacements.first?["totalSuperseded"] as? Int, 1)
        XCTAssertEqual(replacements.first?["totalRetired"] as? Int, 2)
        XCTAssertEqual(replacements.first?["rowsWithRetireIntent"] as? Int, 1)
        withExtendedLifetime(library) {}
        let text = String(decoding: data, as: UTF8.self)
        for value in privateValues + [
            "private-retired", "private-related", "private-intent", "private-store-path", "private-journal-path",
        ] {
            XCTAssertFalse(text.contains(value), value)
        }
    }

    func testClosedQueueIsUnavailableInsteadOfEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        queue.close()
        XCTAssertFalse(queue.backupSupportSnapshot().isAvailable)
    }
}
