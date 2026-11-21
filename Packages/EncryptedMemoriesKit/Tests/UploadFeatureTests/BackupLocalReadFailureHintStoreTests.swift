import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class BackupLocalReadFailureHintStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent(BackupLocalReadFailureHintStore.databaseFileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// The key is the photo: a hint for its paired video is the same hint, and hints survive a restart.
    func testOneHintPerPhotoSurvivesAReopen() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        XCTAssertTrue(store.insert(photo("a")))
        XCTAssertTrue(store.insert(photo("a", resource: .livePairedVideo)))
        XCTAssertTrue(store.insert(UploadSourceIdentity(kind: .fileURL, identifier: "a")))
        store.close()

        let reopened = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(try allHints(reopened), [photo("a"), UploadSourceIdentity(kind: .fileURL, identifier: "a")])
    }

    func testRemoveDeletesOnlyTheNamedPhotos() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { store.close() }
        for name in ["a", "b", "c"] { XCTAssertTrue(store.insert(photo(name))) }

        XCTAssertTrue(store.remove([photo("a"), photo("c", resource: .livePairedVideo), photo("missing")]))

        XCTAssertEqual(try allHints(store), [photo("b")])
        XCTAssertTrue(store.remove([]))
    }

    /// At the capacity the oldest hints go first. A dropped hint only restores the normal order for its photo.
    func testTheCapacityDropsTheOldestHints() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url, capacity: 3))
        defer { store.close() }
        for name in ["a", "b", "c", "d"] { XCTAssertTrue(store.insert(photo(name))) }

        XCTAssertEqual(try allHints(store), [photo("b"), photo("c"), photo("d")])
    }

    func testPagesListEveryHintOnceOldestFirst() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { store.close() }
        let names = ["e", "a", "d", "b", "c"]
        for name in names { XCTAssertTrue(store.insert(photo(name))) }

        let first = try XCTUnwrap(store.page(after: 0, limit: 2))
        XCTAssertEqual(first.sources, [photo("e"), photo("a")])
        let second = try XCTUnwrap(store.page(after: first.next, limit: 2))
        XCTAssertEqual(second.sources, [photo("d"), photo("b")])
        XCTAssertEqual(try allHints(store, pageSize: 2), names.map { photo($0) })
    }

    func testTheSweepCursorStartsAtZeroAndSurvivesAReopen() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        XCTAssertEqual(store.sweepCursor(), 0)
        XCTAssertTrue(store.saveSweepCursor(42))
        store.close()

        let reopened = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(reopened.sweepCursor(), 42)
    }

    /// An unreadable file is a lost cache: the store removes it, opens empty and accepts hints again.
    func testAnUnreadableFileOpensEmptyAndAcceptsHints() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        XCTAssertTrue(store.insert(photo("a")))
        store.close()
        try Data(repeating: 0x5A, count: 8_192).write(to: url)

        let reopened = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(try allHints(reopened), [])
        XCTAssertTrue(reopened.insert(photo("b")))
        XCTAssertEqual(try allHints(reopened), [photo("b")])
    }

    func testAFileWithAnotherSchemaIsRebuiltEmpty() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "CREATE TABLE hint(other TEXT); INSERT INTO hint VALUES('x');", nil, nil, nil),
            SQLITE_OK)
        sqlite3_close(handle)

        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { store.close() }
        XCTAssertEqual(try allHints(store), [])
        XCTAssertTrue(store.insert(photo("a")))
    }

    /// Another connection holds the file longer than the busy timeout: the file is kept and opens again with its hints.
    func testAFileThatAnotherConnectionHoldsIsKeptAndOpensAgainWithItsHints() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        XCTAssertTrue(store.insert(photo("a")))
        store.close()
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let noWait = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let busy = BackupLocalReadFailureHintStore(url: url, policy: noWait)
        busy?.close()
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)

        XCTAssertNil(busy, "the store is unavailable while the lock lasts")
        let reopened = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(try allHints(reopened), [photo("a")])
    }

    /// Without a usable file there is no store, and the runner keeps the normal order.
    func testALocationThatCannotHoldTheFileOpensNoStore() throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)

        XCTAssertNil(
            BackupLocalReadFailureHintStore(
                url: blocked.appendingPathComponent(BackupLocalReadFailureHintStore.databaseFileName)))
    }

    func testAClosedStoreAnswersNothingAndStoresNothing() throws {
        let store = try XCTUnwrap(BackupLocalReadFailureHintStore(url: url))
        XCTAssertTrue(store.insert(photo("a")))
        store.close()

        XCTAssertFalse(store.insert(photo("b")))
        XCTAssertFalse(store.remove([photo("a")]))
        XCTAssertNil(store.page(after: 0, limit: 10))
        XCTAssertNil(store.sweepCursor())
        XCTAssertFalse(store.saveSweepCursor(1))
    }

    private func photo(
        _ identifier: String, resource: UploadSourceIdentity.Resource = .primary
    ) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: resource)
    }

    private func allHints(
        _ store: BackupLocalReadFailureHintStore, pageSize: Int = 100
    ) throws -> [UploadSourceIdentity] {
        var hints: [UploadSourceIdentity] = []
        var cursor: Int64 = 0
        while true {
            let page = try XCTUnwrap(store.page(after: cursor, limit: pageSize))
            hints += page.sources
            guard page.sources.count == pageSize else { return hints }
            cursor = page.next
        }
    }
}
