import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class LoopingLivePhotoStateTests: XCTestCase {
    func testLoopingStateSurvivesCodableWithoutChangingLivePhotoMembership() throws {
        let loop = item(looping: true)
        XCTAssertTrue(loop.isLoopingLivePhoto)
        XCTAssertTrue(loop.isLivePhoto)
        XCTAssertTrue(loop.tags.contains(.livePhotos))
        XCTAssertEqual(loop.relatedVideoUID?.nodeID, "motion")
        XCTAssertTrue(try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(loop)).isLoopingLivePhoto)
    }

    func testLegacyLiveItemsDoNotBecomeLoops() throws {
        XCTAssertFalse(item(looping: false).isLoopingLivePhoto)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item(looping: false))) as? [String: Any])
        legacy.removeValue(forKey: "isLoopingLivePhoto")
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.isLoopingLivePhoto)
    }

    func testConstructorAndDecoderRejectLoopingOnNonLiveItems() throws {
        let ordinary = item(looping: true, live: false)
        XCTAssertFalse(ordinary.isLoopingLivePhoto)
        var malformed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        malformed["isLoopingLivePhoto"] = true
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: malformed))
        XCTAssertFalse(decoded.isLoopingLivePhoto)
    }

    func testSourceNormalizationAndMergePreserveKnownLoopingState() {
        let loop = item(looping: true)
        XCTAssertTrue(LibrarySourceItem.complete(loop).item.isLoopingLivePhoto)
        let unknown = LibrarySourceItem(item: loop, knownFields: [.captureTime, .mediaType])
        XCTAssertFalse(unknown.item.isLoopingLivePhoto)
        let merged = LibrarySourceGraph.merge(preferred: unknown, fallback: .complete(loop))
        XCTAssertTrue(merged.item.isLoopingLivePhoto)
        let knownStill = LibrarySourceGraph.merge(
            preferred: .complete(item(looping: false)), fallback: .complete(loop))
        XCTAssertFalse(knownStill.item.isLoopingLivePhoto)
    }

    func testStorePersistsLoopingAsTwoAndKeepsLegacyLiveAsOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timeline.sqlite")
        let store = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertTrue(store.save([item(looping: true)]).succeeded)
        XCTAssertTrue(try XCTUnwrap(store.load().first).isLoopingLivePhoto)
        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(try XCTUnwrap(reopened.load().first).isLoopingLivePhoto)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT live FROM photos;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
        sqlite3_reset(statement)
        XCTAssertTrue(reopened.save([item(looping: false)]).succeeded)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testChangingOnlyLoopingStateCannotBeSkippedByTheTimelineDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("timeline.sqlite")))
        defer { store.close() }
        XCTAssertTrue(store.save([item(looping: false)]).succeeded)
        let change = store.save([item(looping: true)])
        XCTAssertTrue(change.succeeded)
        XCTAssertFalse(change.skippedUnchanged)
        XCTAssertTrue(try XCTUnwrap(store.load().first).isLoopingLivePhoto)
        XCTAssertTrue(store.save([item(looping: true)]).skippedUnchanged)
    }

    func testAFailedLoopWriteKeepsTheOldStateAndAllowsARetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timeline.sqlite")
        let store = try XCTUnwrap(TimelineMetadataStore(url: url))
        defer { store.close() }
        XCTAssertTrue(store.save([item(looping: false)], validationToken: "old").succeeded)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let trigger = """
            CREATE TRIGGER reject_loop BEFORE UPDATE ON photos WHEN NEW.live=2
            BEGIN SELECT RAISE(ABORT, 'synthetic loop write failure'); END;
            """
        XCTAssertEqual(sqlite3_exec(database, trigger, nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store.save([item(looping: true)], validationToken: "new").succeeded)
        XCTAssertFalse(try XCTUnwrap(store.load().first).isLoopingLivePhoto)
        XCTAssertEqual(store.validationToken(), "old")
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_loop;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store.save([item(looping: true)], validationToken: "new").succeeded)
        XCTAssertTrue(try XCTUnwrap(store.load().first).isLoopingLivePhoto)
        XCTAssertEqual(store.validationToken(), "new")
    }

    private func item(looping: Bool, live: Bool = true) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 10), mediaType: "image/heic",
            isLivePhoto: live, isLoopingLivePhoto: looping, relatedVideoID: live ? "motion" : nil,
            tags: live ? [.livePhotos] : [])
    }
}
