import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// A keyed decision read answers found, absent or unknown. Unknown never proves the row absent (#1153).
final class QueueTypedDecisionReadTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "existing")
    private let missing = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "missing")
    private let revision = UploadBackupRevision(rawValue: 1)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue")))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func row(state: UploadBackupSyncQueueState = .discovered) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source, revision: revision, originalFilename: "photo.heic", state: state,
            lastError: "kept reason", updatedAt: Date(timeIntervalSince1970: 1_720_000_000))
    }

    func testTheKeyedReadDistinguishesFoundAbsentAndUnknown() throws {
        let stored = row()
        XCTAssertTrue(queue.upsert(stored))
        let store: any UploadBackupSyncQueueStore = queue
        XCTAssertEqual(try store.decisionEntry(for: source, revision: revision), .found(stored))
        XCTAssertEqual(try store.decisionEntry(for: missing, revision: revision), .absent)

        let fault = try SQLiteReadInterrupt(in: queue!, matching: "SELECT original_filename, byte_count, state")
        XCTAssertEqual(try store.decisionEntry(for: source, revision: revision), .unknown)
        fault.stop()
        XCTAssertTrue(fault.fired)
        XCTAssertTrue(queue.isOperational(), "the interrupted read is forgotten once the database answers")
        XCTAssertEqual(try store.decisionEntry(for: source, revision: revision), .found(stored))
    }

    /// The engine keeps a foreign error of the read, a cancellation for example, and never turns it into an unknown row.
    func testAnErrorOtherThanAFailedReadPropagatesThroughTheEngine() async throws {
        XCTAssertTrue(queue.upsert(row()))
        let wrapper = SpyQueueStore(inner: queue, log: BackupEventLog())
        wrapper.entryReadFailure = CancellationError()

        let snapshot = UploadBackupAssetSnapshot(
            source: source, revision: revision, editRevision: .unavailable, resourceCount: 1, externalIdentity: nil)
        let candidate = UploadBackupAssetCandidate(snapshot: snapshot, originalFilename: "photo.heic", byteCount: 1024)
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStateStore()), queue: wrapper)
        do {
            try await engine.enqueueChangedMissingSources([candidate])
            XCTFail("a foreign read error must stop the decision")
        } catch {
            XCTAssertTrue(error is CancellationError, "the engine keeps the error: \(error)")
        }
    }

    func testDismissingAProblemRefusesAnUnknownRowAndKeepsItsRecord() throws {
        let stored = row(state: .failed)
        XCTAssertTrue(queue.upsert(stored))
        let wrapper = SpyQueueStore(inner: queue, log: BackupEventLog(), unknownEntryReads: 1)
        let later = Date(timeIntervalSince1970: 1_720_000_100)
        XCTAssertFalse(
            wrapper.dismissPermanentFailure(source: source, revision: revision, updatedAt: later),
            "an unread row is not dismissed")
        XCTAssertEqual(try queue.entry(for: source, revision: revision), stored)
        XCTAssertTrue(wrapper.dismissPermanentFailure(source: source, revision: revision, updatedAt: later))
        let dismissed = try XCTUnwrap(try queue.entry(for: source, revision: revision))
        XCTAssertEqual(dismissed.state, .dismissedFailure)
        XCTAssertEqual(dismissed.lastError, "kept reason", "the dismissed row keeps its record")
        XCTAssertFalse(
            wrapper.dismissPermanentFailure(source: missing, revision: revision, updatedAt: later),
            "a missing row is not dismissed")
    }
}
