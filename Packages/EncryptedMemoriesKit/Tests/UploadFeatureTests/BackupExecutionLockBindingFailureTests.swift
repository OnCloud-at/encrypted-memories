import Foundation
import PhotosCore
import SQLite3
import SQLiteTestSupport
import XCTest

@testable import UploadCore

/// Every text bind of the backup execution lock checks its result (#1194). A failed bind leaves its parameter NULL, and
/// `lock_name` is a nullable primary key. An unchecked lock-name bind in the read made a contender see no lock, take
/// the holder's row and report the lock as acquired while another run held it. An unchecked bind in the write stored
/// its row under a NULL name, so the next run also saw no lock. The guard tests fail only the binds of one statement
/// through `BindFailureUntilStep`, because SQLITE_NOMEM need not fail both statements.
final class BackupExecutionLockBindingFailureTests: XCTestCase {
    /// The lock statements prepare and the contender's row fits under this limit; only the longer lock name fails.
    private static let limit: Int32 = 128
    private let longName = String(repeating: "l", count: 300)

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("backup-execution-lock.sqlite") }

    private func store(lockName: String = "photoBackup") throws -> BackupExecutionLockManifestStore {
        try XCTUnwrap(BackupExecutionLockManifestStore(url: databaseURL, lockName: lockName))
    }

    private func holdLock(name: String) throws -> BackupExecutionLockManifestStore {
        let holder = try store(lockName: name)
        guard case .acquired = holder.acquire(owner: .foreground, runID: "a", phase: nil, processContext: nil) else {
            XCTFail("The first run must hold the lock")
            return holder
        }
        return holder
    }

    /// Every stored lock row, read through a separate connection.
    private func storedRows() throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle, "SELECT ifnull(lock_name, 'NULL') || '/' || run_id FROM backup_execution_lock ORDER BY 1;",
                -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }

    func testAcquireWithALockNameThatDoesNotBindIsUnavailableWhileAnotherRunHoldsTheLock() throws {
        let holder = try holdLock(name: longName)
        defer { holder.close() }
        let before = try storedRows()
        let contender = try store(lockName: longName)
        defer { contender.close() }
        // The lock name fails to bind in the read and in the write.
        lowerSQLiteLengthLimit(on: try storeConnection(contender), to: Self.limit)

        let result = contender.acquire(owner: .background, runID: "b", phase: nil, processContext: nil)

        XCTAssertEqual(result, .unavailable, "A lock name that does not bind is no proof that the lock is free")
        XCTAssertEqual(try storedRows(), before, "No second lock row may appear")
        assertRecordedBindFailure(on: try storeConnection(contender))
    }

    /// Only the read's lock-name bind fails. Before, the read saw no lock, and the write, whose bind succeeded, took
    /// the holder's row.
    func testAcquireWhoseReadAloneDoesNotBindIsUnavailableAndKeepsTheHoldersRow() throws {
        let holder = try holdLock(name: longName)
        defer { holder.close() }
        let before = try storedRows()
        let contender = try store(lockName: longName)
        defer { contender.close() }
        // The limit is restored when the read steps, after its bind and before the write binds.
        let fault = BindFailureUntilStep(
            on: try storeConnection(contender), statement: "SELECT owner, run_id", after: nil, limit: Self.limit)
        defer { fault.remove() }

        let result = contender.acquire(owner: .background, runID: "b", phase: nil, processContext: nil)

        XCTAssertEqual(result, .unavailable, "A read whose lock name does not bind is no proof that the lock is free")
        XCTAssertFalse(fault.stepped, "A read whose bind failed must not run")
        XCTAssertEqual(try storedRows(), before, "The holder keeps its row")
        assertRecordedBindFailure(on: try storeConnection(contender))
    }

    /// Only the write's lock-name bind fails. Before, the write stored a row under a NULL name and reported the lock as
    /// acquired.
    func testAcquireWhoseWriteAloneDoesNotBindIsUnavailableAndStoresNoRow() throws {
        let contender = try store(lockName: longName)
        defer { contender.close() }
        // The limit is lowered when the read ends and restored when the write steps.
        let fault = BindFailureUntilStep(
            on: try storeConnection(contender), statement: "INSERT INTO backup_execution_lock",
            after: "SELECT owner, run_id", limit: Self.limit)
        defer { fault.remove() }

        let result = contender.acquire(owner: .background, runID: "b", phase: nil, processContext: nil)

        XCTAssertEqual(result, .unavailable, "A write whose lock name does not bind must not acquire the lock")
        XCTAssertTrue(fault.lowered, "The fault reached the write")
        XCTAssertFalse(fault.stepped, "A write whose bind failed must not run")
        XCTAssertEqual(try storedRows(), [], "No row may be stored under a NULL name")
        assertRecordedBindFailure(on: try storeConnection(contender))
    }

    /// The process context fails to bind. Before, the lock was acquired with a NULL context, which the abandoned-process
    /// recovery cannot read; now the acquisition fails and stores nothing.
    func testAcquireWithAProcessContextThatDoesNotBindIsUnavailable() throws {
        let contender = try store()
        defer { contender.close() }
        let fault = BindFailureUntilStep(
            on: try storeConnection(contender), statement: "INSERT INTO backup_execution_lock", after: nil,
            limit: Self.limit)
        defer { fault.remove() }

        let result = contender.acquire(
            owner: .background, runID: "b", phase: nil, processContext: String(repeating: "p", count: 300))

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(fault.stepped, "A write whose bind failed must not run")
        XCTAssertEqual(try storedRows(), [])
        assertRecordedBindFailure(on: try storeConnection(contender))
    }
}
