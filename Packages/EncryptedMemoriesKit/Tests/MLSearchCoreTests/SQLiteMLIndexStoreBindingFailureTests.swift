import Foundation
import PhotosCore
import SQLite3
import SQLiteTestSupport
import XCTest

@testable import MLSearchCore

/// Every text and blob bind of the ML index store checks its result (#1194). A failed bind leaves its parameter NULL:
/// an unchecked key or vector bind made INSERT OR IGNORE skip the row and count it as already indexed, a failure clear
/// or a removal matched no row and reported success, a read reported no rows instead of a failed read, and a failure
/// reason was stored as NULL. Each test fails only the binds of the target statement: a value longer than the lowered
/// SQLITE_LIMIT_LENGTH fails with SQLITE_TOOBIG, as a bind that runs out of memory does. A lowered limit also fails the
/// read of a long stored value, so a test that reads such a row lowers the limit only after that read. With the check
/// the statement never steps, and the call gives the answer of a failed statement.
final class SQLiteMLIndexStoreBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 256
    private static let long = String(repeating: "l", count: 512)
    private let descriptor = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 4)
    private let longDescriptor = MLModelDescriptor(identifier: long, version: 1, embeddingDimension: 4)
    private let longUID = PhotoUID(volumeID: long, nodeID: "node")
    private let shortUID = PhotoUID(volumeID: "volume", nodeID: "node")

    private var directory: URL!
    private var store: SQLiteMLIndexStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-index-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(SQLiteMLIndexStore(url: databaseURL, cipher: TestMLVectorCipher()))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent(SQLiteMLIndexStore.databaseFileName) }

    private func record(_ uid: PhotoUID, _ descriptor: MLModelDescriptor) -> MLEmbeddingRecord {
        MLEmbeddingRecord(
            uid: uid, descriptor: descriptor,
            vector: ContiguousArray((0..<descriptor.embeddingDimension).map { Float32($0) / 10 }))
    }

    private func failure(_ uid: PhotoUID, reason: String? = nil) -> MLIndexFailureRecord {
        MLIndexFailureRecord(uid: uid, descriptor: descriptor, kind: .transient, reason: reason, attempts: 1)
    }

    /// Fails the binds of the first statement whose SQL contains `statement` that starts after the first statement whose
    /// SQL contains `earlier` finished, or at once without `earlier`.
    private func failBinds(of statement: String, after earlier: String? = nil) throws -> BindFailureUntilStep {
        let fault = BindFailureUntilStep(
            onDatabase: try XCTUnwrap(storeDatabase(store!)), statement: statement, after: earlier, limit: Self.limit)
        if earlier == nil { XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply") }
        return fault
    }

    private func readAllBlocks(_ descriptor: MLModelDescriptor, maximumRows: Int) throws -> [PhotoUID] {
        var uids: [PhotoUID] = []
        try store.forEachVectorBlock(for: descriptor, maximumRows: maximumRows) { uids += $0.uids }
        return uids
    }

    // MARK: Writes

    func testUpsertWithAKeyThatDoesNotBindIsATransientFailureNotAnIndexedRow() throws {
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_embeddings")
        defer { fault.remove() }
        let report = store.upsert([record(longUID, descriptor)])
        XCTAssertEqual(report.skippedAlreadyIndexed, 0, "A row that was never written is not already indexed")
        XCTAssertEqual(report.transientFailure, 1)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testUpsertWithAVectorThatDoesNotBindIsATransientFailureNotAnIndexedRow() throws {
        let wide = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 256)
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_embeddings")
        defer { fault.remove() }
        let report = store.upsert([record(shortUID, wide)])
        XCTAssertEqual(report.skippedAlreadyIndexed, 0, "A row that was never written is not already indexed")
        XCTAssertEqual(report.transientFailure, 1)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    /// A record whose key does not bind fails alone: the batch goes on and stores the next record. The fault ends when
    /// the first insert steps, so only the first record of the batch fails to bind.
    func testUpsertWithAKeyThatDoesNotBindFailsOnlyThatRecord() throws {
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_embeddings")
        defer { fault.remove() }
        let report = store.upsert([record(longUID, descriptor), record(shortUID, descriptor)])
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(report.transientFailure, 1)
        fault.remove()
        XCTAssertEqual(try store.indexedUIDs(for: descriptor, from: [shortUID, longUID]), [shortUID])
    }

    /// A record whose vector does not bind fails alone, like a record whose key does not bind.
    func testUpsertWithAVectorThatDoesNotBindFailsOnlyThatRecord() throws {
        let wide = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 256)
        let wideUID = PhotoUID(volumeID: "volume", nodeID: "wide")
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_embeddings")
        defer { fault.remove() }
        let report = store.upsert([record(wideUID, wide), record(shortUID, descriptor)])
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(report.transientFailure, 1)
        fault.remove()
        XCTAssertEqual(try store.indexedUIDs(for: descriptor, from: [shortUID]), [shortUID])
        XCTAssertEqual(try store.indexedUIDs(for: wide, from: [wideUID]), [])
    }

    func testUpsertWithAKeyThatDoesNotBindInTheFailureClearFailsTheBatch() throws {
        XCTAssertTrue(store.recordFailures([failure(longUID)]))
        let fault = try failBinds(
            of: "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=? AND volume_id",
            after: "INSERT OR IGNORE INTO ml_embeddings")
        defer { fault.remove() }
        let report = store.upsert([record(longUID, descriptor)])
        XCTAssertEqual(report.indexed, 0, "An indexed row must not keep its failure record")
        XCTAssertEqual(report.transientFailure, 1)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testUpsertWithADescriptorThatDoesNotBindFailsTheGenerationBump() throws {
        let fault = try failBinds(
            of: "INSERT INTO ml_epoch_state",
            after: "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=? AND volume_id")
        defer { fault.remove() }
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 0)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testRemoveAllWithADescriptorThatDoesNotBindFailsAndKeepsTheVectors() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "DELETE FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertFalse(store.removeAll(for: longDescriptor), "A removal that matched no row removed nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.count(for: longDescriptor), 1)
    }

    func testRemoveAllWithADescriptorThatDoesNotBindInTheFailureDeleteFails() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "DELETE FROM ml_failures", after: "DELETE FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertFalse(store.removeAll(for: longDescriptor), "A removal that matched no failure row is not complete")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.count(for: longDescriptor), 1, "The failed removal rolls back")
    }

    func testRecordFailuresWithAReasonThatDoesNotBindFailsInsteadOfStoringNull() throws {
        let fault = try failBinds(of: "INSERT INTO ml_failures")
        defer { fault.remove() }
        XCTAssertFalse(
            store.recordFailures([failure(shortUID, reason: Self.long)]),
            "A reason that does not bind must not be stored as NULL")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    // MARK: Reads

    func testIndexedUIDsWithAKeyThatDoesNotBindIsAReadFailure() throws {
        XCTAssertEqual(store.upsert([record(longUID, descriptor)]).indexed, 1)
        let fault = try failBinds(of: "SELECT volume_id, node_id FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try store.indexedUIDs(for: descriptor, from: [longUID]), "A key that does not bind is no proof of absence")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testGenerationWithADescriptorThatDoesNotBindDoesNotRunTheRead() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "SELECT generation FROM ml_epoch_state")
        defer { fault.remove() }
        XCTAssertEqual(store.generation(for: longDescriptor), 0)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testFailureRecordsWithAKeyThatDoesNotBindIsAReadFailure() throws {
        XCTAssertTrue(store.recordFailures([failure(longUID)]))
        let fault = try failBinds(of: "SELECT volume_id, node_id, kind, reason")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try store.failureRecords(for: descriptor, from: [longUID]),
            "A key that does not bind is no proof of absence")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testVectorBlocksWithADescriptorThatDoesNotBindAreAReadFailure() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "SELECT volume_id, node_id, vector FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try readAllBlocks(longDescriptor, maximumRows: 10), "A descriptor that does not bind is no empty index")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testVectorBlocksWithACursorThatDoesNotBindAreAReadFailure() throws {
        let first = PhotoUID(volumeID: Self.long, nodeID: "a")
        let second = PhotoUID(volumeID: Self.long, nodeID: "b")
        XCTAssertEqual(store.upsert([record(first, descriptor), record(second, descriptor)]).indexed, 2)
        let fault = try failBinds(
            of: "AND (volume_id, node_id) > (?, ?)", after: "SELECT volume_id, node_id, vector FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try readAllBlocks(descriptor, maximumRows: 1), "A cursor that does not bind is no end of the index")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testReconcileWithADescriptorThatDoesNotBindInTheTrackedReadFails() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "UNION")
        defer { fault.remove() }
        XCTAssertFalse(
            store.reconcileTrackedUIDs(
                currentAuthoritativeUIDs: [], previousAuthoritativeUIDs: nil, descriptor: longDescriptor),
            "A tracked read that does not bind is no proof that nothing is tracked")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testReconcileWithAKeyThatDoesNotBindInTheRowDeleteFailsAndKeepsTheVector() throws {
        XCTAssertEqual(store.upsert([record(longUID, descriptor)]).indexed, 1)
        let fault = try failBinds(of: "DELETE FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertFalse(
            store.reconcileTrackedUIDs(
                currentAuthoritativeUIDs: [], previousAuthoritativeUIDs: [longUID], descriptor: descriptor),
            "A removal that matched no row removed nothing")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(store.count(for: descriptor), 1)
    }

    func testCountWithADescriptorThatDoesNotBindDoesNotRunTheRead() throws {
        XCTAssertEqual(store.upsert([record(shortUID, longDescriptor)]).indexed, 1)
        let fault = try failBinds(of: "SELECT count FROM ml_embedding_count")
        defer { fault.remove() }
        XCTAssertEqual(store.count(for: longDescriptor), 0)
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testInvalidRowCleanupWithAKeyThatDoesNotBindDoesNotRunTheDelete() throws {
        XCTAssertEqual(store.upsert([record(longUID, descriptor)]).indexed, 1)
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &other), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(other, "UPDATE ml_embeddings SET vector=x'00';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(other)
        let fault = try failBinds(
            of: "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id",
            after: "SELECT volume_id, node_id, vector FROM ml_embeddings")
        defer { fault.remove() }
        XCTAssertEqual(try readAllBlocks(descriptor, maximumRows: 10), [], "An unreadable vector is never served")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }
}
