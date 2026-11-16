import Foundation
import SQLite3
import XCTest

@testable import UploadCore

final class UploadBackupStateTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func source(_ id: String = "cloud-asset-1") -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id)
    }

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func snapshot(
        id: String = "cloud-asset-1",
        revision seconds: TimeInterval,
        editRevision: UploadBackupEditRevision = .unavailable,
        resources: Int = 1
    ) -> UploadBackupAssetSnapshot {
        UploadBackupAssetSnapshot(
            source: source(id),
            revision: revision(seconds),
            editRevision: editRevision,
            resourceCount: resources
        )
    }

    func testStateStoreDefaultsKeepFullKeysAndDistinctRemovalPolicies() {
        let store = MemoryBackupStateStore(removesRecords: false)
        let old = UploadBackupAssetRecord(
            source: source(), revision: revision(5), resourceCount: 2, pendingResourceCount: 1,
            updatedAt: Date(timeIntervalSince1970: 101))
        let current = UploadBackupAssetRecord(
            source: source(), revision: revision(10), resourceCount: 2, pendingResourceCount: 0,
            updatedAt: Date(timeIntervalSince1970: 102))
        let video = UploadBackupAssetRecord(
            source: .init(kind: .photoLibraryAsset, identifier: source().identifier, resource: .livePairedVideo),
            revision: revision(10), resourceCount: 1, pendingResourceCount: 1,
            updatedAt: Date(timeIntervalSince1970: 103))
        let file = UploadBackupAssetRecord(
            source: .init(kind: .fileURL, identifier: source().identifier),
            revision: revision(10), resourceCount: 3, pendingResourceCount: 2,
            updatedAt: Date(timeIntervalSince1970: 104))
        let records = [old, current, video, file]
        XCTAssertTrue(store.upsertBatch(records))
        let snapshots = [
            snapshot(revision: 10, editRevision: .revision(revision(5)), resources: 2),
            snapshot(revision: 20, editRevision: .revision(revision(5)), resources: 2),
            UploadBackupAssetSnapshot(source: video.source, revision: video.revision, resourceCount: 1),
            UploadBackupAssetSnapshot(source: file.source, revision: file.revision, resourceCount: 3),
            snapshot(id: "missing", revision: 10),
        ]
        let read = store.lookupBatch(snapshots)
        XCTAssertEqual(read.map(\.succeeded), [true, true, true, true, true])
        XCTAssertEqual(read.map(\.directRecord), [current, nil, video, file, nil])
        XCTAssertEqual(read.map(\.editRecord), [old, old, nil, nil, nil])
        XCTAssertEqual(read.map(\.hasAnyRecord), [true, true, true, true, false])
        XCTAssertFalse(store.removeRecords(for: source(), keeping: []))
        XCTAssertEqual(store.count(), 4, "The default refusal must keep every stored revision")
        store.failWrites()
        let refused = UploadBackupAssetRecord(
            source: source(), revision: revision(30), resourceCount: 4, pendingResourceCount: 3,
            updatedAt: Date(timeIntervalSince1970: 105))
        XCTAssertFalse(store.upsertBatch([refused]))
        XCTAssertNil(store.record(for: refused.source, revision: refused.revision))
        XCTAssertEqual(store.count(), 4)

        let removable = MemoryBackupStateStore()
        XCTAssertTrue(removable.upsertBatch(records))
        XCTAssertTrue(removable.removeRecords(for: source(), keeping: [current.revision]))
        XCTAssertNil(removable.record(for: old.source, revision: old.revision))
        XCTAssertEqual(removable.record(for: current.source, revision: current.revision), current)
        XCTAssertEqual(removable.record(for: video.source, revision: video.revision), video)
        XCTAssertEqual(removable.record(for: file.source, revision: file.revision), file)
        XCTAssertEqual(removable.count(), 3)
    }

    func testDateRevisionsKeepTheirStoredQuantization() {
        let cases: [(Double, Int64, Int64)] = [
            (0, 0, 0),
            (1.5, 1_500_000, 1_500_000),
            (3_600, 3_600_000_000, 3_600_000_000),
            (2_592_000, 2_592_000_000_000, 2_592_000_000_000),
            (0.000_000_49, 0, 0),
            (0.000_000_5, 1, 0),
            (-0.000_000_5, -1, 0),
            (0.000_499_9, 500, 0),
            (0.000_5, 500, 1_000),
            (-0.000_5, -500, -1_000),
            (0.001_499_9, 1_500, 1_000),
            (0.001_5, 1_500, 2_000),
            (-0.001_5, -1_500, -2_000),
        ]
        for (seconds, microseconds, milliseconds) in cases {
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            XCTAssertEqual(UploadBackupRevision(date: date).rawValue, microseconds, "\(seconds)")
            XCTAssertEqual(
                UploadBackupExternalIdentity(identifier: "asset", modificationDate: date).revision.rawValue,
                milliseconds, "\(seconds)")
        }
    }

    func testNewAssetWhenSourceWasNeverSeen() async throws {
        let index = UploadBackupPreflightIndex(store: MemoryBackupStateStore(removesRecords: false))

        let result = try await index.classify(snapshot(revision: 10, resources: 2))

        XCTAssertEqual(result, .newAsset)
    }

    func testCompletedRevisionSkipsDirectly() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store, now: { Date(timeIntervalSince1970: 100) })
        let asset = snapshot(revision: 10, resources: 2)
        try await index.markBackedUp(asset)

        let result = try await index.classify(asset)

        XCTAssertEqual(result, .alreadyBackedUp)
        XCTAssertEqual(store.count(), 1)
    }

    func testPendingRevisionReportsRemainingResources() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        let asset = snapshot(revision: 10, resources: 2)
        try await index.markPending(asset, pendingResourceCount: 1)

        let result = try await index.classify(asset)

        XCTAssertEqual(result, .pendingUpload(remainingResources: 1))
    }

    func testMetadataRevisionDriftWithoutReliableEditEvidenceRequiresBackendCheck() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        try await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .unavailable)
        let result = try await index.classify(changed)

        XCTAssertEqual(result, .needsBackendCheck(.unreliableEditRevision))
        XCTAssertNil(store.record(for: changed.source, revision: changed.revision))
        XCTAssertEqual(store.count(), 1)
    }

    func testKnownEditRevisionSkipsAndSeedsCurrentRevision() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        let edit = revision(15)
        try await index.markBackedUp(snapshot(revision: 10))
        try await index.markBackedUp(snapshot(revision: 15))

        let changed = snapshot(revision: 20, editRevision: .revision(edit))
        let result = try await index.classify(changed)

        XCTAssertEqual(result, .alreadyBackedUp)
        XCTAssertNotNil(store.record(for: changed.source, revision: changed.revision))
    }

    func testUndoingAnEditThatReplacedTheEarlierUploadNeedsTheDuplicateCheckAgain() async throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        defer { store.close() }
        let index = UploadBackupPreflightIndex(store: store)
        // The unedited photo was backed up with this resource structure; the edit then replaced that upload.
        let original = revision(15)
        try await index.markBackedUp(snapshot(revision: 10, editRevision: .revision(original)))
        let edited = snapshot(revision: 20)
        try await index.markBackedUp(edited)

        try await index.forgetEarlierStates(of: edited)

        XCTAssertNotNil(store.record(for: edited.source, revision: edited.revision))
        let undone = try await index.classify(snapshot(revision: 30, editRevision: .revision(original)))
        XCTAssertEqual(
            undone, .needsBackendCheck(.unseenEditRevision),
            "the earlier upload moved to the trash, so the original structure is no longer backed up")
    }

    func testUnknownEditRevisionRequiresBackendCheck() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        try await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .revision(revision(18)))
        let result = try await index.classify(changed)

        XCTAssertEqual(result, .needsBackendCheck(.unseenEditRevision))
    }

    func testUnavailableEditRevisionRequiresBackendCheck() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        try await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .unavailable)
        let result = try await index.classify(changed)

        XCTAssertEqual(result, .needsBackendCheck(.unreliableEditRevision))
    }

    func testCompletionWriteFailureThrowsInsteadOfPublishingSuccess() async {
        let store = MemoryBackupStateStore(removesRecords: false)
        store.failWrites()
        let index = UploadBackupPreflightIndex(store: store)

        do {
            try await index.markBackedUp(snapshot(revision: 10))
            XCTFail("a failed state write must not be reported as complete")
        } catch {
            XCTAssertEqual(store.count(), 0)
        }
    }

    func testMetadataDriftClassificationFailsWhenSeedCannotPersist() async throws {
        let store = MemoryBackupStateStore(removesRecords: false)
        let index = UploadBackupPreflightIndex(store: store)
        try await index.markBackedUp(snapshot(revision: 10))
        store.failWrites()

        do {
            _ = try await index.classify(
                snapshot(revision: 20, editRevision: .revision(revision(10)))
            )
            XCTFail("a failed current-revision seed must not be silently accepted")
        } catch {
            XCTAssertNil(store.record(for: source(), revision: revision(20)))
        }
    }

    func testSQLiteStoreRoundTripsAndIndexesBySource() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        let record = UploadBackupAssetRecord(
            source: source(),
            revision: revision(10),
            resourceCount: 2,
            pendingResourceCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        store.upsert(record)

        XCTAssertEqual(store.record(for: source(), revision: revision(10)), record)
        let lookups = store.lookupBatch([snapshot(revision: 10), snapshot(id: "other", revision: 10)])
        XCTAssertEqual(lookups.map(\.succeeded), [true, true])
        XCTAssertEqual(lookups.map(\.hasAnyRecord), [true, false])
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
    }

    /// The SQLite store reads the record of a known edit revision that differs from the current revision.
    func testSQLiteStoreReadsTheRecordOfAnEditRevisionThatDiffersFromTheRevision() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        defer { store.close() }
        let earlier = UploadBackupAssetRecord(
            source: source(), revision: revision(15), resourceCount: 1, pendingResourceCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.upsert(earlier))

        let edited = snapshot(revision: 20, editRevision: .revision(revision(15)))
        let lookup = try XCTUnwrap(store.lookupBatch([edited]).first)

        XCTAssertTrue(lookup.succeeded)
        XCTAssertNil(lookup.directRecord)
        XCTAssertEqual(lookup.editRecord, earlier)
    }

    /// A write that SQLite refuses at its step is no stored record, also while the store stays open.
    func testSQLiteStoreReportsAWriteThatSQLiteRefuses() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        defer { store.close() }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TRIGGER refuse_state BEFORE INSERT ON backup_asset_state BEGIN SELECT RAISE(ABORT, 'refused'); END;",
                nil, nil, nil),
            SQLITE_OK)

        XCTAssertFalse(
            store.upsert(
                UploadBackupAssetRecord(
                    source: source(), revision: revision(10), resourceCount: 1, pendingResourceCount: 0,
                    updatedAt: Date())))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 0)
    }

    func testSQLiteStoreReportsWriteFailureAfterClose() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        store.close()

        XCTAssertFalse(
            store.upsert(
                UploadBackupAssetRecord(
                    source: source(),
                    revision: revision(10),
                    resourceCount: 1,
                    pendingResourceCount: 0,
                    updatedAt: Date()
                )))
    }

    func testSQLiteStoreReadFailureStopsPreflightInsteadOfTreatingAssetAsNew() async throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        store.close()
        let index = UploadBackupPreflightIndex(store: store)

        do {
            _ = try await index.classify(snapshot(revision: 10))
            XCTFail("a state DB read failure must not fall through to newAsset")
        } catch {
            XCTAssertEqual(store.lookupBatch([snapshot(revision: 10)]).first?.succeeded, false)
        }
    }

    func testClosePreservesRecordsWhenTheStoreReopens() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        let record = UploadBackupAssetRecord(
            source: source(), revision: revision(10), resourceCount: 2, pendingResourceCount: 1,
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.upsert(record))

        store.close()
        store.close()

        let closedRead = store.lookupBatch([snapshot(revision: 10)])
        XCTAssertEqual(closedRead.count, 1)
        XCTAssertEqual(closedRead.first?.succeeded, false)
        XCTAssertNil(closedRead.first?.directRecord)
        XCTAssertEqual(closedRead.first?.hasAnyRecord, false)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1, "Closing preserves the stored row")
        XCTAssertFalse(store.upsert(record))
        XCTAssertFalse(store.upsertBatch([record]))
        XCTAssertFalse(store.removeRecords(for: source(), keeping: []))

        let reopened = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(reopened.record(for: source(), revision: revision(10)), record)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
        XCTAssertEqual(reopened.lookupBatch([snapshot(revision: 10)]).first?.succeeded, true)
        XCTAssertTrue(reopened.removeRecords(for: source(), keeping: []))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 0)
    }

    func testEmptyBatchCallsPreserveOpenAndClosedStoreBehavior() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        let record = UploadBackupAssetRecord(
            source: source(), revision: revision(10), resourceCount: 2, pendingResourceCount: 1,
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.upsert(record))

        XCTAssertTrue(store.upsertBatch([]))
        XCTAssertTrue(store.lookupBatch([]).isEmpty)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
        XCTAssertEqual(store.record(for: source(), revision: revision(10)), record)
        XCTAssertTrue(store.upsertBatch([record]))
        XCTAssertEqual(store.lookupBatch([snapshot(revision: 10)]).first?.succeeded, true)

        store.close()

        XCTAssertTrue(store.upsertBatch([]))
        XCTAssertTrue(store.lookupBatch([]).isEmpty)
        XCTAssertFalse(store.upsertBatch([record]))
        XCTAssertEqual(store.lookupBatch([snapshot(revision: 10)]).first?.succeeded, false)

        let reopened = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
        XCTAssertEqual(reopened.record(for: source(), revision: revision(10)), record)
        XCTAssertTrue(reopened.upsert(record))
        XCTAssertEqual(reopened.lookupBatch([snapshot(revision: 10)]).first?.succeeded, true)
    }

    func testSQLiteStoreFailsClosedForFutureSchemaWithoutChangingMarker() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
            store.upsert(
                UploadBackupAssetRecord(
                    source: source(),
                    revision: revision(10),
                    resourceCount: 1,
                    pendingResourceCount: 0,
                    updatedAt: Date()
                ))
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_state_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupStateManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
        XCTAssertEqual(sqliteInteger(url: url, sql: "SELECT value FROM backup_state_info WHERE key='schema';"), 99)
    }

    func testSQLiteStoreRejectsMarkerlessWrongShapeWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE backup_asset_state(source_id TEXT); INSERT INTO backup_asset_state VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupStateManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_asset_state"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_state_info"), -1)
    }

    private func sqliteCount(url: URL, table: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    private func sqliteInteger(url: URL, sql: String) -> Int? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
