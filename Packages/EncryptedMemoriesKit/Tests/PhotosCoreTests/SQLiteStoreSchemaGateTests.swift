import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteStoreSchemaGateTests: XCTestCase {
    func testRollbackJournalCommitsCanSynchronizeWhenWALIsUnavailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE marker (value INTEGER);", nil, nil, nil), SQLITE_OK)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &reader), SQLITE_OK)
        // A reader prevents the WAL transition, as on a store where WAL is unavailable.
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT * FROM marker;", nil, nil, nil), SQLITE_OK)
        SQLiteStoreSchemaGate.configureConnection(
            db, policy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 10))
        sqlite3_close(reader)
        XCTAssertEqual(try pragma("journal_mode", in: db), "delete")
        XCTAssertGreaterThanOrEqual(Int(try pragma("synchronous", in: db)) ?? 0, 2)
        XCTAssertEqual(try pragma("fullfsync", in: db), "1")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO marker VALUES (1);", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(SQLiteStoreSchemaGate.checkpointCompletely(db))

        XCTAssertEqual(sqlite3_exec(db, "BEGIN; INSERT INTO marker VALUES (3);", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "uncommitted rows cannot move the token")
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let before = try pragma("synchronous", in: db)
        XCTAssertEqual(
            SQLiteStoreSchemaGate.withDurableCommits(db) {
                sqlite3_exec(db, "INSERT INTO marker VALUES (2);", nil, nil, nil)
            }, SQLITE_OK)
        XCTAssertEqual(try pragma("synchronous", in: db), before)
        XCTAssertEqual(try pragma("fullfsync", in: db), "1")
        XCTAssertTrue(SQLiteStoreSchemaGate.checkpointCompletely(db))

        XCTAssertEqual(sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "a non-durable commit cannot move the token")
    }

    func testSynchronizationRejectsMemoryAndMissingConnections() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "an in-memory database is not durable")
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(nil))
    }

    private func pragma(_ name: String, in db: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    func testOpenCurrentStoreCreatesReopensAndRejectsIncompatibleFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaGate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let schema = "CREATE TABLE marker (version INTEGER NOT NULL);"
        func verify(_ db: OpaquePointer?) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT version FROM marker;", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
        }
        func stamp(_ db: OpaquePointer?) -> Bool {
            sqlite3_exec(db, "INSERT INTO marker VALUES (1);", nil, nil, nil) == SQLITE_OK
        }
        let first = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(first))
        sqlite3_close(first)

        let reopened = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(reopened))
        XCTAssertEqual(sqlite3_exec(reopened, "UPDATE marker SET version = 2;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(reopened)

        XCTAssertNil(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        var inspection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &inspection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(inspection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(inspection, "SELECT version FROM marker;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
    }
}
