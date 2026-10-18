import Foundation
import SQLite3

/// Owns an already-verified store handle. Opening and connection tuning stay in SQLiteStoreSchemaGate.
/// Access the handle and failure state only inside `withLock`. Finalize each statement before that closure returns.
/// `close` and `isOperational` take the same nonrecursive lock; do not call them inside `withLock`.
public final class SQLiteStoreConnection: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var database: OpaquePointer?
    public private(set) var operationFailed = false

    public init(database: OpaquePointer) {
        self.database = database
    }

    deinit { close() }

    public func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }

    /// Call inside `withLock`. Failure stays recorded for the lifetime of this connection.
    public func markFailed() {
        operationFailed = true
    }

    /// Records a predicate under `withLock`. A prior failure does not change a later successful predicate.
    /// The shared type deliberately requires `database != nil`; the old helper returned the condition unchanged.
    /// Album and catalog conditions derive from SQLite; a nil handle yields MISUSE and fails those conditions.
    /// Their caller results stay unchanged. Audit non-SQL conditions before migrating another store.
    /// The old helper could return true after close. The shared type rejects that case.
    /// The operational probe remains false after any recorded failure.
    @discardableResult
    public func requireOperational(_ condition: Bool) -> Bool {
        let succeeded = database != nil && condition
        if !succeeded { markFailed() }
        return succeeded
    }

    public func isOperational() -> Bool {
        withLock {
            guard database != nil, !operationFailed else { return false }
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

    public func close() {
        withLock {
            guard database != nil else { return }
            sqlite3_exec(database, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(database)
            database = nil
        }
    }
}
