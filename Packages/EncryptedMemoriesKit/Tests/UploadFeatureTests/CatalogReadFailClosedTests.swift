import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// A failed catalog read never means absent, complete, removed or inaccessible (#1004). Each test drives the real
/// catalog store through its production consumer: the catalog sync, the pending metadata provider and the pending
/// coordinator.
final class CatalogReadFailClosedTests: XCTestCase {
    private var directory: URL!
    private var closers: [() async -> Void] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-fail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for close in closers.reversed() { await close() }
        closers.removeAll()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCatalog() throws -> PhotoLibraryCatalogManifestStore {
        let store = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        closers.append { store.close() }
        return store
    }

    private func photo(_ id: String, modified: TimeInterval = 1_700_000_100) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: modified), pixelWidth: 10, pixelHeight: 10,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic")])
    }

    /// An edit that lists its rendered file next to the original.
    private func edit(_ id: String, modified: TimeInterval = 1_700_000_100) -> PhotoBackupAssetInfo {
        var info = photo(id, modified: modified)
        info.resources.append(
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.JPG", mimeType: "image/jpeg"))
        return info
    }

    private func entry(_ info: PhotoBackupAssetInfo, at seconds: TimeInterval = 100) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date(timeIntervalSince1970: seconds))
    }

    private func sync(
        _ store: PhotoLibraryCatalogManifestStore, infos: [PhotoBackupAssetInfo] = [], at seconds: TimeInterval = 100,
        chunkSize: Int = 10
    ) -> PhotoLibraryCatalogSync {
        PhotoLibraryCatalogSync(
            store: store, enumerator: Enumerator(infos: infos), chunkSize: chunkSize,
            now: { Date(timeIntervalSince1970: seconds) })
    }

    /// An identifier longer than the length limit that `LengthLimitAfterWrite` sets.
    private let longIdentifier = "m" + String(repeating: "x", count: 600)

    // MARK: - Full scan (H1-H3): hazards that appear once recovery clears a transient failure

    func testAFailedSnapshotCountNeverSweepsTheLibraryOrCompletesTheScan() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        let infos = ["a", "b", "c"].map { photo($0) }
        _ = try await sync(store, infos: infos, at: 100).run(engine: Enqueuer())
        XCTAssertTrue(store.markFullScanOwed(), "a rescan is owed again")

        // The snapshot append reads the count first; the second count is the one that sizes the scan.
        let fault = try SQLiteReadInterrupt(
            in: store, matching: "SELECT COUNT(*) FROM photo_full_scan_snapshot", occurrence: 2)
        do {
            _ = try await sync(store, infos: infos, at: 200).run(engine: Enqueuer())
            XCTFail("an unknown snapshot size must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(try store.entry(for: id)?.isRemoved, false, "an unknown count must not sweep \(id)")
        }
        XCTAssertFalse(store.hasCompletedFullScan(), "an unknown count must not complete the owed scan")
    }

    func testAFailedSnapshotPageKeepsTheResumePoint() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id FROM photo_full_scan_snapshot")
        do {
            _ = try await sync(store, infos: ["a", "b", "c"].map { photo($0) }).run(engine: Enqueuer())
            XCTFail("an unknown snapshot page must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertEqual(try store.fullScanProgress()?.cursor, 0, "an unknown page keeps the epoch and its cursor")
        XCTAssertEqual(store.fullScanSnapshotCount(), 3, "an unknown page keeps the saved snapshot")
    }

    func testAFailedResumeReadKeepsTheInterruptedScanEpoch() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        let epoch = PhotoLibraryFullScanProgress(epochStart: Date(timeIntervalSince1970: 100), cursor: 1)
        XCTAssertTrue(store.beginFullScanSnapshot(epochStart: epoch.epochStart))
        XCTAssertTrue(store.appendFullScanSnapshotIdentifiers(["a", "b", "c"]))
        XCTAssertTrue(store.finishFullScanSnapshot())
        XCTAssertTrue(store.recordFullScanProgress(epoch))

        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT value FROM photo_catalog_info WHERE key=?")
        do {
            _ = try await sync(store, infos: ["a", "b", "c"].map { photo($0) }, at: 200).run(engine: Enqueuer())
            XCTFail("an unknown resume point must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertEqual(try store.fullScanProgress(), epoch, "an unknown resume point must not start a new epoch")
    }

    // MARK: - Sweeps (H4, H5): a failed cursor bind exists today

    func testAFailedLateRenderCursorBindNeverCompletesThePass() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", longIdentifier, "z"].map { entry(edit($0)) }))
        let limit = try LengthLimitAfterWrite(in: store, marker: longIdentifier, limit: 400)
        let engine = Enqueuer()
        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: engine)
            XCTFail("an unknown page must stop the pass")
        } catch {}
        let applied = limit.remove()

        XCTAssertLessThan(try XCTUnwrap(applied), Int32(longIdentifier.utf8.count), "the next cursor bind fails")
        XCTAssertFalse(store.hasReconciledLateRenders(), "the page after the failed bind is still unchecked")
        XCTAssertEqual(engine.reopened, ["a", longIdentifier])
    }

    func testAFailedMissingSourceCursorBindNeverCompletesTheSweep() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", longIdentifier, "z"].map { entry(photo($0)) }))
        let limit = try LengthLimitAfterWrite(in: store, marker: longIdentifier, limit: 400)
        let engine = Enqueuer()
        do {
            try await sync(store, chunkSize: 1).reconcileMissingSources(engine: engine)
            XCTFail("an unknown page must stop the sweep")
        } catch {}
        let applied = limit.remove()

        XCTAssertLessThan(try XCTUnwrap(applied), Int32(longIdentifier.utf8.count), "the next cursor bind fails")
        XCTAssertNotEqual(
            store.reconciledMissingSourceGeneration(), Enqueuer.generation,
            "the page after the failed bind is still unchecked")
        XCTAssertEqual(engine.recovered, ["a", longIdentifier])
    }

    func testAnUnknownLateRenderPageNeverCompletesThePass() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(edit($0)) }))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id, cloud_id", occurrence: 2)
        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: Enqueuer())
            XCTFail("an unknown page must stop the pass")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertFalse(store.hasReconciledLateRenders(), "an unknown page is not the end of the catalog")
    }

    func testAnUnknownMissingSourcePageNeverCompletesTheSweep() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(photo($0)) }))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id, cloud_id", occurrence: 2)
        do {
            try await sync(store, chunkSize: 1).reconcileMissingSources(engine: Enqueuer())
            XCTFail("an unknown page must stop the sweep")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertNotEqual(
            store.reconciledMissingSourceGeneration(), Enqueuer.generation,
            "an unknown page is not the end of the catalog")
    }

    // MARK: - Late render (H6)

    func testAFailedStoredEntryReadNeverSkipsALateRenderReopening() async throws {
        let store = try makeCatalog()
        store.recoversTransientFailuresForTesting = true
        XCTAssertTrue(store.upsertBatch([entry(photo("a"))]))
        let engine = Enqueuer()
        // Photos now lists the rendered file of "a": classification reads first, then the stored row.
        let fault = try SQLiteReadInterrupt(in: store, matching: "FROM photo_catalog WHERE local_id=?", occurrence: 2)
        do {
            _ = try await sync(store, infos: [edit("a", modified: 1_700_000_200)], at: 200)
                .run(engine: engine, identifiers: ["a"])
            XCTFail("an unknown stored row must stop the chunk")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        let stored = try XCTUnwrap(store.entry(for: "a"))
        XCTAssertFalse(
            PhotoBackupAssetPlanner.listsRender(PhotoLibraryCatalogMapper.info(for: stored)),
            "the catalog must not record the render that no reopening covered")
        XCTAssertTrue(engine.enqueued.isEmpty)
    }

    // MARK: - Binding results (H8)

    func testAFailedRemovalBindReportsAFailedRemoval() throws {
        let store = try makeCatalog()
        try setLengthLimit(400, on: store)
        let result = store.markRemoved([longIdentifier], removedAt: Date())
        XCTAssertFalse(result.succeeded, "an unbound identifier matches no row; that is no removal")
        XCTAssertFalse(store.isOperational())
    }

    func testAFailedIdentifierBindWritesNoCatalogRow() throws {
        let store = try makeCatalog()
        try setLengthLimit(400, on: store)
        var unbound = photo(longIdentifier)
        unbound.resources[0].originalFilename = "IMG_LONG.HEIC"
        XCTAssertFalse(store.upsertBatch([entry(unbound)]), "an unbound identifier is no observation")
        try setLengthLimit(1_000_000, on: store)
        XCTAssertEqual(store.count(), 0, "no row without an identifier")
    }

    // The missing-source info keys are longer than the effective length floor of 30 bytes: 31
    // (`missing_source_sweep_generation`), 33 (`missing_source_sweep_resume_point`) and 36
    // (`reconciled_missing_source_generation`). An unbound key would write or delete under a NULL key and report
    // success. `KeyBindFailureAfterBegin` fails only the first bind after the transaction starts.

    func testAFailedCursorKeyBindSavesNoSweepProgress() throws {
        let store = try makeCatalog()
        let fault = try KeyBindFailureAfterBegin(in: store)
        let progress = PhotoLibraryMissingSourceSweepProgress(generation: 1, afterLocalIdentifier: "a")
        XCTAssertFalse(store.recordMissingSourceSweepProgress(progress), "the cursor key did not bind")
        XCTAssertTrue(fault.remove(), "the cursor write was the only statement under the limit")
        XCTAssertNil(store.missingSourceSweepProgress(), "nothing of the refused progress was saved")
    }

    func testAFailedCompletionKeyBindLeavesTheSweepOwed() throws {
        let store = try makeCatalog()
        let fault = try KeyBindFailureAfterBegin(in: store)
        XCTAssertFalse(store.completeMissingSourceSweep(generation: 1), "the completion key did not bind")
        XCTAssertTrue(fault.remove(), "the completion write was the only statement under the limit")
        XCTAssertNil(store.reconciledMissingSourceGeneration(), "the sweep is still owed")
    }

    func testAFailedDeletionKeyBindKeepsTheSavedCursor() throws {
        let store = try makeCatalog()
        let saved = PhotoLibraryMissingSourceSweepProgress(generation: 1, afterLocalIdentifier: "a")
        XCTAssertTrue(store.recordMissingSourceSweepProgress(saved))
        let fault = try KeyBindFailureAfterBegin(in: store)
        // A new sweep without a cursor deletes the saved one first; that deletion cannot bind its key.
        XCTAssertFalse(
            store.recordMissingSourceSweepProgress(PhotoLibraryMissingSourceSweepProgress(generation: 2)),
            "the cursor key of the deletion did not bind")
        XCTAssertTrue(fault.remove(), "the deletion was the only statement under the limit")
        XCTAssertEqual(store.missingSourceSweepProgress(), saved, "the refused change kept the saved progress")
    }

    private func setLengthLimit(_ limit: Int32, on store: PhotoLibraryCatalogManifestStore) throws {
        let connection = try storeConnection(store)
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
        let effective = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) }
        XCTAssertEqual(effective, limit, "the effective limit is the requested one")
    }

    // MARK: - Pending grid (H7, row 11)

    private func makeCoordinator(
        catalog: PhotoLibraryCatalogManifestStore
    ) throws -> (PendingBackupCoordinator, UploadBackupSyncQueueManifestStore) {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        let recorder = PendingBackupEventRecorder(
            store: pending, replacementLedger: .shared(accountDataDirectory: directory), now: { Date() })
        let coordinator = PendingBackupCoordinator(
            store: pending, queues: [.photoLibraryAsset: queue],
            metadataProvider: PhotoLibraryPendingMetadataProvider(catalog: catalog), effects: NoEffects(),
            recorder: recorder,
            configuration: .init(
                membershipInterval: .zero, progressInterval: .milliseconds(1), libraryChangeDelay: .zero))
        closers.append {
            await coordinator.close()
            recorder.finish()
            queue.close()
            pending.close()
        }
        return (coordinator, queue)
    }

    private func queueRow(
        _ id: String, state: UploadBackupSyncQueueState = .queuedForUpload
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
            revision: UploadBackupRevision(rawValue: 9), originalFilename: "IMG_\(id).HEIC", state: state,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Breaks the resources of one catalog row on the store's own connection; the other rows stay readable.
    private func corrupt(_ id: String, in catalog: PhotoLibraryCatalogManifestStore, repair: Bool = false) throws {
        try SerializedImageMutation.install(on: storeConnection(catalog)) { image in
            let healthy = Array("\"IMG_\(id).HEIC\"".utf8)
            var broken = healthy
            broken[0] = UInt8(ascii: "!")
            let range = try XCTUnwrap(image.firstRange(of: repair ? broken : healthy))
            image[range.lowerBound] = repair ? healthy[0] : broken[0]
        }
    }

    private func waitFor(
        _ coordinator: PendingBackupCoordinator, _ description: String,
        _ predicate: @escaping (PendingBackupSnapshot) -> Bool
    ) async -> PendingBackupSnapshot {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let snapshot = await coordinator.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(predicate(snapshot), description)
        return snapshot
    }

    func testAnUnrelatedUndecodableCatalogRowKeepsHealthyPendingTilesVisible() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch(["known", "broken"].map { entry(photo($0)) }))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        XCTAssertTrue(queue.upsert(queueRow("known")))
        XCTAssertTrue(queue.upsert(queueRow("broken")))
        try corrupt("broken", in: catalog)

        await coordinator.start()

        let tiles = await coordinator.currentSnapshot().tiles.map(\.key.identifier)
        XCTAssertEqual(tiles, ["known"], "only the undecodable row is unknown; the healthy row keeps its tile")
    }

    /// Each photo is its own read, whatever the request order: only the undecodable row is unknown, a healthy row
    /// keeps its metadata, and a photo without a row is neither (#1004 row 11).
    func testAnUndecodableRowLeavesEveryOtherPendingAnswerKnown() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch(["known", "broken"].map { entry(photo($0)) }))
        try corrupt("broken", in: catalog)
        let provider = PhotoLibraryPendingMetadataProvider(catalog: catalog)
        let key = { PendingSourceKey(kind: .photoLibraryAsset, identifier: $0) }
        for order in [["broken", "known", "absent"], ["known", "absent", "broken"]] {
            let answer = await provider.metadataAnswer(for: order.map(key))
            XCTAssertEqual(Set(answer.metadata.keys), [key("known")], "order \(order)")
            XCTAssertEqual(answer.unknown, [key("broken")], "order \(order)")
        }
    }

    func testAnUnknownCatalogReadNeverMarksThePendingSourceInaccessible() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch([entry(photo("flaky"))]))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        XCTAssertTrue(queue.upsert(queueRow("flaky")))
        try corrupt("flaky", in: catalog)
        await coordinator.start()
        let hidden = await coordinator.currentSnapshot().tiles
        XCTAssertTrue(hidden.isEmpty, "fixture: the unknown row has no metadata yet")

        try corrupt("flaky", in: catalog, repair: true)
        XCTAssertTrue(
            queue.updateState(
                source: queueRow("flaky").source, revision: queueRow("flaky").revision, state: .uploading,
                attempts: nil, lastError: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_001)))

        _ = await waitFor(coordinator, "the next event reads the unknown row again and shows its tile") {
            $0.tiles.map(\.key.identifier) == ["flaky"]
        }
    }

    func testAnUnknownCatalogReadKeepsExcludedPhotosListed() async throws {
        let catalog = try makeCatalog()
        let ids = ["kept", "broken", "deleted"]
        XCTAssertTrue(catalog.upsertBatch(ids.map { entry(photo($0)) }))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        for id in ids { XCTAssertTrue(queue.upsert(queueRow(id))) }
        await coordinator.start()
        let uids = ids.map { PhotoUID(localPending: .photoLibrary, identifier: $0) }
        _ = await coordinator.exclude(uids)
        let listed = await coordinator.currentSnapshot().excludedTiles.map(\.key.identifier)
        XCTAssertEqual(Set(listed), Set(ids), "fixture: all three are listed")

        XCTAssertTrue(catalog.markRemoved(["deleted"], removedAt: Date()).succeeded)
        try corrupt("broken", in: catalog)
        await coordinator.noteLibraryChanged()

        let snapshot = await waitFor(coordinator, "the certified absent photo leaves the list") {
            !$0.excludedTiles.contains { $0.key.identifier == "deleted" }
        }
        let remaining = Set(snapshot.excludedTiles.map(\.key.identifier))
        XCTAssertTrue(remaining.contains("kept"), "a healthy row stays listed after an unrelated decode failure")
        XCTAssertTrue(remaining.contains("broken"), "an unknown read keeps the earlier answer")
    }
}

// MARK: - Fixtures

private func storeConnection(_ store: Any) throws -> SQLiteStoreConnection {
    try XCTUnwrap(
        Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value as? SQLiteStoreConnection)
}

/// Lowers SQLITE_LIMIT_LENGTH on the store's own connection right after the info write that stores `marker`. The
/// value was stored and read normally, and only its next bind fails, as a bind that runs out of memory does.
private final class LengthLimitAfterWrite {
    private let connection: SQLiteStoreConnection
    private let marker: String
    private let limit: Int32
    private var applied: Int32?

    init(in store: Any, marker: String, limit: Int32) throws {
        connection = try storeConnection(store)
        // sqlite3_expanded_sql renders a BLOB parameter as lowercase hexadecimal.
        self.marker = marker.utf8.prefix(16).map { String(format: "%02x", $0) }.joined()
        self.limit = limit
        connection.withLock {
            _ = sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_PROFILE),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let hook = Unmanaged<LengthLimitAfterWrite>.fromOpaque(context).takeUnretainedValue()
                    guard hook.applied == nil, let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else {
                        return 0
                    }
                    defer { sqlite3_free(expanded) }
                    let sql = String(cString: expanded)
                    guard sql.hasPrefix("INSERT INTO photo_catalog_info"), sql.contains(hook.marker) else { return 0 }
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, hook.limit)
                    hook.applied = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1)
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Removes the hook and the limit. Returns the effective limit that applied, or nil when no write matched.
    func remove() -> Int32? {
        connection.withLock {
            _ = sqlite3_trace_v2(connection.database, 0, nil, nil)
            _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
        return applied
    }
}

/// Fails exactly one bind: lowers SQLITE_LIMIT_LENGTH to the 30-byte floor once `BEGIN IMMEDIATE` finishes, and restores
/// it when the next statement starts to step, after its binds and before it builds a record. A bind of a longer value
/// fails as a bind that runs out of memory does; the record and every later statement run without the limit.
private final class KeyBindFailureAfterBegin {
    private let connection: SQLiteStoreConnection
    private var lowered = false
    private var restored = false

    init(in store: Any) throws {
        connection = try storeConnection(store)
        connection.withLock {
            _ = sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE),
                { event, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let fault = Unmanaged<KeyBindFailureAfterBegin>.fromOpaque(context).takeUnretainedValue()
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    if event == UInt32(SQLITE_TRACE_PROFILE), !fault.lowered,
                        let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).hasPrefix("BEGIN IMMEDIATE")
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 30)
                        fault.lowered = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 30
                    } else if event == UInt32(SQLITE_TRACE_STMT), fault.lowered, !fault.restored {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_000_000_000)
                        fault.restored = true
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Removes the hook. True when the limit applied to one statement and was restored.
    func remove() -> Bool {
        connection.withLock {
            _ = sqlite3_trace_v2(connection.database, 0, nil, nil)
            _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
        return lowered && restored
    }
}

private final class Enumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
    let infos: [PhotoBackupAssetInfo]
    init(infos: [PhotoBackupAssetInfo]) { self.infos = infos }

    func infoChunks(
        identifiers: [String]?, startOffset: Int, chunkSize: Int
    ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        let wanted = identifiers.map(Set.init)
        let selected = Array(infos.filter { wanted?.contains($0.localIdentifier) ?? true }.dropFirst(startOffset))
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < selected.count {
                let upper = min(index + max(1, chunkSize), selected.count)
                continuation.yield(Array(selected[index..<upper]))
                index = upper
            }
            continuation.finish()
        }
    }
}

private final class Enqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
    static let generation: Int64 = 1
    private let lock = NSLock()
    private var _enqueued: [String] = []
    private var _reopened: [String] = []
    private var _recovered: [String] = []
    var enqueued: [String] { lock.withLock { _enqueued } }
    var reopened: [String] { lock.withLock { _reopened } }
    var recovered: [String] { lock.withLock { _recovered } }

    func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
        lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
        return UploadBackupSyncScanResult()
    }

    func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate] {
        lock.withLock { _reopened += reopenings.map(\.candidate.snapshot.source.identifier) }
        return []
    }

    func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        lock.withLock { _recovered += candidates.map(\.snapshot.source.identifier) }
    }

    func missingSourceDiscardGeneration() async throws -> Int64 { Self.generation }
    func synchronizeQueueToDisk() async -> Bool { true }
}

private struct NoEffects: PendingBackupEffects {
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool { true }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool { true }
    func photosVolumeID() async -> String? { "volume" }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}
