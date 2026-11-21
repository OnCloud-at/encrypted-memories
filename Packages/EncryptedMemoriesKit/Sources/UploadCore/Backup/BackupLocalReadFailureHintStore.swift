import Foundation
import PhotosCore
import SQLite3

/// One page of hinted photos, oldest first, and the cursor of the next page.
public struct BackupLocalReadFailureHintPage: Sendable, Equatable {
    public let sources: [UploadSourceIdentity]
    public let next: Int64

    public init(sources: [UploadSourceIdentity], next: Int64) {
        self.sources = sources
        self.next = next
    }
}

/// Remembers the photos whose local read failed in a background pass (#274), mostly originals that only iCloud holds.
/// A hint only orders background claims: a missing, damaged or deleted file restores the normal order and never
/// changes which photos are backed up. The file is a rebuildable cache next to the queue; the queue schema stays as is.
public final class BackupLocalReadFailureHintStore: @unchecked Sendable {
    public static let databaseFileName = "photo-backup-local-read-failed-v1.sqlite"
    /// The most hints the file keeps.
    public static let defaultCapacity = 200_000

    private static let version = SQLiteInfoTableVersion(
        table: "local_read_failure_info", version: 1, stampReplacesExistingRow: false)
    private static let schema = """
        CREATE TABLE local_read_failure_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE local_read_failure_hint(
          seq INTEGER PRIMARY KEY,
          source_kind TEXT NOT NULL,
          source_id TEXT NOT NULL,
          UNIQUE(source_kind, source_id)
        );
        """

    private let connection: SQLiteStoreConnection
    private let capacity: Int64

    public init?(url: URL, capacity: Int = defaultCapacity, policy: LibraryDatabasePolicy = .conservative) {
        func open() -> SQLiteRebuildableStoreOutcome {
            SQLiteStoreSchemaGate.openRebuildableStoreOutcome(
                at: url, schemaSQL: Self.schema, policy: policy,
                verifyVersion: Self.version.verify, stampVersion: Self.version.stamp)
        }
        // A lost hint only restores the normal order, so a file that fails to open is replaced. A file that cannot be
        // checked now stays for the next open.
        guard let handle = SQLiteStoreSchemaGate.openReplacingFailedStore(at: url, open: open) else { return nil }
        connection = SQLiteStoreConnection(database: handle)
        self.capacity = Int64(max(1, capacity))
    }

    deinit { close() }

    public func close() { connection.close() }

    /// Adds a hint for the photo of `source`; the key is the photo, not its resource or revision. A new hint drops the
    /// hints that are `capacity` inserts older. True only when the hint is stored.
    @discardableResult
    public func insert(_ source: UploadSourceIdentity) -> Bool {
        transaction { db in
            try step(
                db,
                """
                INSERT INTO local_read_failure_hint(source_kind, source_id) VALUES(?, ?)
                ON CONFLICT(source_kind, source_id) DO NOTHING;
                """
            ) { try bindPhoto(source, to: $0) }
            guard sqlite3_changes(db) > 0 else { return }
            let oldestKept = sqlite3_last_insert_rowid(db) - capacity
            try step(db, "DELETE FROM local_read_failure_hint WHERE seq <= ?;") {
                sqlite3_bind_int64($0, 1, oldestKept)
            }
        }
    }

    /// Removes the hints of these photos. True when every hint is gone.
    @discardableResult
    public func remove(_ sources: [UploadSourceIdentity]) -> Bool {
        transaction { db in
            for source in sources {
                try step(db, "DELETE FROM local_read_failure_hint WHERE source_kind=? AND source_id=?;") {
                    try bindPhoto(source, to: $0)
                }
            }
        }
    }

    /// Up to `limit` hinted photos after `cursor`, oldest first. Nil when the read failed or a row does not decode.
    public func page(after cursor: Int64, limit: Int) -> BackupLocalReadFailureHintPage? {
        connection.withLock {
            guard let db = connection.database else { return nil }
            var stmt: OpaquePointer?
            guard
                connection.requireOperationalRecordingSQLiteError(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT seq, source_kind, source_id FROM local_read_failure_hint
                        WHERE seq > ? ORDER BY seq LIMIT ?;
                        """,
                        -1, &stmt, nil) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cursor)
            sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
            var sources: [UploadSourceIdentity] = []
            var next = cursor
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                guard let kindText = sqlite3_column_text(stmt, 1), let idText = sqlite3_column_text(stmt, 2),
                    let kind = UploadSourceIdentity.Kind(rawValue: String(cString: kindText))
                else { return nil }
                next = sqlite3_column_int64(stmt, 0)
                sources.append(UploadSourceIdentity(kind: kind, identifier: String(cString: idText)))
                result = sqlite3_step(stmt)
            }
            guard connection.requireOperationalRecordingSQLiteError(result == SQLITE_DONE) else { return nil }
            return BackupLocalReadFailureHintPage(sources: sources, next: next)
        }
    }

    /// Where the next cleanup sweep starts; 0 before the first sweep. Nil when the read failed.
    public func sweepCursor() -> Int64? {
        connection.withLock {
            guard let db = connection.database else { return nil }
            var stmt: OpaquePointer?
            guard
                connection.requireOperationalRecordingSQLiteError(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM local_read_failure_info WHERE key='sweep_cursor';", -1, &stmt, nil)
                        == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return sqlite3_column_int64(stmt, 0)
            case SQLITE_DONE: return 0
            default:
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return nil
            }
        }
    }

    @discardableResult
    public func saveSweepCursor(_ cursor: Int64) -> Bool {
        transaction { db in
            try step(
                db,
                """
                INSERT INTO local_read_failure_info(key, value) VALUES('sweep_cursor', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """
            ) { sqlite3_bind_int64($0, 1, cursor) }
        }
    }

    // MARK: - SQL

    private struct StepFailed: Error {}

    /// Runs `body` in the shared write transaction of the connection, under its lock. False when the store is closed or
    /// any statement failed; a failed transaction changes nothing.
    private func transaction(_ body: (OpaquePointer) throws -> Void) -> Bool {
        connection.withLock {
            guard let db = connection.database else { return false }
            return connection.immediateTransaction {
                do {
                    try body(db)
                    return true
                } catch {
                    return false
                }
            }
        }
    }

    /// Prepares, binds and steps one statement that returns no rows. Call inside `transaction`.
    private func step(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard
            connection.requireOperationalRecordingSQLiteError(
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        else { throw StepFailed() }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        guard connection.requireOperationalRecordingSQLiteError(sqlite3_step(stmt) == SQLITE_DONE) else {
            throw StepFailed()
        }
    }

    /// Binds the photo key: kind and identifier, without the resource.
    private func bindPhoto(_ source: UploadSourceIdentity, to stmt: OpaquePointer?) throws {
        try connection.bindText(stmt, 1, source.kind.rawValue)
        try connection.bindText(stmt, 2, source.identifier)
    }
}
