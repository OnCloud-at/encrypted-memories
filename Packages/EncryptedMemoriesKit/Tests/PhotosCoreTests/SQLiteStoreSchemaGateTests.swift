import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteStoreSchemaGateTests: XCTestCase {
    func testOpenCurrentStoreCreatesReopensAndRejectsIncompatibleFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaGate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let schema = "CREATE TABLE marker (version INTEGER NOT NULL);"
        func verify(_ db: OpaquePointer?) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT version FROM marker;", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
        }
        func stamp(_ db: OpaquePointer?) -> Bool {
            sqlite3_exec(db, "INSERT INTO marker VALUES (1);", nil, nil, nil) == SQLITE_OK
        }
        let first = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(first))
        sqlite3_close(first)

        let reopened = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(reopened))
        XCTAssertEqual(sqlite3_exec(reopened, "UPDATE marker SET version = 2;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(reopened)

        XCTAssertNil(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        var inspection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &inspection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(inspection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(inspection, "SELECT version FROM marker;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
    }
}
