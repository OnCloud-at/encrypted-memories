import Foundation
import SQLite3

/// Owns an already-verified store handle. Opening and connection tuning stay in SQLiteStoreSchemaGate.
/// Access the handle and failure state only inside `withLock`. Finalize each statement before that closure returns.
/// `close` and `isOperational` take the same nonrecursive lock; do not call them inside `withLock`.
public final class SQLiteStoreConnection: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var database: OpaquePointer?
    public private(set) var operationFailed = false
    /// False once a recorded failure was not transient, see `transientResultCodes`.
    public private(set) var failuresAreTransient = true
    private let optimizesOnClose: Bool

    /// The primary SQLite result codes after which the same call can succeed when it runs again: the database was
    /// busy or locked, memory or disk space ran out, an I/O call failed, or the call was interrupted. Every other code,
    /// for example a corrupt database, a file that is no database, a read-only file, a schema change, a constraint or a
    /// misuse, and an unknown cause mean that the database itself may be wrong.
    public static let transientResultCodes: Set<Int32> = [
        SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_INTERRUPT, SQLITE_IOERR, SQLITE_FULL,
    ]
    /// Extended I/O codes that report damaged data, not a passing failure: SQLITE_IOERR_DATA and
    /// SQLITE_IOERR_CORRUPTFS.
    public static let corruptionResultCodes: Set<Int32> = [SQLITE_IOERR | (32 << 8), SQLITE_IOERR | (33 << 8)]

    /// Set optimizesOnClose to false only to preserve a store that never ran `PRAGMA optimize` on close.
    public init(database: OpaquePointer, optimizesOnClose: Bool = true) {
        self.database = database
        self.optimizesOnClose = optimizesOnClose
    }

    deinit { close() }

    public func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }

    /// Call inside `withLock`. Failure stays recorded for the lifetime of this connection, unless the store checks
    /// with `isOperationalAfterRecovery()`.
    public func markFailed() {
        markFailed(resultCode: nil)
    }

    /// Call inside `withLock` with the result code of the failed call, extended or primary; nil for an unknown cause.
    public func markFailed(resultCode: Int32?) {
        operationFailed = true
        let transient = resultCode.map {
            Self.transientResultCodes.contains($0 & 0xFF) && !Self.corruptionResultCodes.contains($0)
        }
        if transient != true { failuresAreTransient = false }
    }

    /// Call inside `withLock`. Ends the open transaction. Only a transaction that stays open records a failure: after a
    /// full disk, an I/O error, an interrupt or no memory, SQLite can roll back on its own, and the explicit rollback
    /// then fails without harm.
    public func rollBack() {
        guard let database else { return }
        let rollback = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
        if sqlite3_get_autocommit(database) == 0 {
            markFailed(resultCode: rollback == SQLITE_OK ? nil : sqlite3_extended_errcode(database))
        }
    }

    /// Records a predicate under `withLock`. A prior failure does not change a later successful predicate.
    /// The shared type deliberately requires `database != nil`; the old helper returned the condition unchanged.
    /// Album/catalog conditions are SQL-derived; audited queue conditions are SQL-derived or literal false.
    /// A nil handle fails these conditions, preserving closed-store results; audit other stores before migration.
    /// The old helper could return true after close. The shared type rejects that case.
    /// The operational probe remains false after any recorded failure.
    @discardableResult
    public func requireOperational(_ condition: Bool) -> Bool {
        let succeeded = database != nil && condition
        if !succeeded { markFailed() }
        return succeeded
    }

    public func isOperational() -> Bool { isOperational(probeDatabase: true) }

    /// Set probeDatabase to false only to preserve a store's existing state-only operational check.
    public func isOperational(probeDatabase: Bool) -> Bool {
        withLock {
            guard database != nil, !operationFailed else { return false }
            guard probeDatabase else { return true }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT 1;", -1, &statement, nil) == SQLITE_OK else {
                markFailed()
                return false
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                markFailed()
                return false
            }
            return true
        }
    }

    /// For a store whose transient failure stops it only until the database answers again. A transaction that a
    /// failed rollback left open stops the store. After recorded failures that were all transient, reads a page of the
    /// database and forgets the failures when it answers. Each call still fails on its own. Any other failure, and a
    /// closed connection, stay recorded.
    public func isOperationalAfterRecovery() -> Bool {
        withLock {
            guard database != nil else { return false }
            guard sqlite3_get_autocommit(database) != 0 else { return false }
            guard operationFailed else { return true }
            guard failuresAreTransient else { return false }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_schema;", -1, &statement, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW
            else { return false }
            operationFailed = false
            return true
        }
    }

    public func close() {
        withLock {
            guard database != nil else { return }
            if optimizesOnClose { sqlite3_exec(database, "PRAGMA optimize;", nil, nil, nil) }
            sqlite3_close(database)
            database = nil
        }
    }
}
