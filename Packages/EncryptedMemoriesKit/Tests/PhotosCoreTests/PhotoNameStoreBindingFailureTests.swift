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

    func testNodeReadWithAVolumeThatDoesNotBindIsUnreadable() throws {
        XCTAssertEqual(store.record([PhotoUID(volumeID: Self.long, nodeID: "node"): "Trip"]), .written)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "SELECT node FROM photo_name WHERE", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertNil(
            store.recordedNodeIDs(volumeID: Self.long), "A volume that does not bind is no proof that it has no names")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    /// An empty name keeps the sealed value below the limit, so only the key binds fail.
    func testRecordWithAKeyThatDoesNotBindFailsBeforeTheWrite() throws {
        let fault = try XCTUnwrap(
            BindFailureUntilStep(
                onStore: store!, statement: "INSERT OR REPLACE INTO photo_name", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertEqual(store.record([PhotoUID(volumeID: Self.long, nodeID: "node"): ""]), .failed)
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.recordedNodeIDs(volumeID: Self.long), [])
    }

    func testForgetWithAKeyThatDoesNotBindFailsAndKeepsTheName() throws {
        let uid = PhotoUID(volumeID: Self.long, nodeID: "node")
        XCTAssertEqual(store.record([uid: "Trip"]), .written)
        let fault = try XCTUnwrap(
            BindFailureUntilStep(onStore: store!, statement: "DELETE FROM photo_name", after: nil, limit: Self.limit))
        defer { fault.remove() }
        XCTAssertFalse(store.forget([uid]), "A key that does not bind removes nothing; that is no successful removal")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.recordedNodeIDs(volumeID: Self.long), ["node"])
    }
}
