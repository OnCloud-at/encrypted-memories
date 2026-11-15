import Foundation
import MLSearchCore
import PhotosCore
import SQLite3
import UploadCore
import XCTest

/// Pins the `user_version` marker of each rebuildable store. Another marker drops that store on every installed device
/// at its next launch, and an older build deletes a file with a marker that it does not know.
final class RebuildableStoreUserVersionTests: XCTestCase {
    func testEachRebuildableStoreKeepsItsReleasedMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        try XCTUnwrap(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret")).close()
        try XCTUnwrap(TimelineOrderMetadataStore(url: url("timeline-order.sqlite"))).close()
        try XCTUnwrap(SQLiteMLIndexStore(url: url("ml-index.sqlite"), cipher: FixtureVectorCipher())).close()
        try XCTUnwrap(SQLiteMLDerivedPipelineStore(url: url("ml-derived.sqlite"), cipher: FixtureDerivedCipher()))
            .close()
        try XCTUnwrap(
            ExactDuplicateFingerprintStore(
                url: url(ExactDuplicateFingerprintStore.databaseFileName), cacheDirectory: directory)
        ).close()
        try XCTUnwrap(UploadRemoteLineageIndexStore(url: url("remote-lineage.sqlite"))).close()

        let expected: [(file: String, marker: Int32)] = [
            (PhotoNameStore.databaseFileName, 1), ("timeline-order.sqlite", 1), ("ml-index.sqlite", 5),
            ("ml-derived.sqlite", 7), (ExactDuplicateFingerprintStore.databaseFileName, 1),
            ("remote-lineage.sqlite", 2),
        ]
        for (file, marker) in expected {
            XCTAssertEqual(userVersion(at: url(file)), marker, file)
        }
    }

    private func userVersion(at url: URL) -> Int32? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }
}
