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
        // Another connection deletes every queue row when the read starts, so the read finds the queue without its rows.
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &other, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(other) }
        let removal = try SQLiteStatementStartAction(
            in: queue!, matching: "SELECT original_filename, byte_count, state"
        ) { _ in sqlite3_exec(other, "DELETE FROM backup_sync_queue;", nil, nil, nil) == SQLITE_OK }
        defer { removal.stop() }
        XCTAssertThrowsError(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])) {
            XCTAssertEqual($0 as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertTrue(removal.fired)
        XCTAssertTrue(queue.isOperational(), "the row is absent, not unreadable")
    }
}
