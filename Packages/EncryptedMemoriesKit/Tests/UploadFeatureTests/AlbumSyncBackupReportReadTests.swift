import AlbumSyncCore
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// The deletion-row read of the Album Sync backup report on the real queue store: a read that fails or finds no row
/// refuses the report, even when the store's health check passes afterwards.
final class AlbumSyncBackupReportReadTests: XCTestCase {
    private var url: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "photo")

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: source, revision: .init(rawValue: 42), originalFilename: "photo.heic",
                    state: .skippedRemoteDeletion, updatedAt: Date())))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: url)
    }

    func testATransientlyFailedDeletionRowReadRefusesTheReportThatTheHealthCheckWouldPass() throws {
        let fault = try SQLiteReadInterrupt(in: queue!, matching: "SELECT original_filename, byte_count, state")
        defer { fault.stop() }
        XCTAssertThrowsError(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])) {
            XCTAssertEqual($0 as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertTrue(fault.fired)
        XCTAssertTrue(queue.isOperational(), "the transient failure is forgotten, so only the typed read refuses")
    }

    func testADeletionRowThatLeavesTheQueueAfterTheStateReadRefusesTheReport() throws {
        let removal = try RowRemovalBeforeStatement(
            in: queue!, matching: "SELECT original_filename, byte_count, state", databaseURL: url)
        defer { removal.stop() }
        XCTAssertThrowsError(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])) {
            XCTAssertEqual($0 as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertTrue(removal.removed)
        XCTAssertTrue(queue.isOperational(), "the row is absent, not unreadable")
    }
}

/// Deletes every queue row through a second connection when the store starts the first statement whose SQL contains
/// `matching`, so that statement reads the queue without its rows.
private final class RowRemovalBeforeStatement {
    private let connection: SQLiteStoreConnection
    private let matching: String
    private var other: OpaquePointer?
    private(set) var removed = false

    init(in store: Any, matching: String, databaseURL: URL) throws {
        connection = try storeConnection(store)
        self.matching = matching
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &other, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let removal = Unmanaged<RowRemovalBeforeStatement>.fromOpaque(context).takeUnretainedValue()
                    guard !removal.removed, let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).contains(removal.matching)
                    else { return 0 }
                    removal.removed =
                        sqlite3_exec(removal.other, "DELETE FROM backup_sync_queue;", nil, nil, nil) == SQLITE_OK
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func stop() {
        connection.withLock { sqlite3_trace_v2(connection.database, 0, nil, nil) }
        sqlite3_close(other)
    }
}
