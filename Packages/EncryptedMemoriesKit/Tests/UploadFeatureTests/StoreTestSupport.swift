import PhotoLibraryBackupAdapter
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Reads the same complete snapshot as the native backup sheets. An unknown read is a test failure.
@MainActor
func photoBackupProblemItems(
    _ controller: PhotoLibraryBackupController, file: StaticString = #filePath, line: UInt = #line
) async throws -> [BackupFailedItem] {
    let snapshot = await controller.problemSnapshot()
    return try XCTUnwrap(snapshot, file: file, line: line).rows.map(\.item)
}

/// The SQLite connection of a store, read through reflection, so a fixture can act on the store's own connection.
/// Pass the store itself: an implicitly unwrapped property passed as `Any` reflects as an Optional and has no
/// `connection` child.
func storeConnection(_ store: Any) throws -> SQLiteStoreConnection {
    try XCTUnwrap(
        Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value as? SQLiteStoreConnection)
}

/// The photo backup controller's own queue store, including in Release tests without its DEBUG accessor.
func photoBackupQueueStore(_ controller: Any) throws -> UploadBackupSyncQueueManifestStore {
    try XCTUnwrap(
        Mirror(reflecting: controller).children.first(where: { $0.label == "queueStore" })?.value
            as? UploadBackupSyncQueueManifestStore)
}

/// Pending-grid effects that succeed without doing anything.
struct InertPendingEffects: PendingBackupEffects {
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool { true }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> { Set(keys) }
    func photosVolumeID() async -> String? { "volume" }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

/// Remote pending effects that succeed without doing anything.
struct NoRemoteEffects: PendingRemoteEffects {
    func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

/// The same presentation metadata for every source: a photo.heic of November 2023.
struct AllFilesMetadata: PendingSourceMetadataProviding {
    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        Dictionary(
            uniqueKeysWithValues: keys.map {
                (
                    $0,
                    PendingPresentationMetadata(
                        captureTime: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image/heic",
                        displayName: "photo.heic")
                )
            })
    }
}

/// Fails every statement whose expanded SQL matches, until `stop()` or until it failed `failures` statements. Other
/// statements and probes run normally. With `fails: false` it only counts the matching statement runs.
final class SQLiteStatementFaults {
    private let connection: SQLiteStoreConnection
    private let matches: (String) -> Bool
    private let fails: Bool
    private let failures: Int
    private var statement: UnsafeMutableRawPointer?
    private var fired = 0
    private var matched = 0
    private var stopped = false

    init(in store: Any, fails: Bool = true, failures: Int = .max, matches: @escaping (String) -> Bool) throws {
        connection = try storeConnection(store)
        self.matches = matches
        self.fails = fails
        self.failures = failures
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    faults.statement = nil
                    guard let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                    defer { sqlite3_free(expanded) }
                    guard faults.matches(String(cString: expanded)) else { return 0 }
                    faults.matched += 1
                    if faults.fails, faults.fired < faults.failures { faults.statement = statement }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            sqlite3_progress_handler(
                connection.database, 1,
                { context in
                    guard let context else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    guard faults.statement != nil else { return 0 }
                    faults.statement = nil
                    faults.fired += 1
                    return 1
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var firedCount: Int { connection.withLock { fired } }
    var matchedCount: Int { connection.withLock { matched } }

    func stop() {
        connection.withLock {
            guard !stopped, connection.database != nil else { return }
            stopped = true
            sqlite3_trace_v2(connection.database, 0, nil, nil)
            sqlite3_progress_handler(connection.database, 0, nil, nil)
        }
    }
}

/// Records one transient failure on the store's connection while the first statement whose SQL contains `matching`
/// runs, without failing that statement. The failure stands for another reader of the same connection; the store's
/// health check forgets it at once, because the database answers.
final class SQLiteRecordedFailure {
    private let connection: SQLiteStoreConnection
    private let matching: String
    private var marked = false

    init(in store: Any, matching: String) throws {
        connection = try storeConnection(store)
        self.matching = matching
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let mark = Unmanaged<SQLiteRecordedFailure>.fromOpaque(context).takeUnretainedValue()
                    guard !mark.marked, let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).contains(mark.matching)
                    else { return 0 }
                    // The trace runs while the store holds its connection lock, as `markFailed` requires.
                    mark.marked = true
                    mark.connection.markFailed(resultCode: SQLITE_INTERRUPT)
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var recorded: Bool { connection.withLock { marked } }

    func stop() {
        connection.withLock {
            guard connection.database != nil else { return }
            sqlite3_trace_v2(connection.database, 0, nil, nil)
        }
    }
}

/// Authorizes statement preparation, not each step. Prepare, use and finalize statements within the body;
/// statements prepared before installation or retained across the body are outside this fixture's guarantees.
/// SQLite can reprepare during a step, so the callback stays installed until the body returns or throws.
/// The predicate receives the operation and arg1/arg2: table for READ/UPDATE/DELETE, column for READ/UPDATE;
/// other operations retain SQLite's argument meanings. Database and trigger/view names are not forwarded.
/// Do not nest or overlap calls on one connection: SQLite has one authorizer and the next install replaces it.
/// Keep the store open. The predicate must not re-enter the connection's nonrecursive lock.
/// The callback must not modify its connection, including preparing or stepping statements.
func withSQLiteAuthorization(
    in store: Any, authorizing: @escaping (Int32, String?, String?) -> Int32,
    _ body: () throws -> Void
) throws {
    let connection = try storeConnection(store)
    let authorization = connection.withLock {
        SQLiteAuthorization(onLockedConnection: connection, authorizing: authorizing)
    }
    defer {
        connection.withLock { SQLiteAuthorization.remove(authorization, fromLockedConnection: connection) }
    }
    try body()
}

/// Owns the callback storage for one installed authorizer. Retain it until removal finishes.
/// Install and remove only while holding the connection lock, so a fixture can change its other callbacks atomically.
/// The caller must remove the authorizer before releasing this object or closing the store.
final class SQLiteAuthorization {
    private let authorizing: (Int32, String?, String?) -> Int32

    init(
        onLockedConnection connection: SQLiteStoreConnection, authorizing: @escaping (Int32, String?, String?) -> Int32
    ) {
        self.authorizing = authorizing
        XCTAssertEqual(
            sqlite3_set_authorizer(
                connection.database,
                { context, action, table, column, _, _ in
                    guard let context else { return SQLITE_DENY }
                    let authorization = Unmanaged<SQLiteAuthorization>.fromOpaque(context).takeUnretainedValue()
                    return authorization.authorizing(
                        action, table.map { String(cString: $0) }, column.map { String(cString: $0) })
                }, Unmanaged.passUnretained(self).toOpaque()), SQLITE_OK)
    }

    static func remove(_ authorization: SQLiteAuthorization?, fromLockedConnection connection: SQLiteStoreConnection) {
        withExtendedLifetime(authorization) {
            XCTAssertEqual(sqlite3_set_authorizer(connection.database, nil, nil), SQLITE_OK)
        }
    }
}
