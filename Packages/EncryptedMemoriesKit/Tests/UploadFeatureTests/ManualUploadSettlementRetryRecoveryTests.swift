import Foundation
import PhotosCore
import SQLite3
import UploadCore
import XCTest

/// Reads the settlement store's private connection through a mirror, so fault tests can arm
/// interrupts, set pragmas and latch result codes on the connection the store really uses.
private func settlementConnection(of store: UploadManualSettlementStore) -> SQLiteStoreConnection {
    for child in Mirror(reflecting: store).children where child.label == "connection" {
        if let connection = child.value as? SQLiteStoreConnection { return connection }
    }
    preconditionFailure("The settlement store does not expose its connection to the mirror")
}

/// Runs SQL on a database handle opened for the test only, for schema-side setup such as
/// triggers that refuse writes. The settlement store keeps its own connection untouched.
private func executeSideSQL(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    let opened = sqlite3_open(url.path, &handle)
    defer { sqlite3_close(handle) }
    XCTAssertEqual(opened, SQLITE_OK)
    guard opened == SQLITE_OK else { throw UploadError.backend("Test database did not open") }
    let result = sqlite3_exec(handle, sql, nil, nil, nil)
    XCTAssertEqual(result, SQLITE_OK)
    guard result == SQLITE_OK else { throw UploadError.backend("Test database setup failed") }
}

/// Executes SQL directly on the settlement store's own handle. Test-only transaction control the
/// store itself classifies as a lasting condition when it sees the open transaction.
private func executeOnStoreConnection(_ sql: String, store: UploadManualSettlementStore) throws {
    let connection = settlementConnection(of: store)
    let result = sqlite3_exec(connection.database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw UploadError.backend("Store-side SQL failed with SQLite code \(result)")
    }
}

/// Reads one integer pragma from the store's own handle.
private func storePragmaInt(_ store: UploadManualSettlementStore, _ name: String) throws -> Int {
    let connection = settlementConnection(of: store)
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(connection.database, "PRAGMA \(name);", -1, &statement, nil) == SQLITE_OK
    else { throw UploadError.backend("The pragma did not prepare") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw UploadError.backend("The pragma did not answer")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

/// Continuation-based hold. `hold()` suspends its caller until `release()`, so a test can freeze
/// a settlement task at one exact await point without timed sleeps.
final class AttachGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enters = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var enterCount: Int { lock.withLock { enters } }

    /// Suspends until the first enter, so a test parks at a deterministic point with no polling.
    func awaitFirstEntry() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if enters > 0 { return true }
                firstEntryWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func hold() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                enters += 1
                let announced = firstEntryWaiters.isEmpty ? nil : firstEntryWaiters
                firstEntryWaiters.removeAll()
                announced?.forEach { $0.resume() }
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let resumed = lock.withLock {
            released = true
            let resumed = waiters
            waiters.removeAll()
            return resumed
        }
        resumed.forEach { $0.resume() }
    }
}

/// Album attachment that parks the photo-add step on an `AttachGate`, so a settlement task stays
/// alive and registered at a deterministic point.
final class HoldingAlbumAttaching: AlbumAttaching, @unchecked Sendable {
    let gate = AttachGate()

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library: return nil
        case .existingAlbum(let id, _): return id
        case .newAlbum(let name): return "new-album-\(name)"
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        await gate.hold()
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {}
}

/// Records every emitted item state in arrival order, so guard tests can assert the exact publish
/// sequence without polling snapshots.
final class StateHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [UploadItemState] = []

    func record(_ items: [UploadItem]) {
        lock.withLock { states.append(contentsOf: items.map(\.state)) }
    }

    var count: Int { lock.withLock { states.count } }

    var finalizingCount: Int { lock.withLock { states.filter(\.isFinalizing).count } }

    var last: UploadItemState? { lock.withLock { states.last } }

    func reset() { lock.withLock { states.removeAll() } }
}

private extension UploadItemState {
    var isFinalizing: Bool {
        if case .finalizing = self { return true }
        return false
    }
}

/// Issue #1104: one failed settlement write must not pin a manual upload as failed for the whole
/// session. Transient SQLite failures heal at the next store operation, so the receipt-backed item
/// settles again through Retry without re-uploading bytes; a lasting failure keeps the item
/// fail-closed until a relaunch replays the pending row.
final class ManualUploadSettlementRetryRecoveryTests: XCTestCase {
    // MARK: Same-session recovery through Retry

    func testLibraryPathRetrySettlesAgainAfterOneTransientTerminalWriteFailure() async throws {
        let fixture = try await recoverByRetry(destination: .library)
        XCTAssertEqual(
            fixture.identityResolver.recordedUploads.count, 2,
            "A receipt-backed library retry replays from the restored manifest-pending stage, so it"
                + " records the manifest exactly one more time")
    }

    func testAlbumPathRetrySettlesAgainAfterOneTransientTerminalWriteFailure() async throws {
        let fixture = try await recoverByRetry(
            destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album")))
        XCTAssertEqual(
            fixture.identityResolver.recordedUploads.count, 1,
            "A receipt-backed album retry replays from the restored album-pending stage and must not"
                + " record the manifest a second time")
    }

    @discardableResult
    private func recoverByRetry(destination: UploadDestination) async throws -> Fixture {
        let fixture = try Fixture(terminalWriteInterrupt: true, destination: destination)
        defer { fixture.cleanup() }

        let item = try await fixture.enqueueAndWaitForFailure()
        XCTAssertEqual(item.state, .failed(message: fixture.expectedFailureMessage))
        XCTAssertNotNil(item.uploadedUID, "The upload receipt survived the failed settlement write")
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        XCTAssertFalse(
            UploadQueuePresentation
                .rowActions(for: item, capabilities: fixture.uploader.capabilities).isEmpty,
            "Retry must stay available while the settlement record is pending")

        await fixture.manager.retry(try XCTUnwrap(fixture.ids.first))

        let settled = await fixture.waitForCompletion()
        let settledItem = try XCTUnwrap(settled)
        XCTAssertEqual(settledItem.state, .completed)
        XCTAssertEqual(
            settledItem.uploadedUID, item.uploadedUID, "The uploaded file reference must not change")
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Committed bytes must never upload again")
        let saved = try XCTUnwrap(fixture.backingStore.record(for: try XCTUnwrap(fixture.ids.first)))
        XCTAssertEqual(saved.stage, .terminal)
        XCTAssertEqual(saved.terminalState, .completed)
        XCTAssertEqual(saved.uploadedUID, item.uploadedUID)
        await fixture.manager.shutdown()
        return fixture
    }

    /// resumeAll resumes paused byte uploads; it must never adopt a failed settlement itself.
    /// The Retry path is the single in-session recovery entry.
    func testResumeAllLeavesAReceiptBackedFailureToRetry() async throws {
        let fixture = try Fixture(terminalWriteInterrupt: true, destination: .library)
        defer { fixture.cleanup() }

        let item = try await fixture.enqueueAndWaitForFailure()
        XCTAssertEqual(fixture.uploader.requests.count, 1)

        for _ in 0..<3 { await fixture.manager.resumeAll() }
        let afterResume = await fixture.manager.snapshot()
        XCTAssertEqual(
            try XCTUnwrap(afterResume.first).state, item.state,
            "resumeAll must not change a failed receipt-backed item")
        XCTAssertEqual(fixture.uploader.requests.count, 1, "resumeAll must not re-upload bytes")

        await fixture.manager.retry(try XCTUnwrap(fixture.ids.first))
        let settled = await fixture.waitForCompletion()
        XCTAssertEqual(try XCTUnwrap(settled).state, .completed)
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        await fixture.manager.shutdown()
    }

    /// The double-write fault of #1104: the terminal settlement write fails and the
    /// pending-restore write fails too, like a disk that stays full. The in-memory record is
    /// terminal without a terminal state while the durable row stays pending. A terminal record
    /// without a terminal state is no proof of durable completion: Retry stays visible, Clear
    /// finished keeps the item and the still-pending row, and Retry heals the transient store
    /// and settles within the same session without uploading bytes again.
    func testRetrySettlesADoubleWriteFailureWithinTheSameSession() async throws {
        let fixture = try Fixture(
            terminalWriteInterrupt: true,
            terminalWriteInterruptShots: 2,
            destination: .library)
        defer { fixture.cleanup() }

        let item = try await fixture.enqueueAndWaitForFailure()
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        XCTAssertFalse(fixture.backingStore.hasLastingFailure(), "An interrupted write is transient")
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: fixture.uploader.capabilities),
            [.retry],
            "A terminal record without a terminal state is no proof of durable completion; the"
                + " durable row is still pending, so Retry must stay available")

        await fixture.manager.clearFinished()
        let afterClear = await fixture.manager.snapshot()
        XCTAssertEqual(
            afterClear.count, 1,
            "Clear finished must keep an item whose durable settlement row is still pending")
        XCTAssertEqual(try XCTUnwrap(afterClear.first).state, item.state)
        let id = try XCTUnwrap(fixture.ids.first)
        let pending = try XCTUnwrap(
            fixture.backingStore.record(for: id),
            "Clear finished must not delete the still-pending durable row")
        XCTAssertEqual(pending.stage, .manifestPending, "The durable row keeps the pending stage")

        await fixture.manager.retry(id)
        let settled = await fixture.waitForCompletion()
        XCTAssertEqual(try XCTUnwrap(settled).state, .completed)
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Committed bytes must never upload again")
        XCTAssertEqual(try XCTUnwrap(settled).uploadedUID, item.uploadedUID)
        let saved = try XCTUnwrap(fixture.backingStore.record(for: id))
        XCTAssertEqual(saved.stage, .terminal)
        XCTAssertEqual(saved.terminalState, .completed)
        await fixture.manager.shutdown()
    }

    // MARK: Lasting failure stays fail-closed until a relaunch replays the pending row

    /// A trigger refuses every settlement update, like a lasting SQLite fault: the terminal write
    /// fails and the pending-restore write fails too. The in-memory record is terminal without a
    /// terminal state while the durable row stays pending. The store cannot heal in this session,
    /// so the row offers no Retry and Clear finished drops the item without deleting the row; only
    /// a relaunch replays the pending row, without uploading bytes again.
    func testLastingWriteFailureHidesRetryAndClearsTheItemUntilARelaunchReplaysThePendingRow() async throws {
        let fixture = try Fixture(refuseAllSettlementUpdates: true, destination: .library)
        defer { fixture.cleanup() }

        let item = try await fixture.enqueueAndWaitForFailure()
        XCTAssertNotNil(item.uploadedUID, "The visible failure keeps the uploaded reference")
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        XCTAssertTrue(
            fixture.backingStore.hasLastingFailure(), "A lasting fault stays recorded on the connection")
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: fixture.uploader.capabilities),
            [],
            "No settlement can run again before a relaunch, so the row offers no Retry")

        // The fault clears, but the store connection stays latched: a Retry call that still
        // arrives changes nothing and never uploads bytes again.
        try executeSideSQL("DROP TRIGGER refuse_all_settlement_update;", at: fixture.databaseURL)
        await fixture.manager.retry(try XCTUnwrap(fixture.ids.first))
        let afterRetry = await fixture.manager.snapshot()
        XCTAssertEqual(afterRetry, [item], "A latched store must not settle or change the failed row")
        XCTAssertEqual(fixture.uploader.requests.count, 1)

        // Clear finished drops the item from this session. It never deletes the durable row: the
        // relaunch below proves the row survived.
        await fixture.manager.clearFinished()
        let afterClear = await fixture.manager.snapshot()
        XCTAssertEqual(afterClear, [], "Clear finished removes an item that cannot settle before a relaunch")

        // A relaunch opens a new store connection and replays the still-pending row: the receipt
        // covers the bytes, only the metadata settlement runs, and the item completes.
        await fixture.manager.shutdown()
        let relaunched = fixture.makeRelaunchedManager(openingNewStore: true)
        let settled = await fixture.waitForCompletion()
        let settledItem = try XCTUnwrap(settled)
        XCTAssertEqual(settledItem.state, .completed)
        XCTAssertEqual(settledItem.uploadedUID, item.uploadedUID)
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Committed bytes must never upload again")
        let relaunchedStore = try XCTUnwrap(fixture.relaunchedStore)
        let saved = try XCTUnwrap(relaunchedStore.record(for: try XCTUnwrap(fixture.ids.first)))
        XCTAssertEqual(saved.stage, .terminal)
        XCTAssertEqual(saved.terminalState, .completed)
        await relaunched.shutdown()
    }

    /// The album step write fails with a lasting SQLite fault, and the failure record cannot be
    /// written either. The cached record stays pending while the durable row keeps the earlier
    /// manifest stage. No settlement step can run before a relaunch: the row offers no Retry, Clear
    /// finished drops the item without deleting the row, and the relaunch settles it with one upload.
    func testLastingAlbumStageWriteFailureHidesRetryAndClearsTheItemUntilARelaunchSettlesIt() async throws {
        let fixture = try Fixture(
            refuseAllSettlementUpdates: true,
            destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album")))
        defer { fixture.cleanup() }

        let item = try await fixture.enqueueAndWaitForFailure()
        XCTAssertNotNil(item.uploadedUID)
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        XCTAssertTrue(fixture.backingStore.hasLastingFailure())
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: fixture.uploader.capabilities),
            [],
            "No settlement step can run before a relaunch, so the row offers no Retry")

        await fixture.manager.clearFinished()
        let afterClear = await fixture.manager.snapshot()
        XCTAssertEqual(afterClear, [], "Clear finished removes an item that cannot settle before a relaunch")

        try executeSideSQL("DROP TRIGGER refuse_all_settlement_update;", at: fixture.databaseURL)
        await fixture.manager.shutdown()
        let relaunched = fixture.makeRelaunchedManager(openingNewStore: true)
        let settled = await fixture.waitForCompletion()
        let settledItem = try XCTUnwrap(settled)
        XCTAssertEqual(settledItem.state, .completed, "The relaunch replays the row Clear finished kept")
        XCTAssertEqual(settledItem.uploadedUID, item.uploadedUID)
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Committed bytes must never upload again")
        let relaunchedStore = try XCTUnwrap(fixture.relaunchedStore)
        let saved = try XCTUnwrap(relaunchedStore.record(for: try XCTUnwrap(fixture.ids.first)))
        XCTAssertEqual(saved.terminalState, .completed)
        await relaunched.shutdown()
    }

    // MARK: Startup replay retries a failing first read

    /// The startup replay latches its "already started" flag before it reads. When the first
    /// sweep fails transiently, no pending row restores and no settlement replays in the whole
    /// session, even though the store heals. The flag must latch only after a successful read,
    /// so the next snapshot retries the replay (#1104).
    func testStartupReplayRetriesAfterATransientReadFailure() async throws {
        let (fixture, saved, id) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        // Leave the row pending the way an interrupted session leaves it: the bytes are committed
        // and the receipt is durable, but the settlement never reached a terminal stage.
        var pending = saved
        pending.stage = .manifestPending
        pending.terminalState = nil
        pending.updatedAt = Date(timeIntervalSinceNow: 1)
        XCTAssertTrue(store.upsert(pending))

        // Shutdown closes the seeding connection. A real relaunch opens a fresh connection on
        // the same database file, so the first sweep must be interrupted on that fresh store.
        await fixture.manager.shutdown()
        let relaunched = fixture.makeRelaunchedManager(openingNewStore: true)
        let freshStore = try XCTUnwrap(fixture.relaunchedStore)
        let interrupt = try SQLiteReadInterrupt(
            in: freshStore,
            matching: "FROM manual_upload_settlement ORDER BY updated_at ASC")
        defer { interrupt.stop() }

        // The first snapshot fails the sweep: nothing restores and nothing replays.
        let firstSnapshot = await relaunched.snapshot()
        XCTAssertTrue(firstSnapshot.isEmpty, "A failed sweep must not present rows as data")
        XCTAssertTrue(interrupt.fired, "The armed interrupt really failed the first sweep")

        // The transient failure healed at the next operation. A later snapshot must retry the
        // replay instead of skipping forever through the flag latched by the failed first read.
        let settled = await fixture.waitForCompletion()
        let settledItem = try XCTUnwrap(settled)
        XCTAssertEqual(settledItem.state, .completed, "The replay must retry after the read heals")
        XCTAssertEqual(settledItem.id, id)
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Replay must never upload bytes again")
        let replayed = try XCTUnwrap(freshStore.record(for: id))
        XCTAssertEqual(replayed.stage, .terminal)
        XCTAssertEqual(replayed.terminalState, .completed)
        await relaunched.shutdown()
    }

    // MARK: resumeAll guards

    /// resumeAll publishes the live snapshot exactly once through pump(). A second `.finalizing`
    /// publish would mean a sweep adopted a settlement a live task still owns. The gate parking is
    /// deterministic: `awaitFirstEntry` resolves only when the album step really entered.
    func testResumeAllDoesNotRepublishAnOwnedLiveSettlement() async throws {
        let attaching = HoldingAlbumAttaching()
        let fixture = try Fixture(
            destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album")),
            albums: attaching)
        defer { fixture.cleanup() }

        let history = StateHistory()
        await fixture.manager.setOnChange { items, _ in history.record(items) }
        let ids = await fixture.enqueue()

        // Park the settlement task inside the album step: the record is pending and owned.
        await attaching.gate.awaitFirstEntry()
        XCTAssertEqual(attaching.gate.enterCount, 1, "The album settlement reached the photo-add step")

        history.reset()
        await fixture.manager.resumeAll()
        XCTAssertEqual(
            history.finalizingCount, 1,
            "resumeAll republished an owned live settlement: expected one snapshot publish")

        attaching.gate.release()
        let settled = await fixture.waitForCompletion()
        let settledItem = try XCTUnwrap(settled)
        XCTAssertEqual(settledItem.state, .completed)
        XCTAssertEqual(fixture.uploader.requests.count, 1, "Committed bytes must never upload again")
        XCTAssertEqual(attaching.gate.enterCount, 1, "The album attach step must run exactly once")
        let saved = try XCTUnwrap(fixture.backingStore.record(for: try XCTUnwrap(ids.first)))
        XCTAssertEqual(saved.stage, .terminal)
        XCTAssertEqual(saved.uploadedUID, settledItem.uploadedUID)
        await fixture.manager.shutdown()
    }

    /// A completed item keeps its terminal record; resumeAll must not replay it as finalizing.
    func testResumeAllLeavesCompletedSettlementsUntouched() async throws {
        let fixture = try Fixture(destination: .library)
        defer { fixture.cleanup() }

        let history = StateHistory()
        await fixture.manager.setOnChange { items, _ in history.record(items) }
        _ = await fixture.enqueue()
        let settled = await fixture.waitForCompletion()
        XCTAssertEqual(try XCTUnwrap(settled).state, .completed)

        history.reset()
        await fixture.manager.resumeAll()
        XCTAssertEqual(history.finalizingCount, 0, "A completed settlement must not replay as finalizing")
        let after = await fixture.manager.snapshot()
        XCTAssertEqual(try XCTUnwrap(after.first).state, .completed)
        XCTAssertEqual(fixture.uploader.requests.count, 1)
        await fixture.manager.shutdown()
    }

    // MARK: Store-level faults

    /// Seeds one completed settlement row through the real manager and returns the raw store, so
    /// store-level fault tests operate on a record SQLite really wrote.
    @discardableResult
    private func seededStore() async throws -> (
        fixture: Fixture, record: UploadManualSettlementRecord, id: UploadQueueItemID
    ) {
        let fixture = try Fixture(destination: .library)
        let ids = await fixture.enqueue()
        let settled = await fixture.waitForCompletion()
        XCTAssertEqual(try XCTUnwrap(settled).state, .completed)
        // The manager keeps its store open here on purpose: shutdown would close the connection,
        // and these fault tests latch and heal the live connection SQLite really wrote through.
        let id = try XCTUnwrap(ids.first)
        let record = try XCTUnwrap(fixture.backingStore.record(for: id))
        XCTAssertEqual(record.stage, .terminal)
        return (fixture, record, id)
    }

    func testInterruptedWriteRecoversAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        let interrupt = try SQLiteReadInterrupt(
            in: store, matching: "INSERT INTO manual_upload_settlement")
        XCTAssertFalse(store.upsert(saved), "The interrupted upsert fails once")
        XCTAssertTrue(interrupt.fired, "The interrupt really fired inside SQLite")
        interrupt.stop()

        XCTAssertFalse(store.isOperational(), "The transient failure stays recorded until recovery")
        XCTAssertTrue(
            store.upsert(saved), "The next upsert heals a transient SQLITE_INTERRUPT latch at its entry")
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), saved)
    }

    func testBusyWriteRecoversAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        var side: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &side), SQLITE_OK)
        defer { sqlite3_close(side) }
        XCTAssertEqual(sqlite3_exec(side, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store.hasLastingFailure(), "A healthy store has no lasting failure")
        XCTAssertFalse(
            store.upsert(saved), "A write against a held write lock fails SQLITE_BUSY after the timeout")
        XCTAssertEqual(sqlite3_exec(side, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store.hasLastingFailure(), "A busy write is a transient failure")

        XCTAssertFalse(store.isOperational(), "The transient failure stays recorded until recovery")
        XCTAssertTrue(store.upsert(saved), "The next upsert heals a transient SQLITE_BUSY latch")
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), saved)
    }

    func testFullWriteRecoversAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        let pageCount = try storePragmaInt(store, "page_count")
        try executeOnStoreConnection("PRAGMA max_page_count=\(pageCount);", store: store)
        var grown = saved
        grown.lastError = String(repeating: "x", count: 40_000)
        grown.updatedAt = Date(timeIntervalSinceNow: 1)
        XCTAssertFalse(
            store.upsert(grown), "A page-limited upsert fails SQLITE_FULL when the payload must grow")
        try executeOnStoreConnection("PRAGMA max_page_count=1073741823;", store: store)

        XCTAssertFalse(store.isOperational(), "The transient failure stays recorded until recovery")
        XCTAssertTrue(store.upsert(grown), "The next upsert heals a transient SQLITE_FULL latch")
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), grown)
    }

    // MARK: Store-level latch classification (agreed deviation: latched directly)

    /// Deviation agreed with the maintainer: SQLITE_LOCKED, SQLITE_NOMEM and SQLITE_IOERR have no
    /// reliable same-handle repro (SQLite reports them only through latches), so these tests latch
    /// the recorded code directly and assert the classification plus the healing behavior.
    func testLockedLatchHealsAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore
        settlementConnection(of: store).markFailed(resultCode: SQLITE_LOCKED)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(
            store.upsert(saved), "The next store operation heals a recorded transient SQLITE_LOCKED")
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), saved)
    }

    func testNoMemoryLatchHealsAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore
        settlementConnection(of: store).markFailed(resultCode: SQLITE_NOMEM)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(
            store.upsert(saved), "The next store operation heals a recorded transient SQLITE_NOMEM")
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), saved)
    }

    func testIoErrorLatchHealsAtTheNextOperation() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore
        settlementConnection(of: store).markFailed(resultCode: SQLITE_IOERR)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(
            store.upsert(saved), "The next store operation heals a recorded transient SQLITE_IOERR")
        XCTAssertEqual(try XCTUnwrap(store.record(for: saved.queueItemID)), saved)
    }

    /// SQLITE_CORRUPT is a lasting class: the latch survives the next operation and reads stop
    /// pretending the row is readable data.
    func testCorruptLatchStaysFailed() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore
        settlementConnection(of: store).markFailed(resultCode: SQLITE_CORRUPT)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(store.hasLastingFailure(), "SQLITE_CORRUPT is a lasting failure")
        XCTAssertFalse(store.upsert(saved), "A lasting SQLITE_CORRUPT latch does not heal")
        XCTAssertNil(
            store.record(for: saved.queueItemID),
            "A failed read must never present an existing row as data")
        guard case .unreadable = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("A failed read must surface unreadable, never absence")
        }
        XCTAssertTrue(store.allRecords().isEmpty, "A failed sweep must never look like absence")
        guard case .unreadable = store.readAllOutcome() else {
            return XCTFail("A failed sweep must surface unreadable, never absence")
        }
        XCTAssertFalse(store.upsert(saved), "The lasting latch keeps refusing writes")
    }

    // MARK: Store-level lasting faults

    /// A trigger raising FAIL on every settlement update is a real lasting SQLite fault. The latch
    /// stays recorded even after the fault clears: only a new connection can recover.
    func testConstraintTriggerLatchStaysFailedAfterTheFaultClears() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        try executeSideSQL(
            """
            CREATE TRIGGER refuse_all_settlement_update BEFORE UPDATE ON manual_upload_settlement
            BEGIN
                SELECT RAISE(FAIL, 'settlement write refused');
            END;
            """,
            at: fixture.databaseURL)
        XCTAssertFalse(store.upsert(saved), "The refused update fails once through real SQLite")
        XCTAssertFalse(store.isOperational(), "The constraint fault latches the connection lasting")
        XCTAssertTrue(store.hasLastingFailure(), "A refused constraint write is a lasting failure")
        XCTAssertNil(store.record(for: saved.queueItemID))
        guard case .unreadable = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("A latched read must surface unreadable, never absence")
        }

        try executeSideSQL("DROP TRIGGER refuse_all_settlement_update;", at: fixture.databaseURL)
        XCTAssertFalse(
            store.upsert(saved), "A lasting latch stays recorded after its cause clears")
        XCTAssertFalse(store.isOperational())
        XCTAssertNil(store.record(for: saved.queueItemID))
    }

    /// An open transaction on the store's own handle is a lasting condition with no result code:
    /// the store refuses writes and never heals within the same connection.
    func testOpenTransactionIsALastingCondition() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        try executeOnStoreConnection("BEGIN IMMEDIATE;", store: store)
        XCTAssertTrue(store.hasLastingFailure(), "An open transaction is a lasting condition")
        XCTAssertFalse(store.upsert(saved), "An open transaction refuses writes and latches lasting")
        try executeOnStoreConnection("ROLLBACK;", store: store)
        XCTAssertFalse(store.isOperational(), "Rolling back does not heal the lasting latch")
        XCTAssertTrue(store.hasLastingFailure(), "The latch recorded inside the transaction stays lasting")
        XCTAssertFalse(store.upsert(saved))
        XCTAssertNil(store.record(for: saved.queueItemID))
        guard case .unreadable = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("A latched read must surface unreadable, never absence")
        }
    }

    /// A transient latch heals at the entry of every store operation, `remove` included: the
    /// delete of a settled row must not stay refused for the whole session (#1104).
    func testRemoveHealsATransientLatchAndDeletesTheRow() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        settlementConnection(of: store).markFailed(resultCode: SQLITE_IOERR)
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(
            store.remove(queueItemID: saved.queueItemID),
            "The next store operation heals a recorded transient SQLITE_IOERR")
        XCTAssertTrue(store.isOperational(), "The successful delete proved the latch healed")
        XCTAssertNil(store.record(for: saved.queueItemID))
    }

    /// A transient latch heals at the entry of every read: a failed read must not stay
    /// refused for the whole session when the recorded SQLite code is transient (#1104).
    func testReadHealsATransientLatch() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        settlementConnection(of: store).markFailed(resultCode: SQLITE_IOERR)
        XCTAssertFalse(store.isOperational())
        guard case .found(let read) = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("The next read heals a recorded transient SQLITE_IOERR latch")
        }
        XCTAssertEqual(read.queueItemID, saved.queueItemID)
        XCTAssertTrue(store.isOperational(), "The successful read proved the latch healed")
    }

    /// The replay sweep reads every row through the same healing entry: a recorded transient
    /// latch must not keep the whole sweep unreadable for the rest of the session (#1104).
    func testReadAllHealsATransientLatch() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        settlementConnection(of: store).markFailed(resultCode: SQLITE_IOERR)
        XCTAssertFalse(store.isOperational())
        guard case .records(let rows) = store.readAllOutcome() else {
            return XCTFail("The next sweep heals a recorded transient SQLITE_IOERR latch")
        }
        XCTAssertEqual(rows.map(\.queueItemID), [saved.queueItemID])
        XCTAssertTrue(store.isOperational(), "The successful sweep proved the latch healed")
    }

    /// While a transaction holds the store's own handle, reads and deletes must refuse the
    /// connection instead of reporting data or success (#1104). The latch is lasting: after the
    /// rollback the delete still refuses, exactly like the existing write assertions above.
    func testAnOpenTransactionMakesReadsAndDeletesUnreadable() async throws {
        let (fixture, saved, _) = try await seededStore()
        defer { fixture.cleanup() }
        let store = fixture.backingStore

        try executeOnStoreConnection("BEGIN IMMEDIATE;", store: store)
        guard case .unreadable = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("A read inside an open transaction must surface unreadable, never data")
        }
        XCTAssertFalse(
            store.remove(queueItemID: saved.queueItemID),
            "A delete inside an open transaction must refuse")

        try executeOnStoreConnection("ROLLBACK;", store: store)
        XCTAssertFalse(
            store.remove(queueItemID: saved.queueItemID),
            "The lasting latch keeps refusing deletes after the rollback")
        XCTAssertFalse(store.isOperational())
    }

    // MARK: - Fixture

    private final class Fixture {
        static let libraryMessage = "Manual upload settlement could not be persisted."
        static let albumMessage =
            UploadError.albumStep("Manual album settlement could not be persisted.").errorDescription

        let backingStore: UploadManualSettlementStore
        let uploader = MockUploader(deliverProgress: false)
        let identityResolver = FakeIdentityResolver()
        private(set) var manager: UploadManager
        private(set) var relaunchedStore: UploadManualSettlementStore?
        private(set) var ids: [UploadQueueItemID] = []
        let expectedFailureMessage: String
        let databaseURL: URL
        private var terminalWriteInterrupt: SQLiteReadInterrupt? = nil
        private let directory: URL
        private let files: [URL]
        private let destination: UploadDestination

        /// - Parameters:
        ///   - terminalWriteInterrupt: arms a one-shot SQLITE_INTERRUPT on the terminal settlement
        ///     upsert, the exact production fault of #1104. Occurrences before the terminal write:
        ///     the manifest-pending insert, plus the album-pending update on album destinations.
        ///   - terminalWriteInterruptShots: how many consecutive settlement upserts the interrupt
        ///     fails, counting the terminal write first. Two shots fail the terminal write and the
        ///     pending-restore write, the double-write fault of the clear-finished issue (#1104).
        ///   - refuseAllSettlementUpdates: installs a trigger that raises FAIL on every
        ///     settlement update, a lasting fault the store cannot heal inside this session.
        init(
            terminalWriteInterrupt: Bool = false,
            terminalWriteInterruptShots: Int = 1,
            refuseAllSettlementUpdates: Bool = false,
            destination: UploadDestination = .library,
            albums: (any AlbumAttaching)? = nil
        ) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            self.directory = directory
            self.destination = destination
            self.databaseURL = directory.appendingPathComponent(
                UploadManualSettlementStore.databaseFileName)
            guard let backing = UploadManualSettlementStore(url: databaseURL) else {
                throw UploadError.backend("The settlement store did not open")
            }
            backingStore = backing
            files = try makeTempFiles(["photo.jpg"], in: directory)
            if case .library = destination.target {
                expectedFailureMessage = Self.libraryMessage
            } else {
                guard let message = Self.albumMessage else {
                    throw UploadError.backend("The album step message is unavailable")
                }
                expectedFailureMessage = message
            }
            if refuseAllSettlementUpdates {
                try executeSideSQL(
                    """
                    CREATE TRIGGER refuse_all_settlement_update BEFORE UPDATE ON manual_upload_settlement
                    BEGIN
                        SELECT RAISE(FAIL, 'settlement write refused');
                    END;
                    """,
                    at: databaseURL)
            }
            if terminalWriteInterrupt {
                var occurrence = 2
                if case .library = destination.target {} else { occurrence = 3 }
                self.terminalWriteInterrupt = try SQLiteReadInterrupt(
                    in: backing,
                    matching: "INSERT INTO manual_upload_settlement",
                    occurrence: occurrence,
                    shots: terminalWriteInterruptShots)
            }
            manager = UploadManager(
                uploader: uploader,
                albums: albums ?? MockAlbumAttaching(),
                identityResolver: identityResolver,
                settlementStore: backing,
                requiresDurableSettlement: true,
                maxConcurrent: 1)
        }

        /// Simulates a relaunch: a new manager over the same database. `openingNewStore` opens a
        /// fresh store connection, as a real relaunch does; the old connection stays untouched.
        func makeRelaunchedManager(openingNewStore: Bool = false) -> UploadManager {
            let store: any UploadManualSettlementStoreProtocol
            if openingNewStore, let fresh = UploadManualSettlementStore(url: databaseURL) {
                relaunchedStore = fresh
                store = fresh
            } else {
                store = backingStore
            }
            let relaunched = UploadManager(
                uploader: uploader,
                albums: MockAlbumAttaching(),
                identityResolver: identityResolver,
                settlementStore: store,
                requiresDurableSettlement: true,
                maxConcurrent: 1)
            manager = relaunched
            return relaunched
        }

        func enqueue() async -> [UploadQueueItemID] {
            ids = await manager.enqueueFiles(files, destination: destination)
            return ids
        }

        func enqueueAndWaitForFailure() async throws -> UploadItem {
            ids = await manager.enqueueFiles(files, destination: destination)
            let item = try await waitForFailure()
            guard case .failed(let message) = item.state, message == expectedFailureMessage else {
                throw UploadError.backend("The armed settlement fault did not fail the upload")
            }
            return item
        }

        func waitForFailure() async throws -> UploadItem {
            try await waitFor(expectedFailureMessage)
        }

        /// Polls until the item completes or the deadline passes, then returns the last snapshot item.
        /// The caller asserts on the state so the RED failure lands on an assertion.
        func waitForCompletion() async -> UploadItem? {
            let deadline = ContinuousClock.now + .seconds(5)
            var current = await manager.snapshot()
            while current.first?.state != .completed, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                current = await manager.snapshot()
            }
            return current.first
        }

        private func waitFor(_ message: String) async throws -> UploadItem {
            let deadline = ContinuousClock.now + .seconds(5)
            var current = await manager.snapshot()
            while current.first?.state != .failed(message: message), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
                current = await manager.snapshot()
            }
            guard let first = current.first, first.state == .failed(message: message) else {
                throw UploadError.backend(
                    "The settlement failure never appeared: \(String(describing: current.first?.state))")
            }
            return first
        }

        func cleanup() {
            terminalWriteInterrupt?.stop()
            backingStore.close()
            relaunchedStore?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
