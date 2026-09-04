import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

private actor SettlementLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !open else { return }
        open = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }
}

private final class SettlementEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] {
        lock.withLock { events }
    }
}

private final class SettlementStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UploadQueueStats()

    func store(_ stats: UploadQueueStats) {
        lock.withLock { value = stats }
    }

    var snapshot: UploadQueueStats {
        lock.withLock { value }
    }
}

private final class SettlementIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: SettlementEventLog?
    private let recordStarted: SettlementLatch?
    private let recordGate: SettlementLatch?
    private let invalidationStarted: SettlementLatch?
    private let invalidationGate: SettlementLatch?
    private var failuresRemaining: Int
    private var _recordedCount = 0
    private var _reconciliationCount = 0
    private var _invalidationCount = 0

    init(
        failuresRemaining: Int = 0,
        eventLog: SettlementEventLog? = nil,
        recordStarted: SettlementLatch? = nil,
        recordGate: SettlementLatch? = nil,
        invalidationStarted: SettlementLatch? = nil,
        invalidationGate: SettlementLatch? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.eventLog = eventLog
        self.recordStarted = recordStarted
        self.recordGate = recordGate
        self.invalidationStarted = invalidationStarted
        self.invalidationGate = invalidationGate
    }

    var recordedCount: Int { lock.withLock { _recordedCount } }
    var reconciliationCount: Int { lock.withLock { _reconciliationCount } }
    var invalidationCount: Int { lock.withLock { _invalidationCount } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        UploadPreflightResult(
            identity: UploadIdentity(
                correctedName: descriptor.filename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "a", count: 40),
                sha1Digest: Data(repeating: 0xAA, count: 20),
                contentHash: "content-hash"
            ),
            decision: .upload
        )
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        eventLog?.append("manifest")
        await recordStarted?.signal()
        await recordGate?.wait()
        let shouldFail = lock.withLock { () -> Bool in
            _recordedCount += 1
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldFail {
            throw UploadError.backend("manifest settlement failed")
        }
    }

    func invalidateCachedRemoteState() async {
        lock.withLock { _invalidationCount += 1 }
        await invalidationStarted?.signal()
        await invalidationGate?.wait()
    }

    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        lock.withLock { _reconciliationCount += 1 }
    }
}

private final class SettlementUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities(
        canUpload: true,
        supportsCancel: true,
        supportsPauseResume: false,
        supportsResumeAcrossRelaunch: false
    )

    private let lock = NSLock()
    private let waitsForRelease: Bool
    private let started = SettlementLatch()
    private let release = SettlementLatch()
    private let cancelStarted = SettlementLatch()
    private var _requests: [PhotoUploadRequest] = []
    private var _cancelledTokens: [UUID] = []

    init(waitsForRelease: Bool = false) {
        self.waitsForRelease = waitsForRelease
    }

    var requestCount: Int { lock.withLock { _requests.count } }
    var cancelledCount: Int { lock.withLock { _cancelledTokens.count } }

    func waitUntilStarted() async { await started.wait() }
    func waitUntilCancelled() async { await cancelStarted.wait() }
    func releaseUpload() async { await release.signal() }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { _requests.append(request) }
        await started.signal()
        if waitsForRelease { await release.wait() }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancelledTokens.append(token) }
        await cancelStarted.signal()
    }
}

private final class FailingSettlementStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UploadQueueItemID: UploadManualSettlementRecord] = [:]
    private var failed = false
    private let failOnFirstRead: Bool
    private let failOnUpsert: Bool
    private let failAfterFirstUpsert: Bool

    init(
        failOnFirstRead: Bool = false,
        failOnUpsert: Bool = false,
        failAfterFirstUpsert: Bool = false
    ) {
        self.failOnFirstRead = failOnFirstRead
        self.failOnUpsert = failOnUpsert
        self.failAfterFirstUpsert = failAfterFirstUpsert
    }

    func isOperational() -> Bool { lock.withLock { !failed } }

    @discardableResult
    func upsert(_ record: UploadManualSettlementRecord) -> Bool {
        lock.withLock {
            guard !failed else { return false }
            if failOnUpsert {
                failed = true
                return false
            }
            records[record.queueItemID] = record
            if failAfterFirstUpsert { failed = true }
            return true
        }
    }

    func record(for queueItemID: UploadQueueItemID) -> UploadManualSettlementRecord? {
        lock.withLock {
            guard !failed else { return nil }
            if failOnFirstRead {
                failed = true
                return nil
            }
            return records[queueItemID]
        }
    }

    func allRecords() -> [UploadManualSettlementRecord] {
        lock.withLock { failed ? [] : Array(records.values) }
    }

    func pendingRecords() -> [UploadManualSettlementRecord] {
        lock.withLock { failed ? [] : records.values.filter(\.isPending) }
    }

    @discardableResult
    func remove(queueItemID: UploadQueueItemID) -> Bool {
        lock.withLock {
            guard !failed else { return false }
            records.removeValue(forKey: queueItemID)
            return true
        }
    }

    func close() { lock.withLock { failed = true } }
}

private final class SettlementAlbums: AlbumAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: SettlementEventLog?
    private let addStarted: SettlementLatch?
    private let addGate: SettlementLatch?
    private let addFinished: SettlementLatch?
    private var failuresRemaining: Int
    private var _added: [(PhotoUID, String)] = []

    init(
        failuresRemaining: Int = 0,
        eventLog: SettlementEventLog? = nil,
        addStarted: SettlementLatch? = nil,
        addGate: SettlementLatch? = nil,
        addFinished: SettlementLatch? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.eventLog = eventLog
        self.addStarted = addStarted
        self.addGate = addGate
        self.addFinished = addFinished
    }

    var added: [(PhotoUID, String)] { lock.withLock { _added } }

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library:
            return nil
        case .existingAlbum(let id, _):
            return id
        case .newAlbum:
            return "new-album"
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        eventLog?.append("album")
        await addStarted?.signal()
        await addGate?.wait()
        let shouldFail = lock.withLock { () -> Bool in
            _added.append((uid, albumID))
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldFail { throw UploadError.backend("album settlement failed") }
        await addFinished?.signal()
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {}
}

final class ManualUploadSettlementTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-upload-settlement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func file(named name: String = "photo.jpg") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("settlement-test-bytes".utf8).write(to: url)
        return url
    }

    private func store() throws -> UploadManualSettlementStore {
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        return try XCTUnwrap(UploadManualSettlementStore(url: url))
    }

    private func existingAlbum() -> UploadDestination {
        UploadDestination(target: .existingAlbum(id: "album-1", title: "Test"))
    }

    private func waitForShutdownAdmissionToClose(_ manager: UploadManager) async -> Bool {
        for _ in 0..<128 {
            if await manager.snapshot().isEmpty { return true }
            await Task.yield()
        }
        return false
    }

    func testMarkerlessSettlementShapeFailsClosedWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE manual_upload_settlement(queue_item_id TEXT); "
                    + "INSERT INTO manual_upload_settlement VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadManualSettlementStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "manual_upload_settlement"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "manual_upload_settlement_info"), -1)
    }

    func testMissingRequiredSettlementPublishesUnavailableInsteadOfEmpty() async {
        let manager = UploadManager(
            uploader: SettlementUploader(),
            settlementStore: nil,
            requiresDurableSettlement: true
        )
        let stats = SettlementStatsBox()

        await manager.setOnChange { _, snapshot in
            stats.store(snapshot)
        }

        XCTAssertTrue(stats.snapshot.persistenceUnavailable)
        XCTAssertEqual(stats.snapshot.total, 0)
        await manager.shutdown()
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

    func testLateNonCooperativeSuccessAfterCancelPersistsReceiptAndKeepsUID() async throws {
        let uploader = SettlementUploader(waitsForRelease: true)
        let resolver = SettlementIdentityResolver()
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        await uploader.waitUntilStarted()
        let cancellation = Task { await manager.cancel(id) }
        await uploader.waitUntilCancelled()
        await uploader.releaseUpload()
        await cancellation.value

        let items = await waitUntil(manager) { $0.first?.state == .completed }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.uploadedUID, item.uploadedUID)
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(uploader.cancelledCount, 1)

        await manager.shutdown()
    }

    func testManifestFailurePersistsReplayWorkAndNeverUploadsBytesAgain() async throws {
        let uploader = SettlementUploader()
        let failingResolver = SettlementIdentityResolver(failuresRemaining: 100)
        let firstStore = try store()
        let firstManager = UploadManager(
            uploader: uploader,
            identityResolver: failingResolver,
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        let failed = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        XCTAssertEqual(failed.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(firstStore.record(for: id)?.stage, .manifestPending)
        XCTAssertEqual(uploader.requestCount, 1)
        await firstManager.shutdown()

        let replayResolver = SettlementIdentityResolver()
        let replayStore = try store()
        let replayManager = UploadManager(
            uploader: uploader,
            identityResolver: replayResolver,
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        let replayed = await waitUntil(replayManager) { $0.first?.state == .completed }
        XCTAssertEqual(replayed.first?.id, id)
        XCTAssertEqual(replayed.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(replayStore.record(for: id)?.stage, .terminal)
        XCTAssertEqual(uploader.requestCount, 1, "replay must never call the byte uploader")
        await replayManager.shutdown()
    }

    func testSettlementStoreReadFailureBlocksByteUpload() async throws {
        let uploader = SettlementUploader()
        let store = FailingSettlementStore(failOnFirstRead: true)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let failed = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        XCTAssertEqual(failed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 0, "an unavailable settlement store must fail closed")
        await manager.shutdown()
    }

    func testReceiptLatchPreventsRetryAfterSettlementStoreReadFailure() async throws {
        let uploader = SettlementUploader()
        let resolver = SettlementIdentityResolver(failuresRemaining: 1)
        let store = FailingSettlementStore(failAfterFirstUpsert: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: store,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        for _ in 0..<3 {
            await manager.retry(id)
        }

        XCTAssertEqual(uploader.requestCount, 1, "a receipt-backed retry must not send bytes again")
        let visible = await manager.snapshot()
        XCTAssertEqual(visible.first?.uploadedUID, testUID("photo.jpg"))
        guard case .failed(let message) = visible.first?.state else {
            return XCTFail(
                "a settlement read failure must remain visibly failed: \(String(describing: visible.first?.state))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("read"), "failure must identify the store read failure")
        await manager.shutdown()
    }

    func testAlbumAttachmentRunsOnlyAfterManifestSettlement() async throws {
        let events = SettlementEventLog()
        let manifestStarted = SettlementLatch()
        let manifestRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            eventLog: events,
            recordStarted: manifestStarted,
            recordGate: manifestRelease
        )
        let albums = SettlementAlbums(eventLog: events)
        let durableStore = try store()
        let manager = UploadManager(
            uploader: SettlementUploader(),
            albums: albums,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)

        await manifestStarted.wait()
        XCTAssertTrue(albums.added.isEmpty)
        XCTAssertEqual(events.snapshot, ["manifest"])
        await manifestRelease.signal()

        _ = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(events.snapshot, ["manifest", "album"])
        XCTAssertEqual(albums.added.count, 1)
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        await manager.shutdown()
    }

    func testShutdownAndReopenResumeDurableSettlement() async throws {
        let uploader = SettlementUploader()
        let firstStore = try store()
        let firstAlbums = SettlementAlbums(failuresRemaining: 1)
        let firstManager = UploadManager(
            uploader: uploader,
            albums: firstAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        XCTAssertEqual(firstStore.record(for: id)?.stage, .albumPending)
        await firstManager.shutdown()

        let replayStore = try store()
        let replayAlbums = SettlementAlbums()
        let replayManager = UploadManager(
            uploader: uploader,
            albums: replayAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        let resumed = await waitUntil(replayManager) { $0.first?.state == .completed }
        XCTAssertEqual(resumed.first?.id, id)
        XCTAssertEqual(replayAlbums.added.count, 1)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(replayStore.record(for: id)?.stage, .terminal)
        await replayManager.shutdown()
    }

    func testShutdownWaitsForPendingSettlementAndLateCancelCannotDemoteReceipt() async throws {
        let uploader = SettlementUploader()
        let addStarted = SettlementLatch()
        let addRelease = SettlementLatch()
        let addFinished = SettlementLatch()
        let albums = SettlementAlbums(addStarted: addStarted, addGate: addRelease, addFinished: addFinished)
        let durableStore = try store()
        let recorder = StateRecorder()
        let manager = UploadManager(
            uploader: uploader,
            albums: albums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)

        await addStarted.wait()
        XCTAssertEqual(durableStore.record(for: id)?.stage, .albumPending)
        let shutdown = Task { await manager.shutdown() }
        let lateCancel = Task { await manager.cancel(id) }
        await lateCancel.value
        XCTAssertEqual(uploader.cancelledCount, 0)
        await addRelease.signal()
        await addFinished.wait()
        await shutdown.value

        XCTAssertEqual(recorder.sequence(id).last, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
    }

    func testRepeatedReplayIsIdempotentAndProducesOneTerminalResult() async throws {
        let uploader = SettlementUploader()
        let firstStore = try store()
        let firstManager = UploadManager(
            uploader: uploader,
            albums: SettlementAlbums(failuresRemaining: 1),
            identityResolver: SettlementIdentityResolver(),
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        await firstManager.shutdown()

        let replayStore = try store()
        let addStarted = SettlementLatch()
        let addRelease = SettlementLatch()
        let replayAlbums = SettlementAlbums(addStarted: addStarted, addGate: addRelease)
        let replayManager = UploadManager(
            uploader: uploader,
            albums: replayAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        _ = await replayManager.snapshot()
        await addStarted.wait()
        for _ in 0..<5 { _ = await replayManager.snapshot() }
        await replayManager.retry(id)
        await addRelease.signal()

        let terminal = await waitUntil(replayManager) { $0.first?.state == .completed }
        XCTAssertEqual(terminal.first?.id, id)
        XCTAssertEqual(replayAlbums.added.count, 1)
        XCTAssertEqual(replayStore.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        await replayManager.shutdown()
    }

    func testLibraryOnlyLateCommitReconcilesWithoutUploadingAgain() async throws {
        let uploader = SettlementUploader(waitsForRelease: true)
        let resolver = SettlementIdentityResolver(failuresRemaining: 1)
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        await uploader.waitUntilStarted()
        let cancellation = Task { await manager.cancel(id) }
        await uploader.waitUntilCancelled()
        await uploader.releaseUpload()
        await cancellation.value

        let reconciled = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(reconciled.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(
            resolver.reconciliationCount,
            0,
            "a durable receipt is replayed by settlement; no duplicate reconciliation callback is needed"
        )
        await manager.shutdown()
    }

    func testSettlementPersistenceFailureReconcilesExactlyOnce() async throws {
        let uploader = SettlementUploader()
        let resolver = SettlementIdentityResolver()
        let store = FailingSettlementStore(failOnUpsert: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: store,
            maxConcurrent: 1
        )
        await manager.enqueueFiles([try file()], destination: .library)

        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(
            resolver.reconciliationCount,
            1,
            "withUploadDecision owns the one reconciliation callback when receipt persistence fails"
        )
        await manager.shutdown()
    }

    func testQueueTerminalStateRetainsUIDWhenAlbumSettlementFails() async throws {
        let uploader = SettlementUploader()
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            albums: SettlementAlbums(failuresRemaining: 1),
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        let failed = await waitUntil(manager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        let item = try XCTUnwrap(failed.first)
        guard case .failed = item.state else { return XCTFail("album failure must be terminal") }
        XCTAssertTrue(item.partialSuccess)
        XCTAssertEqual(item.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.stage, .albumPending)
        await manager.shutdown()
    }

    func testCancelDuringRetryInvalidationPreventsNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let retry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        await manager.cancel(id)
        await invalidationRelease.signal()
        await retry.value

        let cancelled = await waitUntil(manager) { $0.first?.state == .cancelled }
        XCTAssertEqual(cancelled.first?.state, .cancelled)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(resolver.invalidationCount, 1)
    }

    func testShutdownJoinsRetryInvalidationAndPreventsNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let retry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        let shutdown = Task { await manager.shutdown() }
        let admissionClosed = await waitForShutdownAdmissionToClose(manager)
        XCTAssertTrue(admissionClosed, "shutdown must close admission while retry invalidation is still blocked")

        let lateIDs = await manager.enqueueFiles([try file(named: "late.jpg")], destination: .library)
        XCTAssertTrue(lateIDs.isEmpty)

        await invalidationRelease.signal()
        await retry.value
        await shutdown.value

        XCTAssertEqual(uploader.requestCount, 1, "retry invalidation must not restart bytes after shutdown")
        XCTAssertEqual(resolver.invalidationCount, 1)
    }

    func testRepeatedRetryRequestsCreateOneNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let firstRetry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        let secondRetry = Task { await manager.retry(id) }
        await invalidationRelease.signal()
        await firstRetry.value
        await secondRetry.value

        _ = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(uploader.requestCount, 2)
        XCTAssertEqual(resolver.invalidationCount, 1)
    }
}
