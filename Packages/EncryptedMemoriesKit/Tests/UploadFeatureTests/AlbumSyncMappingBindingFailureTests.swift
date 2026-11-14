import AlbumSyncCore
import Foundation
import PhotosCore
import SQLite3
import SQLiteTestSupport
import XCTest

/// Every text bind of the album sync mapping store checks its result (#1194). A failed bind leaves its parameter NULL:
/// an unchecked key bind stored a mapping or a selection under a NULL key and reported success, removed no selection and
/// reported success, and made a read report "no mapping" without recording the failure. Each test fails only the binds
/// of the target statement: a local album id longer than the lowered SQLITE_LIMIT_LENGTH fails with SQLITE_TOOBIG, as a
/// bind that runs out of memory does. With the check the statement never steps.
final class AlbumSyncMappingBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 32
    private static let longAlbumID = String(repeating: "a", count: 64)

    private var directory: URL!
    private var store: AlbumSyncMappingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(AlbumSyncMappingStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName) }

    private func mapping(_ localAlbumID: String) -> AlbumSyncMapping {
        AlbumSyncMapping(
            localAlbumID: localAlbumID, remoteAlbumID: "remote", title: "Trip",
            createdAt: Date(timeIntervalSinceReferenceDate: 1))
    }

    private func selection(_ localAlbumID: String) -> AlbumSyncSelection {
        AlbumSyncSelection(localAlbumID: localAlbumID, title: "Trip", addedAt: Date(timeIntervalSinceReferenceDate: 1))
    }

    /// Fails the binds of the first statement whose SQL contains `statement`.
    private func failBinds(of statement: String) throws -> (SQLiteStoreConnection, BindFailureUntilStep) {
        let connection = try storeConnection(store!)
        let fault = BindFailureUntilStep(on: connection, statement: statement, after: nil, limit: Self.limit)
        XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply")
        return (connection, fault)
    }

    /// The stored keys of `table`, read through a separate connection; a NULL key reads as "NULL".
    private func storedKeys(in table: String) throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle, "SELECT ifnull(local_album_id, 'NULL') FROM \(table) ORDER BY 1;", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            keys.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return keys
    }

    func testMappingReadWithAKeyThatDoesNotBindRecordsTheFailure() throws {
        XCTAssertTrue(store.upsert(mapping(Self.longAlbumID)))
        let (connection, fault) = try failBinds(of: "FROM album_sync_mapping WHERE local_album_id=?")
        defer { fault.remove() }
        XCTAssertNil(store.mapping(localAlbumID: Self.longAlbumID))
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the read")
        assertRecordedBindFailure(on: connection)
    }

    func testUpsertWithAKeyThatDoesNotBindFailsAndStoresNoMapping() throws {
        let (connection, fault) = try failBinds(of: "INSERT INTO album_sync_mapping")
        defer { fault.remove() }
        XCTAssertFalse(store.upsert(mapping(Self.longAlbumID)), "A mapping without its key is no successful write")
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the write")
        XCTAssertEqual(try storedKeys(in: "album_sync_mapping"), [], "No mapping may be stored under a NULL key")
        assertRecordedBindFailure(on: connection)
    }

    func testAddSelectionWithAKeyThatDoesNotBindFailsAndStoresNoSelection() throws {
        let (connection, fault) = try failBinds(of: "INSERT INTO album_sync_selection")
        defer { fault.remove() }
        XCTAssertFalse(
            store.addSelection(selection(Self.longAlbumID)), "A selection without its key is no successful write")
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the write")
        XCTAssertEqual(try storedKeys(in: "album_sync_selection"), [], "No selection may be stored under a NULL key")
        assertRecordedBindFailure(on: connection)
    }

    func testRemoveSelectionWithAKeyThatDoesNotBindFailsAndKeepsTheSelection() throws {
        XCTAssertTrue(store.addSelection(selection(Self.longAlbumID)))
        let (connection, fault) = try failBinds(of: "DELETE FROM album_sync_selection")
        defer { fault.remove() }
        XCTAssertFalse(
            store.removeSelection(localAlbumID: Self.longAlbumID),
            "A key that does not bind removes nothing; that is no successful removal")
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the removal")
        XCTAssertEqual(try storedKeys(in: "album_sync_selection"), [Self.longAlbumID])
        assertRecordedBindFailure(on: connection)
    }
}
