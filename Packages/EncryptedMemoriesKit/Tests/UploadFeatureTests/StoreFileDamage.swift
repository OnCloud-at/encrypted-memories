import Foundation
import SQLite3
import XCTest

/// A stored key that is not the exact text of an identifier: NULL, INTEGER, REAL, BLOB, text that is not valid UTF-8,
/// or text with a NUL byte.
enum DamagedKey: CaseIterable {
    case null, integer, real, blob, invalidUTF8, nulByte

    /// The SQL value. A column without a declared type keeps its storage class.
    var sql: String {
        switch self {
        case .null: "NULL"
        case .integer: "5"
        case .real: "5.5"
        case .blob: "X'7A7A'"
        case .invalidUTF8: "CAST(X'7AFF' AS TEXT)"
        case .nulByte: "CAST(X'7A007A' AS TEXT)"
        }
    }

    /// The `typeof` result of the stored value.
    var storageClass: String {
        switch self {
        case .null: "null"
        case .integer: "integer"
        case .real: "real"
        case .blob: "blob"
        case .invalidUTF8, .nulByte: "text"
        }
    }
}

/// Stores `damage` as the full-scan snapshot key at `position` in a closed catalog file. The store declares the key
/// `TEXT NOT NULL`, which converts a number to text and refuses NULL, so the write runs with the key declared without
/// type and without NOT NULL. The file declares the key as before afterwards.
func storeDamagedSnapshotKey(_ damage: DamagedKey, atPosition position: Int, inClosedCatalogAt url: URL) throws {
    try runWithColumnDeclared(
        "local_id BLOB         ", insteadOf: "local_id TEXT NOT NULL", inClosedStoreAt: url,
        sql: "UPDATE photo_full_scan_snapshot SET local_id=\(damage.sql) WHERE position=\(position);")
    XCTAssertEqual(
        try firstText(
            "SELECT typeof(local_id) FROM photo_full_scan_snapshot WHERE position=\(position);", inStoreAt: url),
        damage.storageClass)
}

/// Stores `key` as an INTEGER in `local_id` of the catalog row `localIdentifier`, as only damage to the file can: SQL
/// converts a number to text for a TEXT column, and this SQLite refuses `writable_schema`. With the store closed, the
/// declared type in the file becomes BLOB, which has the same length, for one update, and then TEXT again.
func storeIntegerCatalogKey(_ key: Int, replacing localIdentifier: String, inClosedCatalogAt url: URL) throws {
    try runWithColumnDeclared(
        "local_id            BLOB PRIMARY KEY", insteadOf: "local_id            TEXT PRIMARY KEY",
        inClosedStoreAt: url, sql: "UPDATE photo_catalog SET local_id=\(key) WHERE local_id='\(localIdentifier)';")
    XCTAssertEqual(
        try firstText("SELECT local_id FROM photo_catalog WHERE typeof(local_id)='integer';", inStoreAt: url), "\(key)")
}

/// Runs `sql` on a closed store file while the file declares a column as `replacement`, then restores `declaration`.
/// Both must have the same length. SQLite in defensive mode refuses `writable_schema`, so the declaration is changed in
/// the file bytes after a checkpoint.
func runWithColumnDeclared(
    _ replacement: String, insteadOf declaration: String, inClosedStoreAt url: URL, sql: String
) throws {
    XCTAssertEqual(replacement.utf8.count, declaration.utf8.count, "the record keeps its length")
    func declare(_ from: String, as to: String) throws {
        try runSQL("PRAGMA wal_checkpoint(TRUNCATE);", inStoreAt: url)
        var image = try Data(contentsOf: url)
        let range = try XCTUnwrap(image.range(of: Data(from.utf8)), "the file declares \(from)")
        image.replaceSubrange(range, with: Data(to.utf8))
        try image.write(to: url)
    }
    try declare(declaration, as: replacement)
    try runSQL(sql, inStoreAt: url)
    try declare(replacement, as: declaration)
}

/// Runs `sql` on a store file through its own connection, as damage from outside the store would.
func runSQL(_ sql: String, inStoreAt url: URL) throws {
    try withStoreFile(at: url) { database in
        XCTAssertEqual(
            sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }
}

/// The first column of the first row of `sql` as text, read on its own connection to a store file.
func firstText(_ sql: String, inStoreAt url: URL) throws -> String? {
    try withStoreFile(at: url) { database in
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }
}

private func withStoreFile<Value>(at url: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    let database = try XCTUnwrap(handle)
    defer { sqlite3_close(database) }
    return try body(database)
}
