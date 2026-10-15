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

    func testOnlyADatabaseThatAnotherConnectionLocksCountsAsHeld() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertFalse(SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: missing), "a missing file is not held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "the check creates no file")

        let text = directory.appendingPathComponent("text.sqlite")
        try Data("not a database".utf8).write(to: text)
        XCTAssertFalse(
            SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: text), "a file that is no database is not held")

        let database = directory.appendingPathComponent("held.sqlite")
        var owner: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &owner), SQLITE_OK)
        defer { sqlite3_close(owner) }
        XCTAssertEqual(sqlite3_exec(owner, "CREATE TABLE marker (value INTEGER);", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(
            SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: database),
            "a readable database without a lock is not held")

        XCTAssertEqual(sqlite3_exec(owner, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(owner, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: database), "an exclusive lock holds the file")
        XCTAssertEqual(sqlite3_exec(owner, "COMMIT;", nil, nil, nil), SQLITE_OK)
    }

    /// A rollback journal that a crashed writer left behind needs a writer to recover it. A read-only check cannot
    /// recover it and does not count the file as held, so the store replaces such a cache as before.
    func testADatabaseWithAHotRollbackJournalDoesNotCountAsHeld() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for statement in [
            "PRAGMA journal_mode=DELETE;", "PRAGMA synchronous=FULL;", "CREATE TABLE t (x BLOB);",
            "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000) "
                + "INSERT INTO t SELECT randomblob(500) FROM c;",
            "PRAGMA cache_size=2;", "PRAGMA cache_spill=1;", "BEGIN;", "UPDATE t SET x = randomblob(500);",
        ] {
            XCTAssertEqual(sqlite3_exec(writer, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        // A copy taken while the write runs is what a crash leaves: changed pages and the journal that undoes them.
        let crashed = directory.appendingPathComponent("crashed.sqlite")
        try FileManager.default.copyItem(at: source, to: crashed)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.path + "-journal"), to: URL(fileURLWithPath: crashed.path + "-journal"))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: crashed.path + "-journal")).read(upToCount: 8)
        XCTAssertEqual(header, Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]), "the journal is hot")

        XCTAssertFalse(SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: crashed), "a hot journal is no hold")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: crashed.path + "-journal"), "the read-only check recovers nothing")
    }

    /// A WAL database whose shared-memory file cannot be created cannot be opened for now. It does not count as held.
    func testAWALDatabaseWithoutAWritableSharedMemoryFileDoesNotCountAsHeld() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for statement in [
            "PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;", "CREATE TABLE t (x INTEGER);",
            "INSERT INTO t VALUES (1);",
        ] {
            XCTAssertEqual(sqlite3_exec(writer, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let copy = locked.appendingPathComponent("copy.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.path + "-wal"), to: URL(fileURLWithPath: copy.path + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "-shm"), "no shared-memory file exists")

        XCTAssertFalse(SQLiteStoreSchemaGate.isHeldByAnotherConnection(at: copy), "an unopenable file is no hold")
    }
}
