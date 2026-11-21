import Foundation
import PhotosCore
import SQLiteTestSupport
import XCTest

@testable import UploadCore

/// A set read of the queue answers found, absent or unknown. Unknown never proves that no row exists (#1154).
final class QueueTypedSetReadTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let date = Date(timeIntervalSince1970: 1_720_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ identifier: String, state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier),
            revision: UploadBackupRevision(rawValue: 1), originalFilename: "photo.heic", state: state, updatedAt: date)
    }

    func testTheKeyedSetReadDistinguishesFoundAbsentAndUnknown() throws {
        XCTAssertTrue(queue.upsert(store("waiting", state: .queuedForUpload)))
        XCTAssertTrue(queue.upsert(store("other", state: .failed)))
        let observer: any UploadBackupSyncQueueObserving = queue

        guard case .found(let rows) = observer.decisionRowSet(kind: .photoLibraryAsset, identifiers: ["waiting"]) else {
            return XCTFail("a stored row is found")
        }
        XCTAssertEqual(rows.map(\.source.identifier), ["waiting"])
        XCTAssertEqual(
            observer.decisionRowSet(kind: .photoLibraryAsset, identifiers: ["missing"]), .absent,
            "a complete read that finds no row is absent")
        XCTAssertEqual(observer.decisionRowSet(kind: .photoLibraryAsset, identifiers: []), .absent)
        XCTAssertEqual(
            observer.decisionRowSet(kind: .fileURL, identifiers: ["waiting"]), .absent, "another kind holds no row")

        let fault = try SQLiteStatementFaults(in: queue!) {
            $0.contains("SELECT source_kind, source_id, resource, revision_us, state, original_filename")
        }
        XCTAssertEqual(
            observer.decisionRowSet(kind: .photoLibraryAsset, identifiers: ["waiting"]), .unknown,
            "a failed read never reads as no row")
        fault.stop()
        XCTAssertGreaterThan(fault.firedCount, 0)
    }

    func testTheUnsettledSetReadDistinguishesFoundAbsentAndUnknown() throws {
        let observer: any UploadBackupSyncQueueObserving = queue
        XCTAssertEqual(observer.decisionUnsettledRowSet(), .absent, "an empty queue is a complete empty answer")

        XCTAssertTrue(queue.upsert(store("waiting", state: .queuedForUpload)))
        XCTAssertTrue(queue.upsert(store("done", state: .completed)))
        guard case .found(let rows) = observer.decisionUnsettledRowSet() else {
            return XCTFail("a waiting row is found")
        }
        XCTAssertEqual(rows.map(\.source.identifier), ["waiting"], "a settled row is not unsettled")

        let fault = try SQLiteStatementFaults(in: queue!) { $0.contains("state NOT IN ('alreadyBackedUp'") }
        XCTAssertEqual(observer.decisionUnsettledRowSet(), .unknown, "a failed read is no empty queue")
        fault.stop()
        XCTAssertGreaterThan(fault.firedCount, 0)
    }

    /// A store that is not the SQLite store can throw any error; the answer is unknown, never no rows.
    func testAThrownErrorOfAnyStoreIsUnknown() {
        let observer: any UploadBackupSyncQueueObserving = ThrowingObserver()
        XCTAssertEqual(observer.decisionRowSet(kind: .photoLibraryAsset, identifiers: ["a"]), .unknown)
        XCTAssertEqual(observer.decisionUnsettledRowSet(), .unknown)
        XCTAssertFalse(observer.holdsNoRows(kind: .photoLibraryAsset, identifiers: ["a"]), "unknown holds no proof")
    }

    func testHoldsNoRowsNeedsACompleteReadWithoutRows() throws {
        XCTAssertTrue(queue.upsert(store("waiting", state: .queuedForUpload)))
        let observer: any UploadBackupSyncQueueObserving = queue
        XCTAssertFalse(observer.holdsNoRows(kind: .photoLibraryAsset, identifiers: ["waiting"]))
        XCTAssertTrue(observer.holdsNoRows(kind: .photoLibraryAsset, identifiers: ["missing"]))
        let fault = try SQLiteStatementFaults(in: queue!) {
            $0.contains("SELECT source_kind, source_id, resource, revision_us, state, original_filename")
        }
        XCTAssertFalse(observer.holdsNoRows(kind: .photoLibraryAsset, identifiers: ["missing"]))
        fault.stop()
    }
}

private struct ThrowingObserver: UploadBackupSyncQueueObserving {
    struct Failure: Error {}
    func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?) {}
    func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] { [:] }
    func decisionRows(kind: UploadSourceIdentity.Kind, identifiers: Set<String>) throws -> [UploadBackupQueueRowState] {
        throw Failure()
    }
    func decisionUnsettledRows() throws -> [UploadBackupQueueRowState] { throw Failure() }
}
