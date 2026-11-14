import PhotosCore
import SQLite3
import XCTest

/// Lowers SQLITE_LIMIT_LENGTH on a store's own connection and reads it back, so the test fails unless the lowered limit
/// applies. A bind of a longer value then fails with SQLITE_TOOBIG, as a bind that runs out of memory does.
func lowerSQLiteLengthLimit(
    on connection: SQLiteStoreConnection, to limit: Int32, message: String = "The lowered length limit must apply",
    file: StaticString = #filePath, line: UInt = #line
) {
    connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
    let effective = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) }
    XCTAssertEqual(effective, limit, message, file: file, line: line)
}

/// Fails the test unless the connection recorded a lasting failure, as a failed bind records SQLITE_TOOBIG.
func assertRecordedBindFailure(
    on connection: SQLiteStoreConnection, file: StaticString = #filePath, line: UInt = #line
) {
    connection.withLock {
        XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded", file: file, line: line)
        XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure", file: file, line: line)
    }
}
