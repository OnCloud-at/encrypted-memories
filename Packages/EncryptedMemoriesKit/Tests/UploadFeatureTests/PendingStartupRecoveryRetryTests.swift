import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Causal tests for missed retry-timer paths in pending startup recovery (issue #913).
///
/// Two routes that reload source states after a keyed read are compared:
/// 1. Startup recovery (`recoverLaterTrash`): a failed keyed reload keeps the last known
///    state and schedules the degraded 60 s backoff. This is the safe baseline.
/// 2. `removeFromTrashList`: the same failed keyed reload schedules nothing. The stale
///    trash tile stays until some unrelated event repairs the state. This is the gap.
final class PendingStartupRecoveryRetryTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var store: PendingBackupManifestStore!
    private var recorder: PendingBackupEventRecorder!
    private var metadata: FakePendingMetadata!
    private var effects: FakePendingEffects!
    private var coordinator: PendingBackupCoordinator!
    private let date = Date(timeIntervalSince1970: 1_750_000_000.75)
    private let revision = UploadBackupRevision(rawValue: 9)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let storeURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
        metadata = FakePendingMetadata()
        effects = FakePendingEffects()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        await coordinator.close()
        recorder.finish()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        checkmarkDuration: Duration = .seconds(60),
        uncheckedAdmissionLimit: Int = 64,
        replacementJournal: (any EditReplacementJournaling)? = nil,
        identities: (any UploadIdentityStore)? = nil,
        relations: (any UploadDuplicateChecking)? = nil,
        sourceKind: UploadSourceIdentity.Kind = .photoLibraryAsset,
        membershipInterval: Duration = .zero,
        libraryChangeDelay: Duration = .zero,
        unreadableRetryDelay: Duration = .seconds(60),
        unreadableRetryLimit: Duration = .seconds(30 * 60),
        clock: ResultWriteClock? = nil,
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> PendingBackupCoordinator {
        PendingBackupCoordinator(
            store: store,
            queues: [sourceKind: queue],
            metadataProvider: metadata,
            effects: effects,
            recorder: recorder,
            replacementJournal: replacementJournal,
            identities: identities,
            relations: relations,
            configuration: .init(
                membershipInterval: membershipInterval,
                progressInterval: .milliseconds(1),
                doneLinger: .milliseconds(20),
                checkmarkDuration: checkmarkDuration,
                uncheckedAdmissionLimit: uncheckedAdmissionLimit,
                libraryChangeDelay: libraryChangeDelay,
                unreadableRetryDelay: unreadableRetryDelay,
                unreadableRetryLimit: unreadableRetryLimit
            ),
            now: { [date] in clock?.now ?? date },
            sleep: sleep
        )
    }

    private func source(_ id: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary)
    }

    private func key(_ id: String) -> PendingSourceKey {
        PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
    }

    private var storeURL: URL {
        directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
    }

    private static let presentation = PendingPresentationMetadata(
        captureTime: Date(timeIntervalSince1970: 1_750_000_000),
        mediaType: "photo",
        displayName: "Deleted photo"
    )

    private func includedLater(_ id: String) {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: nil)], at: date))
        XCTAssertNotNil(store.include([key(id)], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: id, at: storeURL))
    }

    /// An excluded source whose remote trash is complete. `newerHandoff` inserts a handoff with a newer
    /// remote node ID than the state, so startup recovery reschedules the remote trash (`.scheduled`)
    /// and reconciles; a matching handoff keeps recovery at `.unchanged`. `tile` also lists the source
    /// in "Zuletzt gelöscht" and provides its presentation metadata, so it appears as a trash tile.
    private func excludedAndRemoteTracked(_ id: String, tile: Bool = false, newerHandoff: Bool = true) throws {
        let stateRemote = PhotoUID(volumeID: "vol", nodeID: "old-\(id)")
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key(id), presentation: tile ? Self.presentation : nil, remote: stateRemote)
                ],
                at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: 1, at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key(id), generation: 1, at: date))
        if tile {
            XCTAssertTrue(Self.setColumns("listed_in_trash=1", of: id, at: storeURL))
            metadata.set(key(id), Self.presentation)
        }
        let handoffRemote = PhotoUID(volumeID: "vol", nodeID: "\(newerHandoff ? "new" : "old")-\(id)")
        // The handoff row is inserted last: completing the remote trash reads the latest handoff
        // and would otherwise reschedule the source before the fixture is ready.
        let connection = try KeyedReadFailure.connection(of: store)
        connection.withLock {
            XCTAssertEqual(
                sqlite3_exec(
                    connection.database,
                    """
                    INSERT INTO handoff VALUES('photoLibraryAsset', '\(id)', 9, 'vol', '\(handoffRemote.nodeID)',
                      'uploaded', \(date.timeIntervalSince1970), 1);
                    """, nil, nil, nil), SQLITE_OK)
        }
    }

    private static func setColumns(_ assignments: String, of id: String, at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "UPDATE source_state SET \(assignments) WHERE source_id='\(id)';", nil, nil, nil)
            == SQLITE_OK && sqlite3_changes(db) == 1
    }

    /// Reads the first column of the first row as text, on its own read-only connection.
    private func scalarText(_ sql: String) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private static let settleWindow = Duration.milliseconds(300)

    private func settle() async throws {
        try await Task.sleep(for: Self.settleWindow)
    }

    private func change(_ sql: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK && sqlite3_changes(db) == 1
    }

    // MARK: - Fixtures

    private final class ResultWriteClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private var recorded: [Duration] = []
        private var sleeping: [(Date, OpenGate)] = []
        var now: Date { lock.withLock { value } }
        var waits: [Duration] { lock.withLock { recorded } }

        init(_ date: Date) { value = date }

        func sleep(_ duration: Duration) async throws {
            let gate = OpenGate()
            lock.withLock {
                recorded.append(duration)
                let parts = duration.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                sleeping.append((value.addingTimeInterval(seconds), gate))
            }
            await gate.wait()
            try Task.checkCancellation()
        }

        func advance(by duration: Duration) {
            let due = lock.withLock { () -> [OpenGate] in
                let parts = duration.components
                value = value.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
                let due = sleeping.filter { $0.0 <= value }.map(\.1)
                sleeping.removeAll { $0.0 <= value }
                return due
            }
            due.forEach { $0.open() }
        }

        func releaseAll() {
            let gates = lock.withLock {
                defer { sleeping.removeAll() }
                return sleeping.map(\.1)
            }
            gates.forEach { $0.open() }
        }
    }

    private final class OpenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Interrupts every read whose SQL contains `fragment` on the store's own connection, as a failing disk read would.
    /// The default is the keyed read of a source state.
    private final class KeyedReadFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var interrupted = 0
        private var interruptedStatements: [String] = []
        private let fragment: String
        private let armAfter: String?
        private var armed: Bool
        private var skip: Int
        private var limit: Int
        var count: Int { lock.withLock { interrupted } }
        var interruptedSQL: [String] { lock.withLock { interruptedStatements } }

        /// Lets the first `skip` matching reads pass, then interrupts at most `limit` of them.
        init(
            matching fragment: String = "FROM source_state WHERE source_kind=? AND source_id=?", skip: Int = 0,
            limit: Int = .max, armAfter: String? = nil
        ) {
            self.fragment = fragment
            self.armAfter = armAfter
            self.armed = armAfter == nil
            self.skip = skip
            self.limit = limit
        }

        func install(on store: PendingBackupManifestStore) throws {
            let connection = try Self.connection(of: store)
            connection.withLock {
                _ = sqlite3_trace_v2(
                    connection.database, UInt32(SQLITE_TRACE_STMT),
                    { _, context, pointer, _ in
                        guard let context, let pointer else { return 0 }
                        let statement = OpaquePointer(pointer)
                        let failure = Unmanaged<KeyedReadFailure>.fromOpaque(context).takeUnretainedValue()
                        guard let sql = sqlite3_sql(statement).map({ String(cString: $0) }) else { return 0 }
                        if let armAfter = failure.armAfter, sql.contains(armAfter) {
                            failure.lock.withLock { failure.armed = true }
                        }
                        guard sql.contains(failure.fragment) else { return 0 }
                        let interrupts = failure.lock.withLock { () -> Bool in
                            guard failure.armed else { return false }
                            if failure.skip > 0 {
                                failure.skip -= 1
                                return false
                            }
                            guard failure.limit > 0 else { return false }
                            failure.limit -= 1
                            failure.interrupted += 1
                            failure.interruptedStatements.append(sql)
                            return true
                        }
                        if interrupts { sqlite3_interrupt(sqlite3_db_handle(statement)) }
                        return 0
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        func remove(from store: PendingBackupManifestStore) {
            guard let connection = try? Self.connection(of: store) else { return }
            connection.withLock { _ = sqlite3_trace_v2(connection.database, 0, nil, nil) }
        }

        static func connection(of store: PendingBackupManifestStore) throws -> SQLiteStoreConnection {
            try XCTUnwrap(
                Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                    as? SQLiteStoreConnection)
        }
    }

    private final class LookupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var holds = 1
        private var reached = false
        private let enteredStream: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        private let openStream: AsyncStream<Void>
        private let openContinuation: AsyncStream<Void>.Continuation

        init() {
            (enteredStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
            (openStream, openContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        func pass() async {
            let held = lock.withLock { () -> Bool in
                defer { holds -= 1 }
                if holds > 0 { reached = true }
                return holds > 0
            }
            guard held else { return }
            enteredContinuation.yield()
            for await _ in openStream { return }
        }

        func entered(within limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while !lock.withLock({ reached }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard lock.withLock({ reached }) else {
                open()
                return false
            }
            return true
        }

        func open() {
            lock.withLock { holds = 0 }
            openContinuation.finish()
        }
    }

    private final class DelayLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Duration] = []
        var values: [Duration] { lock.withLock { recorded } }
        func append(_ duration: Duration) { lock.withLock { recorded.append(duration) } }
    }

    private final class FakePendingMetadata: PendingSourceMetadataProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PendingSourceKey: PendingPresentationMetadata] = [:]
        private var requested = Set<PendingSourceKey>()
        private var readCounts: [PendingSourceKey: Int] = [:]
        private var gate: (@Sendable () async -> Void)?

        var fetchGate: (@Sendable () async -> Void)? {
            get { lock.withLock { gate } }
            set { lock.withLock { gate = newValue } }
        }

        func reads(of key: PendingSourceKey) -> Int {
            lock.withLock { readCounts[key, default: 0] }
        }

        func wasRequested(_ key: PendingSourceKey) -> Bool {
            lock.withLock { requested.contains(key) }
        }

        func set(_ key: PendingSourceKey, _ value: PendingPresentationMetadata) {
            lock.withLock { values[key] = value }
        }

        func remove(_ key: PendingSourceKey) {
            _ = lock.withLock { values.removeValue(forKey: key) }
        }

        func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
            let (answer, gate) = lock.withLock {
                requested.formUnion(keys)
                for key in Set(keys) { readCounts[key, default: 0] += 1 }
                return (values.filter { keys.contains($0.key) }, gate)
            }
            await gate?()
            return answer
        }
    }

    private final class FakePendingEffects: PendingBackupEffects, @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [[String]] = []
        private var _returned: [[PendingSourceKey]] = []
        private var _trashed: [[PhotoUID]] = []
        private var _restored: [[PhotoUID]] = []
        private var _favorites: [PhotoUID] = []
        private var _favoriteValues: [Bool] = []
        private var _removeSucceeds = true
        private var _albumResult = PendingEffectResult.done
        private var _favoriteResult = PendingEffectResult.done
        private var _volumeID: String? = "photos-volume"
        private var _trashRetry = Set<PhotoUID>()
        private var _favoriteGate: LookupGate?

        var removed: [[String]] { lock.withLock { _removed } }
        var returned: [[PendingSourceKey]] { lock.withLock { _returned } }
        var trashed: [[PhotoUID]] { lock.withLock { _trashed } }
        var restored: [[PhotoUID]] { lock.withLock { _restored } }
        var favorites: [PhotoUID] { lock.withLock { _favorites } }
        var favoriteValues: [Bool] { lock.withLock { _favoriteValues } }
        var removeSucceeds: Bool {
            get { lock.withLock { _removeSucceeds } }
            set { lock.withLock { _removeSucceeds = newValue } }
        }
        var albumResult: PendingEffectResult {
            get { lock.withLock { _albumResult } }
            set { lock.withLock { _albumResult = newValue } }
        }
        var favoriteResult: PendingEffectResult {
            get { lock.withLock { _favoriteResult } }
            set { lock.withLock { _favoriteResult = newValue } }
        }
        var volumeID: String? {
            get { lock.withLock { _volumeID } }
            set { lock.withLock { _volumeID = newValue } }
        }
        var trashRetry: Set<PhotoUID> {
            get { lock.withLock { _trashRetry } }
            set { lock.withLock { _trashRetry = newValue } }
        }

        var favoriteGate: LookupGate? {
            get { lock.withLock { _favoriteGate } }
            set { lock.withLock { _favoriteGate = newValue } }
        }

        func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
            lock.withLock { _removed.append(identifiers.sorted()) }
            return _removeSucceeds
        }

        func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool {
            lock.withLock { _returned.append(keys.sorted()) }
            return true
        }

        func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
            let succeeded = await returnToBackup(states.map(\.key))
            return Dictionary(uniqueKeysWithValues: states.map { ($0.key, succeeded ? .completed : .unreadable) })
        }

        func photosVolumeID() async -> String? { volumeID }

        func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            lock.withLock { _trashed.append(uids) }
            return .done
        }

        func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            lock.withLock { _restored.append(uids) }
            return .done
        }

        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
            await favoriteGate?.pass()
            return lock.withLock {
                _favorites.append(uid)
                _favoriteValues.append(favorite)
                return _favoriteResult
            }
        }

        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
            lock.withLock { _albumResult }
        }
    }

    // MARK: - Startup recovery

    /// Startup recovery rescheduled the remote trash of a newer handoff (`.scheduled`), then the keyed
    /// reload of that source failed. The safe baseline for issue #913: the degraded regime schedules the
    /// 60 s backoff, and firing that timer retries the interrupted keyed read. While the read stays
    /// unreadable no remote trash dispatch runs, and the long readable wait of the control source
    /// coexists with the backoff instead of replacing it.
    func testStartupRecoveryInterruptedReloadSchedulesDegradedRetry() async throws {
        try excludedAndRemoteTracked("k")
        includedLater("ctrl")

        // Arms after the reschedule UPDATE of `resumeLaterTrash`, so that read itself stays readable and
        // only the recovery reload afterwards is interrupted.
        let failure = KeyedReadFailure(limit: 5, armAfter: "needs_remote_trash=1")
        try failure.install(on: store)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        try await waitUntil { failure.count >= 1 }
        XCTAssertGreaterThanOrEqual(failure.count, 1, "the reload keyed read must be genuinely interrupted")
        XCTAssertTrue(
            failure.interruptedSQL.allSatisfy { $0.contains("FROM source_state WHERE source_kind=? AND source_id=?") },
            "only the keyed source state read may be interrupted, was: \(failure.interruptedSQL)")

        // The safe baseline: the degraded 60 s backoff is scheduled, no action runs while the read fails,
        // and the control source keeps its readable long wait alongside the backoff.
        let backoffDelay = Duration.seconds(60)
        try await waitUntil { clock.waits.contains(backoffDelay) }
        XCTAssertTrue(
            effects.trashed.isEmpty,
            "while the keyed read fails, no remote trash dispatch may run; the handoff stays unconsumed")
        XCTAssertTrue(
            clock.waits.contains(backoffDelay),
            "issue #913 safety baseline: after the failed keyed reload, startup recovery schedules the "
                + "degraded 60 s backoff")
        XCTAssertTrue(
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) },
            "the readable ~5000 s wait of the control source stays scheduled; the backoff is not replaced")

        // The retry is real: firing the fake clock by the backoff makes the coordinator re-attempt the
        // interrupted keyed read (a fresh interrupt beyond the settled startup count).
        let settledCount = failure.count
        clock.advance(by: .seconds(60))
        try await waitUntil { failure.count > settledCount }
        XCTAssertGreaterThan(
            failure.count, settledCount,
            "the 60 s backoff timer must fire and retry the interrupted keyed read")

        // The interrupts never corrupted the durable decision: the handoff row stays as written.
        XCTAssertEqual(
            scalarText("SELECT remote_link_id FROM handoff WHERE source_id='k' AND revision_us=9;"),
            "new-k",
            "the interrupted reads must not change the handoff row")

        failure.remove(from: store)
        await coordinator.close()
        clock.releaseAll()
    }

    /// The same recovery scenario with healthy reads: the remote trash of the newer handoff is dispatched,
    /// the readable schedule (~5000 s) replaces any timer, and no degraded backoff is ever scheduled.
    func testStartupRecoveryHealthyReadControlSchedulesReadableWait() async throws {
        try excludedAndRemoteTracked("k")
        includedLater("ctrl")

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()

        let resumedRemote = PhotoUID(volumeID: "vol", nodeID: "new-k")
        try await waitUntil { effects.trashed.count >= 1 }
        XCTAssertEqual(effects.trashed, [[resumedRemote]], "healthy reads must dispatch the rescheduled remote trash")

        try await waitUntil {
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) }
        }
        XCTAssertTrue(
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) },
            "the healthy path must schedule the long readable wait of the included source")
        XCTAssertFalse(
            clock.waits.contains(Duration.seconds(60)),
            "the healthy path must not schedule the degraded backoff wait")
        XCTAssertEqual(
            clock.waits.filter { $0 < Duration.seconds(130) }, [],
            "the healthy path must not record any degraded backoff wait")

        await coordinator.close()
        clock.releaseAll()
    }

    // MARK: - removeFromTrashList

    /// The `removeFromTrashList` failure route for issue #913: the unlist commits, the keyed reload
    /// after it fails, and the last known state is stale, so the tile stays in the trash list. The
    /// degraded 60 s retry must be scheduled, as startup recovery does, and firing it must repair
    /// the stale tile once the read answers again.
    func testRemoveFromTrashListFailedReloadSchedulesDegradedRetry() async throws {
        try excludedAndRemoteTracked("t", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        try await waitUntil {
            await coordinator.currentSnapshot().trashTiles.contains { $0.key == key("t") }
        }
        let initialSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            initialSnapshot.trashTiles.contains { $0.key == key("t") },
            "the fixture must first show the source in the trash list")

        // Arms after the unlist UPDATE, so the keyed read inside `unlistFromTrash` itself stays readable.
        let failure = KeyedReadFailure(limit: 1, armAfter: "listed_in_trash=0")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t")
        ])
        XCTAssertTrue(
            result,
            "removeFromTrashList must return true when the unlist succeeds despite the reload failure")
        XCTAssertGreaterThanOrEqual(failure.count, 1, "the reload keyed read after the unlist must be interrupted")
        XCTAssertTrue(
            failure.interruptedSQL.allSatisfy { $0.contains("FROM source_state WHERE source_kind=? AND source_id=?") },
            "only the keyed source state read may be interrupted, was: \(failure.interruptedSQL)")
        XCTAssertEqual(
            scalarText("SELECT listed_in_trash FROM source_state WHERE source_id='t';"), "0",
            "the unlist must be committed in the store")

        // The observable symptom: the last known state is stale, so the tile stays in the trash list.
        try await settle()
        let staleSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            staleSnapshot.trashTiles.contains { $0.key == key("t") },
            "the failed reload must leave the stale trash tile until a read succeeds")

        // The repair (#913): the degraded 60 s retry is scheduled, as startup recovery does in the same
        // situation, so the stale tile repairs itself instead of staying until another trigger.
        let backoffDelay = Duration.seconds(60)
        try await waitUntil { clock.waits.contains(backoffDelay) }
        XCTAssertTrue(
            clock.waits.contains(backoffDelay),
            "issue #913: removeFromTrashList must schedule the degraded 60 s retry after its reload failed, "
                + "as startup recovery does")

        // Firing the retry repairs the tile: the interrupt budget is spent, the keyed read answers
        // again, and the trash list drops the stale tile.
        clock.advance(by: .seconds(60))

        // Advance the membership interval (1 s) so the publish task releases from fake-clock sleep
        // and applies the dirty set, refreshing the trash list from the fresh source state.
        clock.advance(by: .seconds(2))
        try await waitUntil {
            await coordinator.currentSnapshot().trashTiles.allSatisfy { $0.key != key("t") }
        }
        let repairedSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            repairedSnapshot.trashTiles.allSatisfy { $0.key != key("t") },
            "the fired 60 s retry must repair the stale trash tile")
        XCTAssertTrue(
            repairedSnapshot.excludedTiles.contains { $0.key == key("t") },
            "the source stays excluded and keeps its settings tile after the repair")

        await coordinator.close()
        clock.releaseAll()
    }

    /// The healthy control of the same route: without the read failure, the tile leaves the trash list
    /// and stays in the excluded list, and no degraded backoff is ever scheduled.
    func testRemoveFromTrashListHealthyReadControlRemovesTile() async throws {
        try excludedAndRemoteTracked("t", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        try await waitUntil {
            await coordinator.currentSnapshot().trashTiles.contains { $0.key == key("t") }
        }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t")
        ])
        XCTAssertTrue(result, "removeFromTrashList must succeed with healthy reads")
        XCTAssertEqual(
            scalarText("SELECT listed_in_trash FROM source_state WHERE source_id='t';"), "0",
            "the unlist must be committed in the store")

        try await waitUntil {
            await coordinator.currentSnapshot().trashTiles.allSatisfy { $0.key != key("t") }
        }
        let removedSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            removedSnapshot.trashTiles.allSatisfy { $0.key != key("t") },
            "the tile must leave the trash list")
        XCTAssertTrue(
            removedSnapshot.excludedTiles.contains { $0.key == key("t") },
            "the source stays excluded and keeps its settings tile")
        XCTAssertFalse(
            clock.waits.contains(Duration.seconds(60)),
            "the healthy route must not schedule the degraded backoff wait")
        XCTAssertEqual(
            clock.waits.filter { $0 < Duration.seconds(130) }, [],
            "the healthy route must not record any degraded backoff wait")

        await coordinator.close()
        clock.releaseAll()
    }
}
