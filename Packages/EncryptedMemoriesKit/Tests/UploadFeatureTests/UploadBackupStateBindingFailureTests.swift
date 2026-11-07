import SQLite3
import XCTest

@testable import PhotosCore
@testable import UploadCore

/// Every text bind of the backup state store checks its result (#1194). A failed bind leaves its parameter NULL: an
/// unchecked bind made a lookup report "no backup state" as a successful read, and made a removal report success
/// without removing anything. Each test lowers SQLITE_LIMIT_LENGTH on the store's own connection and reads it back, so
/// an identifier longer than the limit fails its bind with SQLITE_TOOBIG. The lookup guard tests fail only the binds of
/// one statement through `BindFailureUntilStep`, because SQLITE_NOMEM need not fail both lookup statements.
final class UploadBackupStateBindingFailureTests: XCTestCase {
    /// The statements prepare and a row with a short identifier fits under this limit; only the longer identifier fails.
    private static let limit: Int32 = 128
    private let long = String(repeating: "x", count: 300)

    private var tempDir: URL!
    private var store: UploadBackupStateManifestStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-state-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try XCTUnwrap(UploadBackupStateManifestStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var databaseURL: URL { tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName) }

    private func connection() throws -> SQLiteStoreConnection { try storeConnection(store!) }

    private func lowerLengthLimit() throws { lowerSQLiteLengthLimit(on: try connection(), to: Self.limit) }

    private func assertBindFailureRecorded(file: StaticString = #filePath, line: UInt = #line) throws {
        assertRecordedBindFailure(on: try connection(), file: file, line: line)
    }

    /// Every stored row, read through a separate connection.
    private func storedRows() throws -> [[String]] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                """
                SELECT source_kind, source_id, resource, revision_us, resource_count, pending_resources, updated_at
                FROM backup_asset_state ORDER BY source_kind, source_id, resource, revision_us;
                """, -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<7).map { String(cString: sqlite3_column_text(statement, $0)) })
        }
        return rows
    }

    private func source(_ identifier: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier)
    }

    private func record(_ identifier: String, revision: Int64 = 10) -> UploadBackupAssetRecord {
        UploadBackupAssetRecord(
            source: source(identifier), revision: UploadBackupRevision(rawValue: revision), resourceCount: 1,
            pendingResourceCount: 0, updatedAt: Date(timeIntervalSince1970: 100))
    }

    func testLookupBatchWithAnIdentifierLongerThanTheLimitFails() throws {
        try lowerLengthLimit()
        let lookups = store.lookupBatch([
            UploadBackupAssetSnapshot(
                source: source(long), revision: UploadBackupRevision(rawValue: 10), resourceCount: 1)
        ])
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(
            lookups.first?.succeeded, false,
            "A key that does not bind is no proof that the photo has no backup state")
        try assertBindFailureRecorded()
    }

    func testRemoveRecordsWithAnIdentifierLongerThanTheLimitFails() throws {
        XCTAssertTrue(store.upsertBatch([record(long, revision: 10), record(long, revision: 20)]))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(
            store.removeRecords(for: source(long), keeping: [UploadBackupRevision(rawValue: 20)]),
            "A key that does not bind removes nothing; that is no successful removal")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testUpsertWithAnIdentifierLongerThanTheLimitFails() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.upsert(record(long)))
        XCTAssertEqual(try storedRows(), [])
        try assertBindFailureRecorded()
    }

    func testUpsertBatchWithAnIdentifierLongerThanTheLimitFailsAndKeepsEveryRow() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.upsertBatch([record("a"), record(long)]))
        XCTAssertEqual(try storedRows(), [], "The first row must roll back with the failed second one")
        try assertBindFailureRecorded()
    }

    func testRecordWithAnIdentifierLongerThanTheLimitRecordsTheFailure() throws {
        try lowerLengthLimit()
        XCTAssertNil(store.record(for: source(long), revision: UploadBackupRevision(rawValue: 10)))
        try assertBindFailureRecorded()
    }

    func testHasAnyRecordWithAnIdentifierLongerThanTheLimitRecordsTheFailure() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.hasAnyRecord(for: source(long)))
        try assertBindFailureRecorded()
    }

    private func snapshot(_ identifier: String, revision: Int64 = 10) -> UploadBackupAssetSnapshot {
        UploadBackupAssetSnapshot(
            source: source(identifier), revision: UploadBackupRevision(rawValue: revision), resourceCount: 1)
    }

    /// The exact-revision read fails to bind, while the any-revision read that follows binds. Before, the exact read
    /// answered "no record" and the any read found the photo's row, so a pending photo could look backed up under
    /// another revision and its pending resources might never upload.
    func testLookupWhoseExactReadAloneDoesNotBindFails() throws {
        XCTAssertTrue(store.upsert(record(long, revision: 10)))
        // The limit is restored when the exact read steps, after its binds and before the any read binds.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "SELECT resource_count, pending_resources, updated_at", after: nil,
            limit: Self.limit)
        defer { fault.remove() }
        let lookups = store.lookupBatch([snapshot(long)])
        XCTAssertEqual(lookups.first?.succeeded, false, "An exact read that does not bind is no answer")
        XCTAssertFalse(fault.stepped, "A read whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    /// The exact-revision read binds and finds nothing; the any-revision read then fails to bind. Before, it answered
    /// "no row of any revision", so the photo counted as a new asset.
    func testLookupWhoseAnyReadAloneDoesNotBindFails() throws {
        // The limit is lowered when the exact read ends and restored when the any read steps.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "SELECT 1 FROM backup_asset_state",
            after: "SELECT resource_count, pending_resources, updated_at", limit: Self.limit)
        defer { fault.remove() }
        let lookups = store.lookupBatch([snapshot(long)])
        XCTAssertEqual(lookups.first?.succeeded, false, "An any-revision read that does not bind is no answer")
        XCTAssertTrue(fault.lowered, "The fault reached the any-revision read")
        XCTAssertFalse(fault.stepped, "A read whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testSharedSourceBindingFailsAtKindWithoutStepping() throws {
        try assertSourceBindingFailure(at: 1)
    }

    func testSharedSourceBindingFailsAtIdentifierWithoutStepping() throws {
        try assertSourceBindingFailure(at: 2)
    }

    func testSharedSourceBindingFailsAtResourceWithoutStepping() throws {
        try assertSourceBindingFailure(at: 3)
    }

    /// Short enum values cannot exceed SQLite's effective length floor. Missing parameter slots instead fail each
    /// bind with SQLITE_RANGE, after every earlier field has bound successfully.
    private func assertSourceBindingFailure(at position: Int32) throws {
        let connection = try connection()
        let failuresBefore = connection.recordedFailureCount()
        let source = source("identifier")
        try connection.withLock {
            let parameters = (1...position).map { "?\($0)" }.joined(separator: ", ")
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT \(parameters);", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_bind_parameter_count(statement), position)
            try connection.bindText(statement, 1, "prefix")

            XCTAssertFalse(
                connection.bindUploadSource(source, to: statement, from: 2),
                "The out-of-range bind of field \(position) must return false")

            XCTAssertTrue(connection.operationFailed)
            XCTAssertEqual(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0), 0)
            let expanded = try XCTUnwrap(sqlite3_expanded_sql(statement))
            defer { sqlite3_free(expanded) }
            let values = ["prefix", source.kind.rawValue, source.identifier, source.resource.rawValue]
            let expected = values.prefix(Int(position)).map { "'\($0)'" }.joined(separator: ", ")
            XCTAssertEqual(String(cString: expanded), "SELECT \(expected);")
        }
        XCTAssertEqual(
            connection.recordedFailureCount(), failuresBefore + 1,
            "The shared binder must stop after the first failed field")
    }

    func testSharedSourceBindingKeepsOrderAndSurroundingParametersAtAnOffset() throws {
        let connection = try connection()
        let failuresBefore = connection.recordedFailureCount()
        let source = source("identifier")
        try connection.withLock {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT ?1, ?2, ?3, ?4, ?5;", -1, &statement, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try connection.bindText(statement, 1, "prefix")
            try connection.bindText(statement, 5, "suffix")

            XCTAssertTrue(connection.bindUploadSource(source, to: statement, from: 2))

            XCTAssertFalse(connection.operationFailed)
            XCTAssertEqual(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0), 0)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            let actual = (0..<5).map { index -> String? in
                guard let text = sqlite3_column_text(statement, Int32(index)) else { return nil }
                return String(cString: text)
            }
            XCTAssertEqual(
                actual, ["prefix", source.kind.rawValue, source.identifier, source.resource.rawValue, "suffix"])
        }
        XCTAssertEqual(connection.recordedFailureCount(), failuresBefore)
    }
}
