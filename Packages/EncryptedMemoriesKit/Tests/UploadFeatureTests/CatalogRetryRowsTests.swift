import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

final class CatalogRetryRowsTests: XCTestCase {
    private var directory: URL!
    private var store: PhotoLibraryCatalogManifestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        XCTAssertTrue(store.upsertBatch(["a", "b", "c", "d"].map { entry($0) }))
        try setUnknown(true)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testLateRenderEventsRetryOnlyUnknownRowsThenProcessTheRepairedRow() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d"])
        XCTAssertEqual(store.lateRenderSweepResumePoint(), "a")

        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d"], "healthy edits are not offered again")
        XCTAssertFalse(store.hasReconciledLateRenders(), "an unknown row stays owed")

        try setUnknown(false)
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d", "b"], "the repaired row is processed once")
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    func testMissingSourceEventsRetryOnlyUnknownRowsThenProcessTheRepairedRow() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d"])

        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d"], "healthy rows are not offered again")
        XCTAssertNil(store.reconciledMissingSourceGeneration())

        try setUnknown(false)
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d", "b"])
        XCTAssertEqual(store.reconciledMissingSourceGeneration(), engine.generation)
    }

    func testRemovedUnknownRowLetsTheLateRenderPassComplete() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertTrue(store.markRemoved(["b"], removedAt: Date()).succeeded)
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d"])
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    func testCancelledWalkDoesNotForgetTheHealthyTail() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        engine.failure = CancellationError()
        do {
            try await sync.reconcileLateRendersOnce(engine: engine)
            XCTFail("the first walk stops at c")
        } catch is CancellationError {}
        engine.failure = nil
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "c", "d"], "the unfinished tail still needs its walk")
        XCTAssertFalse(store.hasReconciledLateRenders())
    }

    func testUnavailableProofDoesNotForgetTheHealthyTail() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        engine.failure = UploadBackupRemoteProofUnavailable()
        try await sync.reconcileLateRendersOnce(engine: engine)
        engine.failure = nil
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "c", "d"])
        XCTAssertFalse(store.hasReconciledLateRenders())
    }

    func testUndecodablePayloadIsUnknownWithoutASQLReadFailure() {
        let presence = store.presence(for: ["a", "b", "absent"])
        XCTAssertEqual(presence.unknown, ["b"])
        XCTAssertEqual(Set(presence.present.keys), ["a"])
        XCTAssertFalse(presence.readFailed)
        XCTAssertTrue(store.isOperational())
    }

    func testFailedPrepareSetsReadFailedAndKeepsRequestedRowsUnknown() throws {
        try withSQLiteAuthorization(
            in: store as PhotoLibraryCatalogManifestStore,
            authorizing: { operation, table, _ in
                operation == SQLITE_READ && table == "photo_catalog" ? SQLITE_DENY : SQLITE_OK
            },
            {
                let presence = store.presence(for: ["a", "b"])
                XCTAssertTrue(presence.readFailed)
                XCTAssertEqual(presence.unknown, ["a", "b"])
                XCTAssertTrue(presence.present.isEmpty)
            })
    }

    func testFailedBindSetsReadFailedAndKeepsRequestedRowUnknown() throws {
        let connection = try storeConnection(store as PhotoLibraryCatalogManifestStore)
        let previous = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        defer { connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, previous) } }
        let id = String(repeating: "x", count: 128)
        let presence = store.presence(for: [id])
        XCTAssertTrue(presence.readFailed)
        XCTAssertEqual(presence.unknown, [id])
        XCTAssertTrue(presence.present.isEmpty)
    }

    func testFailedStepSetsReadFailedEvenAfterTheStoreRecovers() throws {
        let fault = try SQLiteStatementFaults(in: store as PhotoLibraryCatalogManifestStore, failures: 1) {
            $0.contains("FROM photo_catalog WHERE local_id=")
        }
        defer { fault.stop() }
        let presence = store.presence(for: ["a"])
        fault.stop()
        XCTAssertEqual(fault.firedCount, 1)
        XCTAssertTrue(store.isOperational())
        XCTAssertTrue(presence.readFailed)
        XCTAssertEqual(presence.unknown, ["a"])
        XCTAssertTrue(presence.present.isEmpty)
    }

    func testFailedRetryReadThrowsBeforeProcessingOrCompletingThenRetriesTheRow() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileLateRendersOnce(engine: engine)
        try setUnknown(false)
        let fault = try SQLiteStatementFaults(in: store as PhotoLibraryCatalogManifestStore, failures: 1) {
            $0.contains("FROM photo_catalog WHERE local_id=")
        }
        defer { fault.stop() }
        do {
            try await sync.reconcileLateRendersOnce(engine: engine)
            XCTFail("a failed retry read must throw, even after the health probe recovers")
        } catch {
            XCTAssertEqual(error as? UploadError, .backend("Photo library catalog could not be read"))
        }
        fault.stop()
        XCTAssertEqual(fault.firedCount, 1)
        XCTAssertFalse(store.hasReconciledLateRenders())
        XCTAssertEqual(engine.reopened, ["a", "c", "d"])
        XCTAssertTrue(store.isOperational(), "the transient read failure can recover")
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d", "b"])
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    func testNewDiscardGenerationRestartsBeforeTheSavedCheckpoint() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileMissingSources(engine: engine)
        engine.generation += 1
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d", "a", "c", "d"])
        XCTAssertNil(store.reconciledMissingSourceGeneration())
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d", "a", "c", "d"])
    }

    func testFreshRetryMemoryWalksFromTheDurableCheckpoint() async throws {
        let engine = RetryEnqueuer()
        try await PhotoLibraryCatalogSync(store: store, chunkSize: 1).reconcileLateRendersOnce(engine: engine)
        try await PhotoLibraryCatalogSync(store: store, chunkSize: 1).reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "c", "d", "c", "d"])
        XCTAssertFalse(store.hasReconciledLateRenders())
    }

    func testPassesKeepSeparateRetryRows() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileLateRendersOnce(engine: engine)
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d"], "the sweep still needs its first walk")
    }

    func testAnAbsentRetryBatchDoesNotHideALaterRetryRow() async throws {
        try setUnknown(true, id: "c")
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "d"])
        XCTAssertTrue(store.markRemoved(["b"], removedAt: Date()).succeeded)
        try setUnknown(false, id: "c")
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "d", "c"])
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    func testFailedGenerationResetStillRestartsBeforeTheSavedCheckpoint() async throws {
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        let engine = RetryEnqueuer()
        try await sync.reconcileMissingSources(engine: engine)
        engine.generation += 1
        let fault = try SQLiteStatementFaults(in: store as PhotoLibraryCatalogManifestStore, failures: 1) {
            $0.hasPrefix("INSERT INTO photo_catalog_info")
        }
        defer { fault.stop() }
        do {
            try await sync.reconcileMissingSources(engine: engine)
            XCTFail("the generation reset must be durable before the retry rows are forgotten")
        } catch {
            XCTAssertEqual(error as? UploadError, .backend("Photo library catalog could not be updated"))
        }
        fault.stop()
        XCTAssertEqual(fault.firedCount, 1)
        try await sync.reconcileMissingSources(engine: engine)
        XCTAssertEqual(engine.recovered, ["a", "c", "d", "a", "c", "d"])
    }

    func testRepeatedLateRenderEventMakesNoRemoteProofReadsForHealthyRows() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("proof-queue.sqlite")))
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(url: directory.appendingPathComponent("proof-state.sqlite")))
        defer {
            queue.close()
            state.close()
        }
        let preflight = UploadBackupPreflightIndex(store: state)
        let candidates = try ["a", "b", "c", "d"].map {
            try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry($0))))
        }
        try await preflight.markBackedUpBatch(candidates.map(\.snapshot))
        let resolver = RetryProofResolver()
        let engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, remoteProofResolver: resolver)
        let sync = PhotoLibraryCatalogSync(store: store, chunkSize: 1)
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(resolver.readCount, 3, "the first walk reaches the real remote-proof route")
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(resolver.readCount, 3, "a still-unknown row needs no remote proof")
        try setUnknown(false)
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(resolver.readCount, 4, "only the repaired row needs its proof")
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    func testReplayEventsReadOnlyUnknownRowsAndCompleteAfterRepair() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(url: directory.appendingPathComponent("state.sqlite")))
        defer {
            queue.close()
            state.close()
        }
        let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)
        let retryRows = PhotoLibraryCatalogRetryRows()
        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine, retryRows: retryRows)
        XCTAssertEqual(queue.count(), 3)
        let pages = try SQLiteStatementFaults(in: store as PhotoLibraryCatalogManifestStore, fails: false) {
            $0.contains("INDEXED BY sqlite_autoindex_photo_catalog_1")
        }
        defer { pages.stop() }
        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine, retryRows: retryRows)
        XCTAssertEqual(pages.matchedCount, 0, "another event must not walk the catalog again")
        XCTAssertEqual(queue.catalogReplayState(), .inProgress)
        try setUnknown(false)
        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine, retryRows: retryRows)
        XCTAssertEqual(queue.count(), 4)
        XCTAssertEqual(queue.catalogReplayState(), .completed)
    }

    private func entry(_ id: String) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: id, cloudIdentifier: "cloud-\(id)", creationDate: nil,
            modificationDate: Date(timeIntervalSince1970: 100), pixelWidth: 10, pixelHeight: 10,
            durationSeconds: 0, mediaKind: .image, isLivePhoto: false,
            resources: [
                .init(role: "originalPhoto", originalFilename: "\(id).heic", mimeType: "image/heic"),
                .init(role: "fullSizePhoto", originalFilename: "FullSizeRender.JPG", mimeType: "image/jpeg"),
            ], contentFingerprint: 1, metadataRevision: 100, firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 100))
    }

    private func setUnknown(_ unknown: Bool, id: String = "b") throws {
        let connection = try storeConnection(store as PhotoLibraryCatalogManifestStore)
        let healthy = String(decoding: try JSONEncoder().encode(entry(id).resources), as: UTF8.self)
        let value = unknown ? "!" : healthy
        let sql = "UPDATE photo_catalog SET resources_json='\(value)' WHERE local_id='\(id)';"
        XCTAssertEqual(connection.withLock { sqlite3_exec(connection.database, sql, nil, nil, nil) }, SQLITE_OK)
    }
}

private final class RetryProofResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        lock.withLock { reads += 1 }
        return Dictionary(
            uniqueKeysWithValues: identities.map {
                (
                    $0,
                    UploadRemoteAssetIndexRecord(
                        externalIdentity: $0, resourceCount: 2, remoteLinkIDs: ["main", "related"],
                        hashKeyEpoch: "epoch")
                )
            })
    }
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw UploadError.backend("No bytes are needed for catalog reconciliation")
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String
    ) async throws {}
}

private final class RetryEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
    private let lock = NSLock()
    private var reopenedRows: [String] = []
    private var recoveredRows: [String] = []
    var generation: Int64 = 1
    var failure: (any Error)?
    var reopened: [String] { lock.withLock { reopenedRows } }
    var recovered: [String] { lock.withLock { recoveredRows } }

    func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult { .init() }
    func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate] {
        let ids = reopenings.map(\.candidate.snapshot.source.identifier)
        lock.withLock { reopenedRows += ids }
        if ids.contains("c"), let failure { throw failure }
        return []
    }
    func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        lock.withLock { recoveredRows += candidates.map(\.snapshot.source.identifier) }
    }
    func missingSourceDiscardGeneration() async throws -> Int64 { generation }
    func synchronizeQueueToDisk() async -> Bool { true }
}
