import Foundation
import SQLite3
import XCTest

@testable import UploadCore

final class UploadBackupSyncQueueTests: XCTestCase {
    private struct RemoteProofResolver: UploadIdentityResolving {
        let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]

        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
            proofs.filter { identities.contains($0.key) }
        }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw UploadError.backend("byte resolver must not run during discovery")
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor,
            identity: UploadIdentity,
            remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {}
    }

    private struct CancellingProofResolver: UploadIdentityResolving {
        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
            throw CancellationError()
        }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw CancellationError()
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor,
            identity: UploadIdentity,
            remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {}
    }

    private struct StaticCatalog: UploadBackupAssetCatalog {
        let items: [UploadBackupAssetCandidate]

        func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
            AsyncThrowingStream { continuation in
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    private final class MemoryBackupStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
            return true
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-sync-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func source(_ id: String, resource: UploadSourceIdentity.Resource = .primary) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: resource)
    }

    private func candidate(
        id: String,
        revision seconds: TimeInterval,
        editRevision: UploadBackupEditRevision = .unavailable,
        resource: UploadSourceIdentity.Resource = .primary,
        externalIdentity: UploadBackupExternalIdentity? = nil,
        resourceCount: Int = 1
    ) -> UploadBackupAssetCandidate {
        let snapshot = UploadBackupAssetSnapshot(
            source: source(id, resource: resource),
            revision: revision(seconds),
            editRevision: editRevision,
            resourceCount: resourceCount,
            externalIdentity: externalIdentity
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: "IMG_\(id).HEIC",
            byteCount: 1024
        )
    }

    func testSQLiteQueueRoundTripsAndOrdersRunnableWork() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            byteCount: 10,
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = UploadBackupSyncQueueEntry(
            source: source("new"),
            revision: revision(20),
            originalFilename: "new.heic",
            byteCount: nil,
            state: .checking,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let done = UploadBackupSyncQueueEntry(
            source: source("done"),
            revision: revision(30),
            originalFilename: "done.heic",
            state: .completed,
            updatedAt: Date(timeIntervalSince1970: 5)
        )

        store.upsert(newer)
        store.upsert(done)
        store.upsert(old)

        XCTAssertEqual(store.entry(for: old.source, revision: old.revision), old)
        XCTAssertEqual(store.nextRunnable(limit: 2).map(\.source.identifier), ["old"])
        XCTAssertEqual(store.summary().total, 3)
        XCTAssertEqual(store.summary().waiting, 1)
        XCTAssertEqual(store.summary().active, 1)
        XCTAssertEqual(store.summary().uploaded, 1)
    }

    func testRemoteCommitReconciliationSurvivesReopenAndClaimsWithoutLosingReceipt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let entry = UploadBackupSyncQueueEntry(
            source: source("committed"),
            revision: revision(10),
            originalFilename: "committed.heic",
            state: .uploading,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "content-hash"
            ),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link")
        )

        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            XCTAssertTrue(
                store.markNeedsRemoteReconciliation(
                    source: entry.source,
                    revision: entry.revision,
                    reconciliation: reconciliation,
                    lastError: "manifest unavailable",
                    updatedAt: Date(timeIntervalSince1970: 11)
                ))
        }

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let pending = try XCTUnwrap(reopened.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertEqual(pending.remoteCommitReconciliation, reconciliation)
        let claimed = try XCTUnwrap(
            reopened.claimRunnable(
                limit: 1,
                claimedAt: Date(timeIntervalSince1970: 12)
            ).first)
        XCTAssertEqual(claimed.state, .needsRemoteReconciliation)
        XCTAssertEqual(claimed.remoteCommitReconciliation, reconciliation)
        XCTAssertEqual(
            reopened.entry(for: entry.source, revision: entry.revision)?.state,
            .checking
        )
    }

    func testQueueWideRuntimeIssueSurvivesReopenAndClearsExplicitly() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let expected = BackupIssueRecord(
            kind: .network,
            detail: "remote index unavailable",
            nextAttemptAt: Date(timeIntervalSinceReferenceDate: 123)
        )
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.setRuntimeIssue(expected, for: .remoteIndexPreparation))
            XCTAssertEqual(store.runtimeIssue(for: .remoteIndexPreparation), expected)
        }
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(reopened.runtimeIssue(for: .remoteIndexPreparation), expected)
        XCTAssertTrue(reopened.setRuntimeIssue(nil, for: .remoteIndexPreparation))
        XCTAssertNil(reopened.runtimeIssue(for: .remoteIndexPreparation))
    }

    func testCatalogReplayStateSurvivesReopenAndDistinguishesInterruptedRecovery() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertEqual(store.catalogReplayState(), .notStarted)
            XCTAssertTrue(store.setCatalogReplayState(.inProgress))
            XCTAssertEqual(store.catalogReplayState(), .inProgress)
        }

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(reopened.catalogReplayState(), .inProgress, "an interrupted rebuild must resume after relaunch")
        XCTAssertTrue(reopened.setCatalogReplayState(.completed))
        XCTAssertEqual(reopened.catalogReplayState(), .completed)
    }

    func testSQLiteQueueBatchRollsBackCompletelyWhenOneRowFails() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                """
                CREATE TRIGGER reject_bad_queue_row
                BEFORE INSERT ON backup_sync_queue
                WHEN NEW.source_id='bad'
                BEGIN SELECT RAISE(ABORT, 'test failure'); END;
                """,
                nil, nil, nil
            ), SQLITE_OK)
        sqlite3_close(handle)

        let entries = ["good", "bad"].map { id in
            UploadBackupSyncQueueEntry(
                source: source(id),
                revision: revision(10),
                originalFilename: "\(id).heic",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        }
        XCTAssertFalse(store.upsertBatch(entries))
        XCTAssertEqual(store.count(), 0, "a failed discovery chunk must not leave a partial queue frontier")
    }

    func testTwentyThousandQueueBatchStructuralSmoke() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let entries = (0..<20_000).map { index in
            UploadBackupSyncQueueEntry(
                source: source(String(index)),
                revision: revision(TimeInterval(index)),
                originalFilename: "IMG_\(index).HEIC",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }

        let startedAt = Date()
        XCTAssertTrue(store.upsertBatch(entries))
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(store.count(), 20_000)
        XCTAssertEqual(store.summary().waiting, 20_000)
        XCTAssertEqual(store.nextRunnable(limit: 1).first?.source.identifier, "19999")
        let formattedElapsedMs = String(format: "%.2f", elapsedMs)
        print("[BackupDBMicroPerf] queue20k saveMs=\(formattedElapsedMs)")
    }

    func testRunnableWorkDrainsNewestPhotoFirstRegardlessOfEnqueueTime() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        // A backlog and a newly captured photo have different asset dates and update times.
        // The newest photo must drain first, protecting it ahead of the backlog.
        let oldBacklog = UploadBackupSyncQueueEntry(
            source: source("backlog"), revision: revision(100),
            originalFilename: "backlog.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let justTaken = UploadBackupSyncQueueEntry(
            source: source("fresh"), revision: revision(9_999),
            originalFilename: "fresh.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 9_000_000)
        )
        store.upsert(oldBacklog)
        store.upsert(justTaken)

        XCTAssertEqual(
            store.nextRunnable(limit: 2).map(\.source.identifier), ["fresh", "backlog"],
            "newest photo (highest revision) drains first, even though it was enqueued last")
        let claimed = store.claimRunnable(limit: 1, claimedAt: Date(timeIntervalSince1970: 9_000_001))
        XCTAssertEqual(claimed.map(\.source.identifier), ["fresh"], "claim also prioritizes the newest photo")
    }

    func testSQLiteQueueUpdatesStateWithoutRewritingDescriptor() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let entry = UploadBackupSyncQueueEntry(
            source: source("asset"),
            revision: revision(10),
            originalFilename: "asset.heic",
            byteCount: 99,
            state: .hashing,
            attempts: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        store.upsert(entry)

        store.updateState(
            source: entry.source,
            revision: entry.revision,
            state: .failed,
            attempts: 2,
            lastError: "network",
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let updated = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(updated.originalFilename, "asset.heic")
        XCTAssertEqual(updated.byteCount, 99)
        XCTAssertEqual(updated.state, .failed)
        XCTAssertEqual(updated.attempts, 2)
        XCTAssertEqual(updated.lastError, "network")
    }

    func testManualRetryMakesOnlyRetryableRowsDueNow() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let future = Date(timeIntervalSince1970: 10_000)
        let now = Date(timeIntervalSince1970: 500)
        let seeded: [(String, UploadBackupSyncQueueState, Int)] = [
            ("failed", .failed, 8),
            ("draft", .blockedByDraft, 24),
            ("waiting", .discovered, 3),
            ("upload", .queuedForUpload, 4),
            ("deleted", .skippedRemoteDeletion, 0),
            ("missing", .sourceMissing, 0),
            ("permanent", .failedPermanent, 8),
            ("dismissed", .dismissedFailure, 8),
            ("done", .completed, 0),
        ]
        for (id, state, attempts) in seeded {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source(id),
                        revision: revision(1),
                        originalFilename: "\(id).heic",
                        state: state,
                        attempts: attempts,
                        lastError: "old",
                        updatedAt: future
                    )))
        }

        XCTAssertEqual(store.makeRetryableWorkEligible(updatedAt: now), 4)

        let failed = try XCTUnwrap(store.entry(for: source("failed"), revision: revision(1)))
        XCTAssertEqual(failed.state, .discovered)
        XCTAssertEqual(failed.attempts, 0, "terminal failure gets a fresh user-initiated retry budget")
        let draft = try XCTUnwrap(store.entry(for: source("draft"), revision: revision(1)))
        XCTAssertEqual(draft.state, .discovered)
        XCTAssertEqual(draft.attempts, 24, "draft history must remain available for truthful diagnostics")
        let queued = try XCTUnwrap(store.entry(for: source("upload"), revision: revision(1)))
        XCTAssertEqual(queued.state, .queuedForUpload)
        for id in ["failed", "draft", "waiting", "upload"] {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(1)))
            XCTAssertEqual(entry.updatedAt, now)
            XCTAssertNil(entry.lastError)
        }
        for id in ["deleted", "missing", "permanent", "dismissed", "done"] {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(1)))
            XCTAssertEqual(entry.updatedAt, future, "non-retryable and successful rows must not move")
        }
    }

    func testPermanentFailureCanBeDismissedWithoutBecomingBackedUp() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let failed = UploadBackupSyncQueueEntry(
            source: source("stale-draft"),
            revision: revision(1),
            originalFilename: "IMG_0001.HEIC",
            state: .failedPermanent,
            attempts: 8,
            lastError: "stale draft",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(store.upsert(failed))

        XCTAssertTrue(
            store.dismissPermanentFailure(
                source: failed.source,
                revision: failed.revision,
                updatedAt: Date(timeIntervalSince1970: 200)
            ))

        let dismissed = try XCTUnwrap(store.entry(for: failed.source, revision: failed.revision))
        XCTAssertEqual(dismissed.state, .dismissedFailure)
        XCTAssertEqual(dismissed.lastError, "stale draft")
        XCTAssertEqual(store.summary().dismissedFailures, 1)
        XCTAssertEqual(store.summary().resolved, 0, "acknowledgement must never claim upload success")
        XCTAssertEqual(store.makeRetryableWorkEligible(updatedAt: Date(timeIntervalSince1970: 300)), 0)
    }

    func testSQLiteQueueListsEntriesInOneStateOldestFirst() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for (id, state, at) in [
            ("blocked-new", UploadBackupSyncQueueState.blockedByDraft, 30.0),
            ("blocked-old", .blockedByDraft, 10.0),
            ("waiting", .discovered, 5.0),
            ("blocked-future", .blockedByDraft, 100.0),
        ] {
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision(1),
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: Date(timeIntervalSince1970: at)
                ))
        }

        let due = store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 10)
        XCTAssertEqual(
            due.map(\.source.identifier), ["blocked-old", "blocked-new"],
            "state filter + oldest-first ordering + strict updatedBefore cutoff")
        XCTAssertEqual(
            store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 1).count, 1)
        XCTAssertTrue(store.entries(in: .sourceMissing, updatedBefore: .distantFuture, limit: 10).isEmpty)
    }

    func testQueueRemovalDeletesExactRevisionOrAllResourcesForSource() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for entry in [
            UploadBackupSyncQueueEntry(
                source: source("asset"), revision: revision(1), originalFilename: "asset.heic", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("asset"), revision: revision(2), originalFilename: "asset.heic", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("asset", resource: .livePairedVideo), revision: revision(2),
                originalFilename: "asset.mov", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("other"), revision: revision(1), originalFilename: "other.heic", updatedAt: .now
            ),
        ] {
            XCTAssertTrue(store.upsert(entry))
        }

        XCTAssertTrue(store.remove(source: source("asset"), revision: revision(1)))
        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.removeSources(kind: .photoLibraryAsset, identifiers: ["asset"]), 2)
        XCTAssertEqual(store.count(), 1)
        XCTAssertNotNil(store.entry(for: source("other"), revision: revision(1)))
    }

    func testFolderQueueReconciliationKeepsOnlyRegisteredRoots() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let activeRoot = tempDir.appendingPathComponent("active", isDirectory: true)
        let activeSource = UploadSourceIdentity.file(activeRoot.appendingPathComponent("nested/current.jpg"))
        let removedSource = UploadSourceIdentity.file(
            tempDir.appendingPathComponent("removed/old.jpg")
        )
        let prefixSiblingSource = UploadSourceIdentity.file(
            tempDir.appendingPathComponent("active-copy/not-current.jpg")
        )
        let photoLibrarySource = source("photo-library")

        for (source, filename) in [
            (activeSource, "current.jpg"),
            (removedSource, "old.jpg"),
            (prefixSiblingSource, "not-current.jpg"),
            (photoLibrarySource, "library.heic"),
        ] {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source,
                        revision: revision(1),
                        originalFilename: filename,
                        updatedAt: .now
                    )))
        }

        XCTAssertEqual(store.removeFileSources(outsideRootPaths: [activeRoot.path]), 2)
        XCTAssertNotNil(store.entry(for: activeSource, revision: revision(1)))
        XCTAssertNil(store.entry(for: removedSource, revision: revision(1)))
        XCTAssertNil(store.entry(for: prefixSiblingSource, revision: revision(1)))
        XCTAssertNotNil(store.entry(for: photoLibrarySource, revision: revision(1)))

        XCTAssertEqual(store.removeFileSources(outsideRootPaths: []), 1)
        XCTAssertEqual(store.count(), 1)
        XCTAssertNotNil(store.entry(for: photoLibrarySource, revision: revision(1)))
    }

    func testTypedIssueRoundTripsAndEarliestEligibilityIgnoresExecutionPriority() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let retryAt = Date(timeIntervalSince1970: 200)
        let issue = BackupIssueRecord(
            kind: .network,
            detail: "Connection lost",
            nextAttemptAt: retryAt,
            automaticRetryAttempt: 4
        )
        let earlier = UploadBackupSyncQueueEntry(
            source: source("earlier"), revision: revision(10), originalFilename: "earlier.heic",
            state: .discovered, lastError: issue.persistedValue, updatedAt: retryAt
        )
        let newerPhotoButLaterRetry = UploadBackupSyncQueueEntry(
            source: source("later"), revision: revision(9_999), originalFilename: "later.heic",
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 400)
        )
        XCTAssertTrue(store.upsert(earlier))
        XCTAssertTrue(store.upsert(newerPhotoButLaterRetry))

        let stored = try XCTUnwrap(store.earliestRunnableEntry())
        XCTAssertEqual(stored.source.identifier, "earlier")
        XCTAssertEqual(BackupIssueRecord.decode(stored.lastError), issue)
        XCTAssertEqual(
            BackupIssueRecord.decode(
                BackupIssueRecord(kind: .network, detail: "current payload", nextAttemptAt: retryAt).persistedValue
            )?.automaticRetryAttempt,
            0
        )
        XCTAssertNil(BackupIssueRecord.decode("plain text"))
    }

    func testSQLiteQueueAtomicallyClaimsRunnableRowsAndSkipsFutureBackoff() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let now = Date(timeIntervalSince1970: 100)
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let ready = UploadBackupSyncQueueEntry(
            source: source("ready"),
            revision: revision(20),
            originalFilename: "ready.heic",
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let future = UploadBackupSyncQueueEntry(
            source: source("future"),
            revision: revision(30),
            originalFilename: "future.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        for entry in [future, ready, old] {
            XCTAssertTrue(store.upsert(entry))
        }

        XCTAssertEqual(store.nextRunnableDate(), old.updatedAt)

        let firstClaim = store.claimRunnable(limit: 2, claimedAt: now)

        // Newest photo first among the eligible (future-backoff row excluded until its updated_at):
        // ready (revision 20) before the lower-revision row (revision 10).
        XCTAssertEqual(firstClaim.map(\.source.identifier), ["ready", "old"])
        XCTAssertEqual(store.entry(for: old.source, revision: old.revision)?.state, .checking)
        XCTAssertEqual(store.entry(for: ready.source, revision: ready.revision)?.state, .checking)
        XCTAssertEqual(store.entry(for: future.source, revision: future.revision)?.state, .discovered)
        XCTAssertTrue(
            store.claimRunnable(limit: 10, claimedAt: now).isEmpty,
            "claimed rows are active and future-backoff rows are not claimable yet")

        let secondClaim = store.claimRunnable(limit: 10, claimedAt: Date(timeIntervalSince1970: 250))
        XCTAssertEqual(secondClaim.map(\.source.identifier), ["future"])
        XCTAssertNil(store.nextRunnableDate())
    }

    func testConcurrentStoreInstancesNeverClaimTheSameRows() async throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let first = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let second = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let claimedAt = Date(timeIntervalSince1970: 500)
        let entries = (0..<40).map { index in
            UploadBackupSyncQueueEntry(
                source: source("race-\(index)"),
                revision: revision(TimeInterval(index)),
                originalFilename: "race-\(index).heic",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }
        for entry in entries { XCTAssertTrue(first.upsert(entry)) }

        let gate = UploadTestBarrier(participantCount: 2)
        let claims = await withTaskGroup(
            of: [UploadBackupSyncQueueEntry].self, returning: [[UploadBackupSyncQueueEntry]].self
        ) { group in
            group.addTask {
                await gate.arriveAndWait()
                return first.claimRunnable(limit: entries.count, claimedAt: claimedAt)
            }
            group.addTask {
                await gate.arriveAndWait()
                return second.claimRunnable(limit: entries.count, claimedAt: claimedAt)
            }

            var values: [[UploadBackupSyncQueueEntry]] = []
            for await claim in group { values.append(claim) }
            return values
        }

        let identifiers = claims.flatMap { $0.map(\.source.identifier) }
        XCTAssertEqual(identifiers.count, entries.count)
        XCTAssertEqual(Set(identifiers).count, entries.count, "each durable row may be claimed only once")
        XCTAssertTrue(first.claimRunnable(limit: entries.count, claimedAt: claimedAt).isEmpty)
    }

    func testSQLiteQueueRequeuesStaleActiveStatesAfterCrash() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = Date(timeIntervalSince1970: 10)
        let fresh = Date(timeIntervalSince1970: 90)
        let recoveredAt = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 50)

        let staleStates: [(String, UploadBackupSyncQueueState, UploadBackupSyncQueueState)] = [
            ("checking", .checking, .discovered),
            ("hashing", .hashing, .discovered),
            ("duplicate", .duplicateChecking, .discovered),
            ("uploading", .uploading, .queuedForUpload),
            ("finalizing", .finalizing, .queuedForUpload),
        ]
        for (id, state, _) in staleStates {
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision(10),
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: old
                ))
        }
        store.upsert(
            UploadBackupSyncQueueEntry(
                source: source("fresh-uploading"),
                revision: revision(20),
                originalFilename: "fresh.heic",
                state: .uploading,
                updatedAt: fresh
            ))
        store.upsert(
            UploadBackupSyncQueueEntry(
                source: source("done"),
                revision: revision(30),
                originalFilename: "done.heic",
                state: .completed,
                updatedAt: old
            ))

        XCTAssertEqual(store.requeueStaleActive(before: cutoff, updatedAt: recoveredAt), staleStates.count)

        for (id, _, expected) in staleStates {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(10)))
            XCTAssertEqual(entry.state, expected)
            XCTAssertEqual(entry.updatedAt, recoveredAt)
        }
        XCTAssertEqual(store.entry(for: source("fresh-uploading"), revision: revision(20))?.state, .uploading)
        XCTAssertEqual(store.entry(for: source("done"), revision: revision(30))?.state, .completed)
        XCTAssertEqual(
            Set(store.nextRunnable(limit: 10).map(\.source.identifier)),
            Set(staleStates.map { $0.0 }),
            "recovered rows must become runnable again; stale uploading/finalizing may not disappear"
        )
    }

    func testSQLiteQueueRejectsFutureSchemaWithoutDeletingRemoteCommitReceipt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let entry = UploadBackupSyncQueueEntry(
            source: source("committed"),
            revision: revision(10),
            originalFilename: "committed.heic",
            state: .uploading,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "content-hash"
            ),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link")
        )
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            XCTAssertTrue(
                store.markNeedsRemoteReconciliation(
                    source: entry.source,
                    revision: entry.revision,
                    reconciliation: reconciliation,
                    lastError: "manifest unavailable",
                    updatedAt: Date(timeIntervalSince1970: 11)
                ))
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_sync_queue_info SET value=99 WHERE key='schema';", nil, nil, nil),
            SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))

        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT state, remote_commit_reconciliation FROM backup_sync_queue WHERE source_id='committed';",
                -1,
                &stmt,
                nil
            ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "needsRemoteReconciliation")
        XCTAssertEqual(sqlite3_column_type(stmt, 1), SQLITE_BLOB)
        XCTAssertGreaterThan(sqlite3_column_bytes(stmt, 1), 0)
    }

    func testSQLiteQueueRejectsMarkerlessWrongShapeWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE backup_sync_queue(source_id TEXT); INSERT INTO backup_sync_queue VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_sync_queue"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_sync_queue_info"), -1)
    }

    func testSQLiteQueueOpenFailureDoesNotReplaceDatabaseWithAnEmptyQueue() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let original = Data("not-a-sqlite-database".utf8)
        try original.write(to: url)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func sqliteCount(url: URL, table: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    func testClosedSQLiteQueueFailsClosedInsteadOfLookingEmpty() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.isOperational())
        store.close()

        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(store.nextRunnable(limit: 10).isEmpty)
        XCTAssertFalse(store.isOperational(), "an empty read after a DB failure must not mean drained")
        XCTAssertFalse(
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("closed"),
                    revision: revision(10),
                    originalFilename: "closed.heic",
                    updatedAt: Date()
                )))
    }

    func testSyncEngineScansIntoSharedQueueWithSafeDecisions() async throws {
        let backupStore = MemoryBackupStore()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let now = Date(timeIntervalSince1970: 123)
        let index = UploadBackupPreflightIndex(store: backupStore, now: { now })
        let known = candidate(id: "known", revision: 10)
        try await index.markBackedUp(known.snapshot)
        let trustedDrift = candidate(id: "known", revision: 20, editRevision: .trustedNoContentEdits)
        let newAsset = candidate(id: "new", revision: 30)
        let unknownEdit = candidate(id: "known", revision: 40, editRevision: .revision(revision(35)))
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue, now: { now })

        let result = try await engine.scan(StaticCatalog(items: [trustedDrift, newAsset, unknownEdit]))

        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertEqual(result.queuedForWork, 2)
        XCTAssertEqual(result.backendChecksRequired, 1)
        XCTAssertEqual(
            queue.entry(for: trustedDrift.snapshot.source, revision: trustedDrift.snapshot.revision)?.state,
            .alreadyBackedUp)
        XCTAssertEqual(
            queue.entry(for: newAsset.snapshot.source, revision: newAsset.snapshot.revision)?.state, .discovered)
        XCTAssertEqual(
            queue.entry(for: unknownEdit.snapshot.source, revision: unknownEdit.snapshot.revision)?.state, .checking)
    }

    func testExactRemoteAssetProofSkipsBytesAndResourceMismatchFallsBack() async throws {
        let backupStore = MemoryBackupStore()
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent("remote-proof-queue.sqlite")
            ))
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-asset",
            modificationDate: Date(timeIntervalSinceReferenceDate: 50)
        )
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity,
            resourceCount: 1,
            remoteLinkIDs: ["remote-link"],
            hashKeyEpoch: "epoch-1"
        )
        let resolver = RemoteProofResolver(proofs: [identity: proof])
        let index = UploadBackupPreflightIndex(store: backupStore)
        let engine = UploadBackupSyncEngine(
            preflight: index,
            queue: queue,
            remoteProofResolver: resolver
        )
        let exact = candidate(id: "exact", revision: 10, externalIdentity: identity)
        let mismatchedCompound = candidate(
            id: "compound",
            revision: 20,
            externalIdentity: identity,
            resourceCount: 2
        )

        let result = try await engine.enqueueBatch([exact, mismatchedCompound])

        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertEqual(result.queuedForWork, 1)
        XCTAssertEqual(
            queue.entry(for: exact.snapshot.source, revision: exact.snapshot.revision)?.state, .alreadyBackedUp)
        XCTAssertEqual(
            queue.entry(for: mismatchedCompound.snapshot.source, revision: mismatchedCompound.snapshot.revision)?.state,
            .discovered
        )
        let persistedDecision = try await index.classify(exact.snapshot)
        XCTAssertEqual(persistedDecision, .alreadyBackedUp)
    }

    func testRemoteProofCancellationDoesNotPersistQueueRows() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent("cancelled-proof-queue.sqlite")
            ))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        let engine = UploadBackupSyncEngine(
            preflight: index,
            queue: queue,
            remoteProofResolver: CancellingProofResolver()
        )
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-cancel",
            modificationDate: Date()
        )

        do {
            _ = try await engine.enqueue(
                candidate(
                    id: "cancel",
                    revision: 10,
                    externalIdentity: identity
                ))
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(queue.count(), 0)
        }
    }
}
