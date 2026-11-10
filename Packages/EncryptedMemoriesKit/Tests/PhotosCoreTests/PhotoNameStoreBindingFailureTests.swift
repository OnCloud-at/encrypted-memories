import Foundation
import PhotosCore
import SQLiteTestSupport
import XCTest

/// Every text bind of the photo name store checks its result (#1194). A failed bind leaves its parameter NULL: an
/// unchecked volume bind made the name read report an empty volume instead of an unreadable file, and an unchecked key
/// bind made `forget` report success while the name stayed. Each test fails only the binds of the target statement: an
/// identifier longer than the lowered SQLITE_LIMIT_LENGTH fails with SQLITE_TOOBIG, as a bind that runs out of memory
/// does. With the check the statement never steps.
final class PhotoNameStoreBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 32
    private static let long = String(repeating: "v", count: 64)

    private var directory: URL!
    private var store: PhotoNameStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-name-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(PhotoNameStore(directory: directory, accountUID: "account", keyPassword: "secret"))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Fails the binds of the first statement whose SQL contains `statement`.
    private func failBinds(of statement: String) throws -> BindFailureUntilStep {
        let fault = BindFailureUntilStep(
            onDatabase: try XCTUnwrap(storeDatabase(store!)), statement: statement, after: nil, limit: Self.limit)
        XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply")
        return fault
    }

    func testNodeReadWithAVolumeThatDoesNotBindIsUnreadable() throws {
        XCTAssertEqual(store.record([PhotoUID(volumeID: Self.long, nodeID: "node"): "Trip"]), .written)
        let fault = try failBinds(of: "SELECT node FROM photo_name WHERE")
        defer { fault.remove() }
        XCTAssertNil(
            store.recordedNodeIDs(volumeID: Self.long), "A volume that does not bind is no proof that it has no names")
        XCTAssertFalse(fault.stepped, "A volume that does not bind must not reach the read")
    }

    /// An empty name keeps the sealed value below the limit, so only the key binds fail.
    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheWrite() throws {
        let fault = try failBinds(of: "INSERT OR REPLACE INTO photo_name")
        defer { fault.remove() }
        XCTAssertEqual(store.record([PhotoUID(volumeID: Self.long, nodeID: "node"): ""]), .failed)
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the write")
        fault.remove()
        XCTAssertEqual(store.recordedNodeIDs(volumeID: Self.long), [])
    }

    func testForgetWithAKeyThatDoesNotBindFailsAndKeepsTheName() throws {
        let uid = PhotoUID(volumeID: Self.long, nodeID: "node")
        XCTAssertEqual(store.record([uid: "Trip"]), .written)
        let fault = try failBinds(of: "DELETE FROM photo_name")
        defer { fault.remove() }
        XCTAssertFalse(store.forget([uid]), "A key that does not bind removes nothing; that is no successful removal")
        XCTAssertFalse(fault.stepped, "A key that does not bind must not reach the removal")
        fault.remove()
        XCTAssertEqual(store.recordedNodeIDs(volumeID: Self.long), ["node"])
    }
}
