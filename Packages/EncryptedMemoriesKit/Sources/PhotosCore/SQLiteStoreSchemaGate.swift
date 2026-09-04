import Foundation
import SQLite3

/// Classifies an opened SQLite connection before a store applies persistent pragmas or schema DDL.
public enum SQLiteStoreSchemaState: Sendable, Equatable {
    case empty
    case populated
    case unavailable
}

public enum SQLiteStoreSchemaCompatibility: Sendable, Equatable {
    case empty
    case current
    case incompatible
    case unavailable
}

/// Exact-schema gate for operational and user-authored stores.
///
/// Existing files are inspected without writes. Only a database with no application schema may be
/// initialized. A populated database must contain the exact tables, columns, constraints, and indexes
/// produced by this build's schema SQL. This keeps schema changes explicit and prevents markerless or
/// future files from being modified while an older build tries to open them.
public enum SQLiteStoreSchemaGate {
    /// Inspects an existing database through a read-only connection. Missing files are empty stores.
    /// The caller can therefore reject a populated incompatible file before any read-write open,
    /// WAL recovery, persistent pragma, schema DDL, or version stamp can modify it.
    public static func compatibility(
        at url: URL,
        schemaSQL: String,
        busyTimeoutMs: Int = 5_000,
        versionIsCurrent: (OpaquePointer?) -> Bool
    ) -> SQLiteStoreSchemaCompatibility {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        var inspection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &inspection, flags, nil) == SQLITE_OK,
            let inspection
        else {
            sqlite3_close(inspection)
            return .unavailable
        }
        defer { sqlite3_close(inspection) }
        sqlite3_busy_timeout(inspection, Int32(clamping: busyTimeoutMs))
        switch state(of: inspection) {
        case .empty:
            guard let version = userVersion(of: inspection) else { return .unavailable }
            return version == 0 ? .empty : .incompatible
        case .populated:
            return versionIsCurrent(inspection)
                && matchesCurrentSchema(inspection, schemaSQL: schemaSQL)
                ? .current : .incompatible
        case .unavailable:
            return .unavailable
        }
    }

    /// Applies connection-local tuning only after the caller accepts the existing schema.
    public static func configureConnection(
        _ db: OpaquePointer?,
        policy: LibraryDatabasePolicy,
        includeMemoryTuning: Bool = true
    ) {
        var pragmas = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA busy_timeout=\(policy.busyTimeoutMs);",
            "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);",
        ]
        if includeMemoryTuning {
            pragmas.insert("PRAGMA cache_size=-\(max(0, policy.cacheSizeKiB));", at: 3)
            pragmas.insert("PRAGMA mmap_size=\(max(0, policy.mmapBytes));", at: 4)
        }
        for pragma in pragmas {
            sqlite3_exec(db, pragma, nil, nil, nil)
        }
    }

    public static func state(of db: OpaquePointer?) -> SQLiteStoreSchemaState {
        guard let objects = schemaObjects(in: db) else { return .unavailable }
        return objects.isEmpty ? .empty : .populated
    }

    private static func userVersion(of db: OpaquePointer?) -> Int32? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }

    public static func matchesCurrentSchema(
        _ db: OpaquePointer?,
        schemaSQL: String
    ) -> Bool {
        var reference: OpaquePointer?
        guard sqlite3_open(":memory:", &reference) == SQLITE_OK, let reference else {
            sqlite3_close(reference)
            return false
        }
        defer { sqlite3_close(reference) }
        guard sqlite3_exec(reference, schemaSQL, nil, nil, nil) == SQLITE_OK,
            let expectedObjects = schemaObjects(in: reference),
            let actualObjects = schemaObjects(in: db),
            expectedObjects == actualObjects
        else { return false }

        for object in expectedObjects where object.type == "table" {
            guard let expected = tableSignature(in: reference, named: object.name),
                let actual = tableSignature(in: db, named: object.name),
                expected == actual
            else { return false }
        }
        return true
    }

    /// Creates and stamps a new schema as one transaction. The caller must first prove that `db` is empty.
    public static func initializeCurrentSchema(
        _ db: OpaquePointer?,
        schemaSQL: String,
        stamp: () -> Bool
    ) -> Bool {
        guard state(of: db) == .empty,
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
        else { return false }

        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK,
            stamp(),
            matchesCurrentSchema(db, schemaSQL: schemaSQL),
            sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
        else { return false }
        committed = true
        return true
    }

    private struct SchemaObject: Equatable {
        let type: String
        let name: String
        let tableName: String
        let canonicalSQL: String?
    }

    private struct TableSignature: Equatable {
        let metadata: TableMetadata
        let columns: [Column]
        let indexes: [Index]
        let foreignKeys: [ForeignKey]
    }

    private struct TableMetadata: Equatable {
        let type: String
        let columnCount: Int32
        let withoutRowID: Bool
        let strict: Bool
    }

    private struct Column: Equatable {
        let identifier: Int32
        let name: String
        let declaredType: String
        let isNotNull: Bool
        let defaultValue: String?
        let primaryKeyPosition: Int32
        let hidden: Int32
    }

    private struct Index: Equatable {
        let name: String
        let isUnique: Bool
        let origin: String
        let isPartial: Bool
        let columns: [IndexColumn]
    }

    private struct IndexColumn: Equatable {
        let sequence: Int32
        let columnIdentifier: Int32
        let name: String?
        let descending: Bool
        let collation: String?
        let isKey: Bool
    }

    private struct ForeignKey: Equatable {
        let identifier: Int32
        let sequence: Int32
        let table: String
        let from: String
        let to: String?
        let onUpdate: String
        let onDelete: String
        let match: String
    }

    private static func schemaObjects(in db: OpaquePointer?) -> [SchemaObject]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT type, name, tbl_name, sql FROM sqlite_schema "
                + "WHERE type IN ('table','index','view','trigger') AND name NOT LIKE 'sqlite_%' "
                + "ORDER BY type, name, tbl_name;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var objects: [SchemaObject] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let type = text(statement, 0),
                let name = text(statement, 1),
                let tableName = text(statement, 2)
            else { return nil }
            objects.append(
                SchemaObject(
                    type: type,
                    name: name,
                    tableName: tableName,
                    canonicalSQL: text(statement, 3).map(canonicalSQL)
                )
            )
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? objects : nil
    }

    private static func tableSignature(in db: OpaquePointer?, named table: String) -> TableSignature? {
        guard let metadata = tableMetadata(in: db, named: table),
            let columns = columns(in: db, table: table),
            let indexes = indexes(in: db, table: table),
            let foreignKeys = foreignKeys(in: db, table: table)
        else { return nil }
        return TableSignature(
            metadata: metadata,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    private static func tableMetadata(in db: OpaquePointer?, named table: String) -> TableMetadata? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_list;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if text(statement, 1) == table {
                guard let type = text(statement, 2) else { return nil }
                return TableMetadata(
                    type: type,
                    columnCount: sqlite3_column_int(statement, 3),
                    withoutRowID: sqlite3_column_int(statement, 4) != 0,
                    strict: sqlite3_column_int(statement, 5) != 0
                )
            }
            result = sqlite3_step(statement)
        }
        return nil
    }

    private static func columns(in db: OpaquePointer?, table: String) -> [Column]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_xinfo(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = text(statement, 1), let declaredType = text(statement, 2) else { return nil }
            columns.append(
                Column(
                    identifier: sqlite3_column_int(statement, 0),
                    name: name,
                    declaredType: declaredType,
                    isNotNull: sqlite3_column_int(statement, 3) != 0,
                    defaultValue: text(statement, 4),
                    primaryKeyPosition: sqlite3_column_int(statement, 5),
                    hidden: sqlite3_column_int(statement, 6)
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? columns : nil
    }

    private static func indexes(in db: OpaquePointer?, table: String) -> [Index]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_list(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var indexes: [Index] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = text(statement, 1),
                let origin = text(statement, 3),
                let columns = indexColumns(in: db, index: name)
            else { return nil }
            indexes.append(
                Index(
                    name: name,
                    isUnique: sqlite3_column_int(statement, 2) != 0,
                    origin: origin,
                    isPartial: sqlite3_column_int(statement, 4) != 0,
                    columns: columns
                ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return nil }
        return indexes.sorted { $0.name < $1.name }
    }

    private static func indexColumns(in db: OpaquePointer?, index: String) -> [IndexColumn]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_xinfo(\(literal(index)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns: [IndexColumn] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            columns.append(
                IndexColumn(
                    sequence: sqlite3_column_int(statement, 0),
                    columnIdentifier: sqlite3_column_int(statement, 1),
                    name: text(statement, 2),
                    descending: sqlite3_column_int(statement, 3) != 0,
                    collation: text(statement, 4),
                    isKey: sqlite3_column_int(statement, 5) != 0
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? columns : nil
    }

    private static func foreignKeys(in db: OpaquePointer?, table: String) -> [ForeignKey]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_list(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var keys: [ForeignKey] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let targetTable = text(statement, 2),
                let from = text(statement, 3),
                let onUpdate = text(statement, 5),
                let onDelete = text(statement, 6),
                let match = text(statement, 7)
            else { return nil }
            keys.append(
                ForeignKey(
                    identifier: sqlite3_column_int(statement, 0),
                    sequence: sqlite3_column_int(statement, 1),
                    table: targetTable,
                    from: from,
                    to: text(statement, 4),
                    onUpdate: onUpdate,
                    onDelete: onDelete,
                    match: match
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? keys : nil
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// SQLite preserves schema SQL text. Normalize only insignificant unquoted whitespace and ASCII case.
    /// Quoted identifiers and literals remain byte-exact, so CHECK clauses and trigger bodies cannot drift.
    private static func canonicalSQL(_ sql: String) -> String {
        let scalars = Array(sql.unicodeScalars)
        var result = String.UnicodeScalarView()
        var quoteEnd: Unicode.Scalar?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuoteEnd = quoteEnd {
                result.append(scalar)
                if scalar == activeQuoteEnd {
                    if index + 1 < scalars.count, scalars[index + 1] == activeQuoteEnd {
                        result.append(scalars[index + 1])
                        index += 1
                    } else {
                        quoteEnd = nil
                    }
                }
            } else if scalar == "'" || scalar == "\"" || scalar == "`" {
                quoteEnd = scalar
                result.append(scalar)
            } else if scalar == "[" {
                quoteEnd = "]"
                result.append(scalar)
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if scalar.value >= 65, scalar.value <= 90,
                    let lower = Unicode.Scalar(scalar.value + 32)
                {
                    result.append(lower)
                } else {
                    result.append(scalar)
                }
            }
            index += 1
        }
        return String(result)
    }

}
