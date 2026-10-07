import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineOrderMetadataStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func photo(_ node: String, time: Double = 500) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: node),
            captureTime: Date(timeIntervalSince1970: time), mediaType: "image/jpeg")
    }

    func testOnlyUnknownCollisionsAreReadAndASecondIsPublishedTogether() throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
        defer { store.close() }
        let first = photo("a")
        let second = photo("b")
        let singleton = photo("c", time: 501)
        XCTAssertTrue(
            store.synchronize([first, second, singleton], classifiedUIDs: [first.uid, second.uid, singleton.uid]))
        let page = try store.nextPage(limit: 1)
        XCTAssertEqual(page.map(\.uid), [first.uid])
        XCTAssertTrue(page[0].needsOrder)
        XCTAssertTrue(store.record([first.uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.8))]))
        XCTAssertFalse(try store.publishCompletedSeconds())
        XCTAssertEqual(store.enrich([first, second]), [first, second])
        XCTAssertEqual(try store.nextPage().map(\.uid), [second.uid])
        XCTAssertTrue(store.record([second.uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1))]))
        XCTAssertTrue(try store.publishCompletedSeconds())
        XCTAssertEqual(store.enrich([first, second]).map(\.uid), [second.uid, first.uid])
        XCTAssertTrue(try store.nextPage().isEmpty)
        XCTAssertFalse(try store.publishCompletedSeconds())
    }

    func testAbsentValuesSurviveReopenAndRefreshWithoutRepeatedReads() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let items = [photo("a"), photo("b")]
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertTrue(store.record(Dictionary(uniqueKeysWithValues: items.map { ($0.uid, TimelineOrderMetadata()) })))
        XCTAssertTrue(try store.publishCompletedSeconds())
        store.close()
        let reopened = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(reopened.synchronize(items.reversed(), classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertTrue(try reopened.nextPage().isEmpty)
        XCTAssertEqual(reopened.enrich(items), items)
    }

    func testReuploadKeepsTheOrderAfterRefreshAndOnAnotherDevice() throws {
        let items = [photo("a-later"), photo("z-earlier")]
        let values: [PhotoUID: TimelineOrderMetadata] = [
            items[0].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.8), stableIdentity: "asset-2"),
            items[1].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1), stableIdentity: "asset-1"),
        ]
        for _ in 0..<2 {
            let store = try XCTUnwrap(
                TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
            defer { store.close() }
            XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
            XCTAssertTrue(store.record(values))
            XCTAssertTrue(try store.publishCompletedSeconds())
            let edited = photo("0-edit")
            let updated = [edited, items[1]]
            XCTAssertTrue(store.synchronize(updated, classifiedUIDs: Set(updated.map(\.uid))))
            XCTAssertTrue(store.record([edited.uid: values[items[0].uid]!]))
            XCTAssertTrue(try store.publishCompletedSeconds())
            XCTAssertEqual(store.enrich(updated).map(\.uid), [items[1].uid, edited.uid])
            XCTAssertTrue(store.synchronize(updated.reversed(), classifiedUIDs: Set(updated.map(\.uid))))
            XCTAssertEqual(store.enrich(updated).map(\.uid), [items[1].uid, edited.uid])
        }
    }

    func testCorruptCacheRebuildsAndAccountPurgeRemovesItsSidecars() throws {
        let base = try directory()
        let account = LibraryDatabaseLocation.prepareAccountDirectory(uid: "test-account", in: base)
        let url = account.appendingPathComponent(TimelineOrderMetadataStore.databaseFileName)
        try Data("damaged SQLite".utf8).write(to: url)
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize([photo("a"), photo("b")], classifiedUIDs: []))
        XCTAssertEqual(try store.nextPage().count, 2)
        store.close()
        for suffix in ["-wal", "-shm"] {
            try Data("derived sidecar".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + suffix))
        }
        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: "test-account", in: base))
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
    }

    func testOneHundredThousandPhotosUseBoundedPagesAndRetainTheUpgradeTimeline() throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
        defer { store.close() }
        let items = (0..<100_000).map { photo(String(format: "%06d", $0), time: Double(500 + $0 / 2)) }
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var cursor: PhotoUID?
        var pages = 0
        var count = 0
        while true {
            let page = try store.nextPage(after: cursor)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 150)
            XCTAssertTrue(page.allSatisfy(\.needsOrder))
            count += page.count
            pages += 1
            cursor = page.last?.uid
        }
        XCTAssertEqual(count, 100_000)
        XCTAssertEqual(pages, 667)
        XCTAssertFalse(store.workQueryPlan().contains("TEMP B-TREE"))
    }

    func testInterruptedPassResumesOnlyUnknownMembersAndLargeSecondsStayUnpublished() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let items = (0..<1_000).map { photo(String(format: "%04d", $0)) }
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        let firstPage = try store.nextPage()
        XCTAssertEqual(firstPage.count, 150)
        XCTAssertTrue(
            store.record(
                Dictionary(
                    uniqueKeysWithValues: firstPage.map {
                        ($0.uid, TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 500.8)))
                    })))
        XCTAssertFalse(try store.publishCompletedSeconds())
        store.close()
        let reopened = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(reopened.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertEqual(try reopened.nextPage().first?.uid, items[150].uid)
        XCTAssertEqual(reopened.enrich(items), items)
    }

    func testReadFailureRebuildsOnlyTheDerivedCache() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("order.sqlite")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE photo_order;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(store.enrich(items), items, "a broken cache must leave the timeline usable")
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertEqual(try store.nextPage().map(\.uid), items.map(\.uid))
    }

    func testUnavailableCacheDoesNotChangeTheExistingTimeline() throws {
        let directory = try directory()
        let blocked = directory.appendingPathComponent("blocked.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertNil(TimelineOrderMetadataStore(url: blocked))
        let timeline = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        defer { timeline.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(timeline.save(items).succeeded)
        XCTAssertEqual(timeline.load(), items)
    }

    func testV105AndBeta1DDLKeepEveryTimelineFieldWithTheNewCache() throws {
        // Both release tags contain this exact DDL and these four feature markers.
        for release in ["1.0.5", "1.1.0-beta.1"] {
            let dir = try directory()
            let url = dir.appendingPathComponent(LibraryDatabaseLocation.databaseFileName)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, Self.legacyDDL, nil, nil, nil), SQLITE_OK, release)
            let seed = """
                PRAGMA journal_mode=WAL;
                INSERT INTO schema_info VALUES('timeline',1),('photo_tags',1),('burst_members',1),('media_type_evidence',1);
                INSERT INTO photos VALUES('volume','a',500,'image/heic',1,'motion',4032,3024,2.5);
                INSERT INTO photo_tags VALUES('volume','a',0);
                INSERT INTO burst_members VALUES('volume','a','frame',0);
                INSERT INTO store_meta VALUES('timeline.validationToken','cursor');
                """
            XCTAssertEqual(sqlite3_exec(db, seed, nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            let cache = try XCTUnwrap(TimelineOrderMetadataStore(url: dir.appendingPathComponent("order.sqlite")))
            let timeline = try XCTUnwrap(TimelineMetadataStore(url: url))
            let saved = timeline.load()
            XCTAssertEqual(saved.count, 1, release)
            XCTAssertEqual(saved[0].mediaType, "image/heic")
            XCTAssertEqual(saved[0].relatedVideoID, "motion")
            XCTAssertEqual(saved[0].durationSeconds, 2.5)
            XCTAssertEqual(saved[0].tags, [.favorites])
            XCTAssertEqual(saved[0].burstMemberIDs, ["frame"])
            XCTAssertEqual(timeline.loadDimensions()[saved[0].uid], PhotoPixelDimensions(width: 4032, height: 3024))
            XCTAssertEqual(timeline.validationToken(), "cursor")
            XCTAssertTrue(cache.synchronize(saved, classifiedUIDs: []))
            XCTAssertTrue(timeline.save(cache.enrich(saved)).succeeded)
            timeline.close()
            cache.close()
            let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
            XCTAssertEqual(reopened.load(), saved)
            XCTAssertEqual(reopened.validationToken(), "cursor")
            reopened.close()
        }
    }

    private static let legacyDDL = """
            CREATE TABLE IF NOT EXISTS schema_info(feature TEXT PRIMARY KEY, version INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS photos(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              t REAL NOT NULL,
              mime TEXT NOT NULL DEFAULT 'image/jpeg',
              live INTEGER NOT NULL DEFAULT 0,
              relvid TEXT,
              w INTEGER,
              h INTEGER,
              dur REAL,
              PRIMARY KEY (vol, node)
            );
            CREATE INDEX IF NOT EXISTS idx_photos_timeline ON photos(t, vol, node);
            CREATE TABLE IF NOT EXISTS photo_tags(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              tag INTEGER NOT NULL,
              PRIMARY KEY (tag, vol, node)
            );
            CREATE TABLE IF NOT EXISTS burst_members(
              anchor_vol TEXT NOT NULL,
              anchor_node TEXT NOT NULL,
              member_node TEXT NOT NULL,
              seq INTEGER NOT NULL,
              PRIMARY KEY (anchor_vol, anchor_node, seq)
            );
            CREATE TABLE IF NOT EXISTS media_type_evidence(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              mime TEXT NOT NULL,
              PRIMARY KEY (vol, node)
            );
            CREATE TABLE IF NOT EXISTS store_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
}
