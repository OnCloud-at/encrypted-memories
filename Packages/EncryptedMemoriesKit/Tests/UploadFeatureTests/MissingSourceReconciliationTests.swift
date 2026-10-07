import Foundation
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

final class MissingSourceReconciliationTests: XCTestCase {
    private var directory: URL!
    private var catalog: PhotoLibraryCatalogManifestStore!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var state: UploadBackupStateManifestStore!
    private var exclusions: PendingBackupManifestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openStores()
    }

    override func tearDownWithError() throws {
        closeStores()
        try FileManager.default.removeItem(at: directory)
    }

    private func openStores() throws {
        catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(url: url(PhotoLibraryCatalogManifestStore.databaseFileName)))
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: url(UploadBackupSyncQueueManifestStore.databaseFileName)))
        state = try XCTUnwrap(UploadBackupStateManifestStore(url: url(UploadBackupStateManifestStore.databaseFileName)))
        exclusions = try XCTUnwrap(PendingBackupManifestStore(url: url(PendingBackupManifestStore.databaseFileName)))
    }

    private func closeStores() {
        catalog?.close()
        queue?.close()
        state?.close()
        exclusions?.close()
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func candidate(_ id: String, save: Bool = true) throws -> UploadBackupAssetCandidate {
        let info = PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: Date(timeIntervalSince1970: 100),
            modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "\(id).jpg", mimeType: "image/jpeg")],
            cloudIdentifier: "cloud-\(id)")
        if save {
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
        }
        return try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
    }

    private func row(
        _ candidate: UploadBackupAssetCandidate, state: UploadBackupSyncQueueState = .discovered
    )
        -> UploadBackupSyncQueueEntry
    {
        UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source, revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename, state: state, updatedAt: Date(timeIntervalSince1970: 300))
    }

    private func engine(proof: ProofSpy? = nil) -> UploadBackupSyncEngine {
        UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: state), queue: queue,
            remoteProofResolver: proof, exclusions: exclusions)
    }

    func testOnlyPresentUnbackedSourcesWithoutAnyQueueRowReturnAndTheSweepReadsNoRemoteProof() async throws {
        let missing = try candidate("missing")
        let complete = try candidate("complete")
        let excluded = try candidate("excluded")
        let deleted = try candidate("deleted")
        let removed = try candidate("removed")
        let parked = try candidate("parked")
        let pending = try candidate("pending")
        let preflight = UploadBackupPreflightIndex(store: state)
        try await preflight.markBackedUp(complete.snapshot)
        try await preflight.markPending(pending.snapshot)
        XCTAssertTrue(catalog.markRemoved([removed.snapshot.source.identifier], removedAt: Date()).succeeded)
        XCTAssertNotNil(
            exclusions.exclude(
                [excluded, deleted].map {
                    PendingExclusionRequest(key: PendingSourceKey($0.snapshot.source), presentation: nil, remote: nil)
                }, at: Date()))
        let parkedRow = row(parked, state: .failedPermanent)
        XCTAssertTrue(queue.upsert(parkedRow))
        let proof = ProofSpy()
        let sync = PhotoLibraryCatalogSync(store: catalog, chunkSize: 2)
        try await sync.reconcileMissingSources(engine: engine(proof: proof))
        XCTAssertEqual(queue.count(), 3)
        for candidate in [missing, pending] {
            XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        }
        for candidate in [complete, excluded, deleted, removed] {
            XCTAssertNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        }
        XCTAssertEqual(queue.entry(for: parked.snapshot.source, revision: parked.snapshot.revision), parkedRow)
        XCTAssertEqual(proof.calls, 0)
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 0)
        // The upgrade sweep runs once: an ordinary removal does not invent another sweep.
        XCTAssertTrue(queue.remove(source: missing.snapshot.source, revision: missing.snapshot.revision))
        try await sync.reconcileMissingSources(engine: engine(proof: proof))
        XCTAssertNil(queue.entry(for: missing.snapshot.source, revision: missing.snapshot.revision))
    }

    func testCancelledSweepResumesAfterItsDurablePageAndDoesNotLoseALaterDropBehindTheCursor() async throws {
        let a = try candidate("A")
        _ = try candidate("B")
        _ = try candidate("C")
        let first = PageEnqueuer(inner: engine(), cancelAfterPage: 1)
        let interruptedCatalog = try XCTUnwrap(catalog)
        do {
            try await Task {
                try await PhotoLibraryCatalogSync(store: interruptedCatalog, chunkSize: 1).reconcileMissingSources(
                    engine: first)
            }.value
            XCTFail("The interrupted sweep must stop")
        } catch is CancellationError {}
        XCTAssertEqual(catalog.missingSourceSweepProgress()?.afterLocalIdentifier, "A")
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertTrue(queue.removeMissingSource(source: a.snapshot.source, revision: a.snapshot.revision))
        closeStores()
        try openStores()
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 1)
        let resumed = PageEnqueuer(inner: engine())
        let sync = PhotoLibraryCatalogSync(store: catalog, chunkSize: 1)
        try await sync.reconcileMissingSources(engine: resumed)
        XCTAssertEqual(resumed.firstIdentifiers, ["B", "C"])
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 0)
        XCTAssertNil(catalog.missingSourceSweepProgress())
        try await sync.reconcileMissingSources(engine: resumed)
        XCTAssertEqual(resumed.firstIdentifiers, ["B", "C", "A", "B", "C"])
        XCTAssertNotNil(queue.entry(for: a.snapshot.source, revision: a.snapshot.revision))
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 1)
        XCTAssertEqual(queue.count(), 3)
    }

    func testAFailedInsertDoesNotAdvanceThePageAndRelaunchRetriesIt() async throws {
        let candidate = try candidate("missing")
        try sql(
            url(UploadBackupSyncQueueManifestStore.databaseFileName),
            """
            CREATE TRIGGER deny_insert BEFORE INSERT ON backup_sync_queue
            BEGIN SELECT RAISE(ABORT, 'write unavailable'); END;
            """)
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("A failed queue insert must stop the sweep")
        } catch {}
        XCTAssertNil(catalog.missingSourceSweepProgress()?.afterLocalIdentifier)
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        closeStores()
        try sql(url(UploadBackupSyncQueueManifestStore.databaseFileName), "DROP TRIGGER deny_insert;")
        try openStores()
        try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
        XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
    }

    func testUnreadableExclusionsOrStateKeepTheSweepPending() async throws {
        _ = try candidate("missing")
        exclusions.close()
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("Unknown exclusions must stop recovery")
        } catch {}
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertEqual(queue.count(), 0)
        closeStores()
        try openStores()
        state.close()
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("Unknown backup state must stop recovery")
        } catch {}
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertEqual(queue.count(), 0)
    }

    func testConditionalInsertKeepsAQueueRowAddedBeforeTheRecoveryWrite() throws {
        let candidate = try candidate("existing")
        var newer = row(candidate, state: .skippedRemoteDeletion)
        newer.revision = UploadBackupRevision(rawValue: candidate.snapshot.revision.rawValue + 1)
        newer.lastError = "kept user decision"
        XCTAssertTrue(queue.upsert(newer))
        XCTAssertTrue(queue.insertMissingSources([row(candidate)]))
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.entry(for: newer.source, revision: newer.revision), newer)
        XCTAssertNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
    }

    func testFailedDiscardGenerationWriteRollsBackTheRemoval() throws {
        let candidate = try candidate("missing")
        XCTAssertTrue(queue.upsert(row(candidate)))
        try sql(
            url(UploadBackupSyncQueueManifestStore.databaseFileName),
            """
            CREATE TRIGGER deny_generation BEFORE INSERT ON backup_sync_queue_info
            WHEN NEW.key='missing_source_discard_generation'
            BEGIN SELECT RAISE(ABORT, 'write unavailable'); END;
            """)
        XCTAssertFalse(
            queue.removeMissingSource(source: candidate.snapshot.source, revision: candidate.snapshot.revision))
        queue.close()
        // Remove the injected trigger before the exact-schema store opens again.
        try sql(url(UploadBackupSyncQueueManifestStore.databaseFileName), "DROP TRIGGER deny_generation;")
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: url(UploadBackupSyncQueueManifestStore.databaseFileName)))
        XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    @MainActor
    func testA100000PhotoLibraryUsesBoundedPagesOffTheMainThread() async throws {
        for start in stride(from: 0, to: 100_000, by: 200) {
            let candidates = try (start..<min(start + 200, 100_000)).map {
                try candidate(String(format: "%06d", $0), save: false)
            }
            let entries = candidates.map { candidate in
                // The catalog input uses the same plain metadata as the planner, without PhotoKit.
                PhotoLibraryCatalogEntry(
                    localIdentifier: candidate.snapshot.source.identifier,
                    creationDate: Date(timeIntervalSince1970: 100),
                    modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
                    durationSeconds: 0, mediaKind: .image, isLivePhoto: false,
                    resources: [
                        .init(
                            role: "originalPhoto", originalFilename: candidate.originalFilename, mimeType: "image/jpeg")
                    ],
                    contentFingerprint: 0, metadataRevision: candidate.snapshot.revision.rawValue,
                    firstSeenAt: Date(), lastSeenAt: Date())
            }
            XCTAssertTrue(catalog.upsertBatch(entries))
            XCTAssertTrue(
                state.upsertBatch(
                    candidates.filter {
                        $0.snapshot.source.identifier != "000000" && $0.snapshot.source.identifier != "099999"
                    }.map {
                        UploadBackupAssetRecord(
                            source: $0.snapshot.source, revision: $0.snapshot.revision,
                            resourceCount: 1, pendingResourceCount: 0, updatedAt: Date())
                    }))
        }
        let tracked = PageCatalog(inner: catalog)
        let enqueuer = PageEnqueuer(inner: engine())
        try await PhotoLibraryCatalogSync(store: tracked, chunkSize: 200).reconcileMissingSources(engine: enqueuer)
        XCTAssertEqual(tracked.pages, 501)
        XCTAssertEqual(tracked.maximumPageSize, 200)
        XCTAssertFalse(tracked.usedMainThread)
        XCTAssertEqual(enqueuer.firstIdentifiers.count, 500)
        XCTAssertEqual(queue.count(), 2)
        XCTAssertEqual(queue.nextRunnable(limit: 2).map(\.source.identifier).sorted(), ["000000", "099999"])
    }

    private func sql(_ url: URL, _ statement: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, statement, nil, nil, nil), SQLITE_OK)
    }

    private final class ProofSpy: UploadIdentityResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw UploadError.backend("Unexpected byte read")
        }
        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws
            -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
        {
            lock.withLock { count += 1 }
            return [:]
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity,
            remoteVolumeID: String, remoteLinkID: String
        ) async throws {}
    }

    private final class PageEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        let inner: UploadBackupSyncEngine
        let cancelAfterPage: Int?
        private let lock = NSLock()
        private var identifiers: [String] = []
        var firstIdentifiers: [String] { lock.withLock { identifiers } }
        init(inner: UploadBackupSyncEngine, cancelAfterPage: Int? = nil) {
            self.inner = inner
            self.cancelAfterPage = cancelAfterPage
        }
        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            XCTFail("Recovery must use the local-only batch path")
            return UploadBackupSyncScanResult()
        }
        func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
            try await inner.enqueueMissingSources(candidates)
            let count = lock.withLock {
                identifiers.append(candidates.first?.snapshot.source.identifier ?? "")
                return identifiers.count
            }
            if count == cancelAfterPage { withUnsafeCurrentTask { $0?.cancel() } }
        }
        func missingSourceDiscardGeneration() async throws -> Int64 { try await inner.missingSourceDiscardGeneration() }
        func synchronizeQueueToDisk() async -> Bool { await inner.synchronizeQueueToDisk() }
    }

    private final class PageCatalog: PhotoLibraryCatalogStore, @unchecked Sendable {
        let inner: PhotoLibraryCatalogManifestStore
        private let lock = NSLock()
        private var metrics = (pages: 0, maximum: 0, main: false)
        var pages: Int { lock.withLock { metrics.pages } }
        var maximumPageSize: Int { lock.withLock { metrics.maximum } }
        var usedMainThread: Bool { lock.withLock { metrics.main } }
        init(inner: PhotoLibraryCatalogManifestStore) { self.inner = inner }
        func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry] {
            let page = inner.presentEntries(afterLocalIdentifier: afterLocalIdentifier, limit: limit)
            lock.withLock {
                metrics.pages += 1
                metrics.maximum = max(metrics.maximum, page.count)
                metrics.main = metrics.main || Thread.isMainThread
            }
            return page
        }
        func isOperational() -> Bool { inner.isOperational() }
        func reconciledMissingSourceGeneration() -> Int64? { inner.reconciledMissingSourceGeneration() }
        func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress? {
            inner.missingSourceSweepProgress()
        }
        func recordMissingSourceSweepProgress(_ p: PhotoLibraryMissingSourceSweepProgress) -> Bool {
            inner.recordMissingSourceSweepProgress(p)
        }
        func completeMissingSourceSweep(generation: Int64) -> Bool {
            inner.completeMissingSourceSweep(generation: generation)
        }
        func entry(for id: String) -> PhotoLibraryCatalogEntry? { inner.entry(for: id) }
        func classify(_ e: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange { inner.classify(e) }
        func upsert(_ e: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange { inner.upsert(e) }
        func upsertBatch(_ e: [PhotoLibraryCatalogEntry]) -> Bool { inner.upsertBatch(e) }
        func markRemoved(_ ids: [String], removedAt: Date) -> PhotoLibraryCatalogMutationResult {
            inner.markRemoved(ids, removedAt: removedAt)
        }
        func sweepRemoved(notSeenAfter: Date, removedAt: Date) -> PhotoLibraryCatalogMutationResult {
            inner.sweepRemoved(notSeenAfter: notSeenAfter, removedAt: removedAt)
        }
        func snapshot() -> PhotoLibraryCatalogSnapshot { inner.snapshot() }
        func count() -> Int { inner.count() }
        func hasCompletedFullScan() -> Bool { inner.hasCompletedFullScan() }
        func markFullScanOwed() -> Bool { inner.markFullScanOwed() }
        func synchronizeToDisk() -> Bool { inner.synchronizeToDisk() }
        func fullScanProgress() -> PhotoLibraryFullScanProgress? { inner.fullScanProgress() }
        func recordFullScanProgress(_ p: PhotoLibraryFullScanProgress) -> Bool { inner.recordFullScanProgress(p) }
        func completeFullScan() -> Bool { inner.completeFullScan() }
        func clearFullScanResumePoint() -> Bool { inner.clearFullScanResumePoint() }
        func hasReconciledLateRenders() -> Bool { inner.hasReconciledLateRenders() }
        func markLateRendersReconciled() -> Bool { inner.markLateRendersReconciled() }
        func lateRenderSweepResumePoint() -> String? { inner.lateRenderSweepResumePoint() }
        func recordLateRenderSweepResumePoint(_ id: String) -> Bool { inner.recordLateRenderSweepResumePoint(id) }
        func beginFullScanSnapshot(epochStart: Date) -> Bool { inner.beginFullScanSnapshot(epochStart: epochStart) }
        func appendFullScanSnapshotIdentifiers(_ ids: [String]) -> Bool { inner.appendFullScanSnapshotIdentifiers(ids) }
        func finishFullScanSnapshot() -> Bool { inner.finishFullScanSnapshot() }
        func fullScanSnapshotIdentifiers(startingAt: Int, limit: Int) -> [String] {
            inner.fullScanSnapshotIdentifiers(startingAt: startingAt, limit: limit)
        }
        func fullScanSnapshotCount() -> Int { inner.fullScanSnapshotCount() }
    }
}
