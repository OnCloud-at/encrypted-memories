import PhotoLibraryBackupAdapter
import PhotosCore
import SQLite3
import SQLiteTestSupport
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

extension SQLiteStatementFaults {
    /// Acts on the `SQLiteStoreConnection` of `store`.
    convenience init(
        in store: Any, fails: Bool = true, failures: Int = .max, matches: @escaping (String) -> Bool
    ) throws {
        self.init(on: try storeConnection(store), fails: fails, failures: failures, matches: matches)
    }
}

/// Runs `action` once, under the store's connection lock, when the store starts the first statement whose SQL contains
/// `matching`. The statement itself runs normally. `fired` tells whether the action ran and returned true.
final class SQLiteStatementStartAction {
    private let connection: SQLiteStoreConnection
    private let matching: String
    private let action: (SQLiteStoreConnection) -> Bool
    private var ran = false
    private var succeeded = false

    init(in store: Any, matching: String, action: @escaping (SQLiteStoreConnection) -> Bool) throws {
        connection = try storeConnection(store)
        self.matching = matching
        self.action = action
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let start = Unmanaged<SQLiteStatementStartAction>.fromOpaque(context).takeUnretainedValue()
                    guard !start.ran, let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).contains(start.matching)
                    else { return 0 }
                    // The trace runs while the store holds its connection lock.
                    start.ran = true
                    start.succeeded = start.action(start.connection)
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Records one transient failure on the store's connection while the first matching statement runs, without
    /// failing that statement. The failure stands for another reader of the same connection; the store's health check
    /// forgets it at once, because the database answers.
    static func recordedFailure(in store: Any, matching: String) throws -> SQLiteStatementStartAction {
        try SQLiteStatementStartAction(in: store, matching: matching) { connection in
            // `markFailed` requires the connection lock, which the trace holds.
            connection.markFailed(resultCode: SQLITE_INTERRUPT)
            return true
        }
    }

    var fired: Bool { connection.withLock { succeeded } }

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
