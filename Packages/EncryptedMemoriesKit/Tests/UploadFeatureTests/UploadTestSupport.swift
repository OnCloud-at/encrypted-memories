import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Test doubles that do not care about the network keep a reservation that coordinates with nothing. Production
/// uploaders have no such default: the compiler makes each of them choose its admission.
extension PhotoUploading {
    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await UploadNetworkAdmission().reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }
}

actor UploadTestBarrier {
    private let participantCount: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived == participantCount {
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            continuations.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Access the owned connection from tests without adding a production observation hook.
func withDeniedSQLiteSelect(in store: Any, _ body: () throws -> Void) throws {
    try withSQLiteAuthorization(
        in: store,
        authorizing: { action, _, _ in
            action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK
        }, body)
}

func testUID(_ name: String) -> PhotoUID { PhotoUID(volumeID: "vol", nodeID: "node-\(name)") }

/// In-memory `PhotoUploading` for exercising the queue/state-machine without any SDK. Tracks
/// concurrency, start order, and control-plane calls; can fail named files and deliver phase progress.
final class MockUploader: PhotoUploading, @unchecked Sendable {
    let capabilities: UploadBackendCapabilities

    private let lock = NSLock()
    private var concurrent = 0
    private var _peakConcurrent = 0
    private var _startedOrder: [String] = []
    private var _requests: [PhotoUploadRequest] = []
    private var _cancelledTokens: [UUID] = []
    private var _pausedTokens: [UUID] = []
    private var _resumedTokens: [UUID] = []
    private var transientFailures: [String: Int]  // name to number of initial attempts to fail
    private var networkFailures: [String: Int]  // name to initial NSURLErrorTimedOut attempts
    private var serviceFailures: [String: Int]  // name to initial HTTP 5xx/429-style attempts

    private let workDuration: Duration
    private let deliverProgress: Bool
    private let failNames: Set<String>
    /// Like the production uploader, one admission for every upload of this uploader.
    let admission = UploadNetworkAdmission()
    private var _uploadsWithoutTheirReservation: [String] = []
    /// Names of uploads that started without an active reservation of `admission` for their network kind.
    var uploadsWithoutTheirReservation: [String] { lock.withLock { _uploadsWithoutTheirReservation } }

    /// How long a test waits for a reservation before it fails. A reservation that nobody releases would otherwise
    /// keep the test, and the build lane behind it, waiting for good.
    var reservationTimeout: Duration = .seconds(20)
    private var _reserveCalls = 0
    /// How often a caller asked for a reservation. A transfer that the watchdog ends asks again for its next attempt.
    var reserveCalls: Int { lock.withLock { _reserveCalls } }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        lock.withLock { _reserveCalls += 1 }
        let timeout = reservationTimeout
        let admission = admission
        return try await withThrowingTaskGroup(of: UploadNetworkReservation?.self) { group in
            group.addTask { try await admission.reserve(allowsExpensiveNetwork: allowsExpensiveNetwork) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first: UploadNetworkReservation?
            do {
                first = try await group.next() ?? nil
            } catch {
                group.cancelAll()
                await Self.releaseLateReservations(of: &group)
                throw error
            }
            group.cancelAll()
            await Self.releaseLateReservations(of: &group)
            if let first { return first }
            throw UploadError.backend("The test uploader waited \(timeout) for its network reservation")
        }
    }

    /// A reservation that arrives while the wait ends goes back at once, so no test keeps a place by accident.
    private static func releaseLateReservations(
        of group: inout ThrowingTaskGroup<UploadNetworkReservation?, any Error>
    ) async {
        while true {
            do {
                guard let late = try await group.next() else { return }
                late?.release()
            } catch {
                continue
            }
        }
    }

    init(
        capabilities: UploadBackendCapabilities = .init(
            canUpload: true, supportsCancel: true,
            supportsPauseResume: true, supportsResumeAcrossRelaunch: false),
        workDuration: Duration = .milliseconds(20),
        deliverProgress: Bool = true,
        failNames: Set<String> = [],
        transientFailures: [String: Int] = [:],
        networkFailures: [String: Int] = [:],
        serviceFailures: [String: Int] = [:]
    ) {
        self.capabilities = capabilities
        self.workDuration = workDuration
        self.deliverProgress = deliverProgress
        self.failNames = failNames
        self.transientFailures = transientFailures
        self.networkFailures = networkFailures
        self.serviceFailures = serviceFailures
    }

    private var _remoteCapacityBytes: Int64?
    /// Remaining account storage the capacity check reports; nil means unknown, so every upload proceeds.
    var remoteCapacityBytes: Int64? {
        get { lock.withLock { _remoteCapacityBytes } }
        set { lock.withLock { _remoteCapacityBytes = newValue } }
    }

    func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
        guard let capacity = remoteCapacityBytes, bytes > capacity else { return }
        throw UploadError.accountStorageFull(filename, requiredBytes: bytes, availableBytes: capacity)
    }

    var peakConcurrent: Int { lock.withLock { _peakConcurrent } }
    var startedOrder: [String] { lock.withLock { _startedOrder } }
    var cancelledTokens: [UUID] { lock.withLock { _cancelledTokens } }
    /// Every request that reached the backend - lets dedupe tests assert corrected names and
    /// `expectedSHA1` pass-through.
    var requests: [PhotoUploadRequest] { lock.withLock { _requests } }

    private var _uploaded: [(request: PhotoUploadRequest, uid: PhotoUID)] = []
    private var _distinctNodesForRepeatedNames = false
    /// Like the server, gives a new photo to each upload of a name that uploaded before: `node-NAME#2` and so on.
    /// Off by default, so a repeated name keeps `testUID(name)`.
    var distinctNodesForRepeatedNames: Bool {
        get { lock.withLock { _distinctNodesForRepeatedNames } }
        set { lock.withLock { _distinctNodesForRepeatedNames = newValue } }
    }
    /// Every finished upload with the photo it created.
    var uploaded: [(request: PhotoUploadRequest, uid: PhotoUID)] { lock.withLock { _uploaded } }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let reserved =
            request.networkReservation.map {
                $0.isActive && admission.issued($0) && $0.allowsExpensiveNetwork == request.allowsExpensiveNetwork
            } ?? false
        lock.withLock {
            concurrent += 1
            _peakConcurrent = max(_peakConcurrent, concurrent)
            _startedOrder.append(request.name)
            _requests.append(request)
            if !reserved { _uploadsWithoutTheirReservation.append(request.name) }
        }
        defer { lock.withLock { concurrent -= 1 } }

        if deliverProgress {
            onProgress(UploadProgress(phase: .preparing))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .hashing))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .uploading, fraction: 0.5))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .uploading, fraction: 1.0))
            try await Task.sleep(for: .milliseconds(20))
        } else {
            try await Task.sleep(for: workDuration)
        }

        let transient: Int = lock.withLock {
            let t = transientFailures[request.name] ?? 0
            if t > 0 { transientFailures[request.name] = t - 1 }
            return t
        }
        if transient > 0 { throw UploadError.backend("transient failure for \(request.name)") }
        let network: Int = lock.withLock {
            let count = networkFailures[request.name] ?? 0
            if count > 0 { networkFailures[request.name] = count - 1 }
            return count
        }
        if network > 0 { throw URLError(.timedOut) }
        let service: Int = lock.withLock {
            let count = serviceFailures[request.name] ?? 0
            if count > 0 { serviceFailures[request.name] = count - 1 }
            return count
        }
        if service > 0 { throw UploadError.retryableBackend(code: 503, message: "service unavailable") }
        if failNames.contains(request.name) { throw UploadError.backend("mock failure for \(request.name)") }
        return lock.withLock {
            let earlier = _uploaded.filter { $0.request.name == request.name }.count
            let base = testUID(request.name)
            let uid =
                _distinctNodesForRepeatedNames && earlier > 0
                ? PhotoUID(volumeID: base.volumeID, nodeID: "\(base.nodeID)#\(earlier + 1)") : base
            _uploaded.append((request, uid))
            return uid
        }
    }

    func cancel(token: UUID) async { lock.withLock { _cancelledTokens.append(token) } }
    func pause(token: UUID) async throws { lock.withLock { _pausedTokens.append(token) } }
    func resume(token: UUID) async throws { lock.withLock { _resumedTokens.append(token) } }
}

/// In-memory `AlbumAttaching`. Resolves/creates albums and records adds/covers; can fail the add step
/// to exercise partial-success handling.
final class MockAlbumAttaching: AlbumAttaching, @unchecked Sendable {
    private let lock = NSLock()
    let canCreate: Bool
    let canAdd: Bool
    let failAdd: Bool
    private var _createdNames: [String] = []
    private var _added: [(PhotoUID, String)] = []
    private var _covers: [(String, PhotoUID)] = []

    init(canCreate: Bool = true, canAdd: Bool = true, failAdd: Bool = false) {
        self.canCreate = canCreate
        self.canAdd = canAdd
        self.failAdd = failAdd
    }

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library:
            return nil
        case .existingAlbum(let id, _):
            guard canAdd else { throw UploadError.albumStep("add unsupported") }
            return id
        case .newAlbum(let name):
            guard canCreate else { throw UploadError.albumStep("create unsupported") }
            let n = lock.withLock {
                _createdNames.append(name)
                return _createdNames.count
            }
            return "new-album-\(n)"
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        if failAdd { throw UploadError.backend("album add failed") }
        lock.withLock { _added.append((uid, albumID)) }
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {
        lock.withLock { _covers.append((albumID, photo)) }
    }

    var createdNames: [String] { lock.withLock { _createdNames } }
    var addedSnapshot: [(PhotoUID, String)] { lock.withLock { _added } }
    var coversSnapshot: [(String, PhotoUID)] { lock.withLock { _covers } }
}

/// Records every state each item passes through (deduping consecutive repeats) for state-machine assertions.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [UploadQueueItemID: [UploadItemState]] = [:]

    func record(_ items: [UploadItem]) {
        lock.withLock {
            for item in items {
                var seq = sequences[item.id] ?? []
                if seq.last != item.state { seq.append(item.state) }
                sequences[item.id] = seq
            }
        }
    }

    func sequence(_ id: UploadQueueItemID) -> [UploadItemState] {
        lock.withLock { sequences[id] ?? [] }
    }
}

final class UploadCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [UploadCompletedEvent] = []

    func record(_ event: UploadCompletedEvent) {
        lock.withLock { _events.append(event) }
    }

    var events: [UploadCompletedEvent] {
        lock.withLock { _events }
    }
}

extension UploadBackupSyncQueueStore {
    var restoredCompoundReopener: (@Sendable (UploadBackupSyncQueueEntry, Date) -> Bool?)? { nil }

    func updateDismissedSourceRecheck(
        _ entry: UploadBackupSyncQueueEntry, matchingState: UploadBackupSyncQueueState, matchingLastError: String
    ) -> Bool? { nil }

    func removeMissingSource(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        remove(source: source, revision: revision)
    }

    func missingSourceDiscardGeneration() -> Int64? { 0 }
    func sourcesWithEntries(_ sources: [UploadSourceIdentity]) -> Set<UploadSourceIdentity>? { nil }
    func insertMissingSources(_ entries: [UploadBackupSyncQueueEntry]) -> Bool { false }

    func nextRunnableDate() -> Date? {
        nextRunnableDate(excludingSourcesOf: [])
    }

    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry]? {
        claimRunnable(limit: limit, claimedAt: claimedAt, excludingSourcesOf: [])
    }

    func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        entries.allSatisfy(upsert)
    }

    func entriesWithRemoteCommitReconciliation(limit: Int) throws -> [UploadBackupSyncQueueEntry] {
        guard isOperational() else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
        let limit = max(1, limit)
        var result: [UploadBackupSyncQueueEntry] = []
        result.reserveCapacity(limit)
        for state in UploadBackupSyncQueueState.allCases {
            // Generic test stores cannot express a receipt predicate. Inspect their complete state
            // slice so ordinary rows ahead of a receipt cannot make a complete scan look empty;
            // the production SQLite store overrides this with a bounded WHERE/limit query.
            for entry in entries(in: state, updatedBefore: .distantFuture, limit: .max) {
                if entry.remoteCommitReconciliation != nil {
                    result.append(entry)
                    if result.count == limit { return result }
                }
            }
        }
        guard isOperational() else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
        return result
    }

    func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry? {
        entries(in: state, updatedBefore: .distantFuture, limit: Int.max)
            .min { $0.updatedAt < $1.updatedAt }
    }

    func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord? { nil }

    /// A store without a stamp is always read again.
    func changeToken() -> UploadBackupSyncQueueChangeToken? { nil }

    /// Stores without a complete read prove a result by their health after the read.
    func decisionNextRunnableDate(excludingSourcesOf excludedSources: [UploadSourceIdentity]) throws -> Date? {
        let date = nextRunnableDate(excludingSourcesOf: excludedSources)
        guard isOperational() else { throw SQLiteStoreUnknownReadError() }
        return date
    }

    func decisionEarliestEntry(in state: UploadBackupSyncQueueState) throws -> UploadBackupSyncQueueEntry? {
        let entry = earliestEntry(in: state)
        guard isOperational() else { throw SQLiteStoreUnknownReadError() }
        return entry
    }

    func decisionEntries(
        in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int
    ) throws -> [UploadBackupSyncQueueEntry] {
        let result = entries(in: state, updatedBefore: updatedBefore, limit: limit)
        guard isOperational() else { throw SQLiteStoreUnknownReadError() }
        return result
    }

    func decisionRuntimeIssue(for key: BackupRuntimeIssueKey) throws -> BackupIssueRecord? {
        let issue = runtimeIssue(for: key)
        guard isOperational() else { throw SQLiteStoreUnknownReadError() }
        return issue
    }

    @discardableResult
    func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool { true }

    @discardableResult
    func markNeedsRemoteReconciliation(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard var entry = (try? entry(for: source, revision: revision)) ?? nil else { return false }
        entry.state = .needsRemoteReconciliation
        entry.lastError = lastError
        entry.remoteCommitReconciliation = reconciliation
        entry.updatedAt = updatedAt
        return upsert(entry)
    }

    @discardableResult
    func makeRetryableWorkEligible(updatedAt: Date) -> Int {
        var changed = 0
        for state in [
            UploadBackupSyncQueueState.failed,
            .blockedByDraft,
            .discovered,
            .queuedForUpload,
            .needsRemoteReconciliation,
        ] {
            for entry in entries(in: state, updatedBefore: .distantFuture, limit: .max) {
                guard !entry.isDismissedSourceRecheck else { continue }
                let target: UploadBackupSyncQueueState =
                    switch state {
                    case .failed, .blockedByDraft: .discovered
                    default: state
                    }
                if updateState(
                    source: entry.source,
                    revision: entry.revision,
                    state: target,
                    attempts: state == .failed ? 0 : nil,
                    lastError: entry.lastError,
                    updatedAt: updatedAt
                ) {
                    changed += 1
                }
            }
        }
        return changed
    }

    func removeUnsavedEarlierRevisions(
        of source: UploadSourceIdentity, through revision: UploadBackupRevision, except kept: UploadBackupRevision
    ) -> Bool {
        true
    }

    func removeUnsavedEarlierRevisions(of entries: [UploadBackupSyncQueueEntry]) -> Bool {
        for entry in entries {
            guard removeUnsavedEarlierRevisions(of: entry.source, through: entry.revision, except: entry.revision)
            else {
                return false
            }
        }
        return true
    }

    /// Read-only view of every runnable row through the store's own state reads; claiming would change the rows.
    func runnableEntries() -> [UploadBackupSyncQueueEntry] {
        UploadBackupSyncQueueManifestStore.runnableStates.flatMap {
            entries(in: UploadBackupSyncQueueState(rawValue: $0)!, updatedBefore: .distantFuture, limit: .max)
        }
    }
}

extension XCTestCase {
    /// Polls `manager.snapshot()` until `predicate` holds or the timeout elapses.
    @discardableResult
    func waitUntil(
        _ manager: UploadManager,
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable ([UploadItem]) -> Bool
    ) async -> [UploadItem] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snap = await manager.snapshot()
            if predicate(snap) { return snap }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await manager.snapshot()
    }

    @discardableResult
    func waitForAllTerminal(_ manager: UploadManager, timeout: Duration = .seconds(5)) async -> [UploadItem] {
        await waitUntil(manager, timeout: timeout) { items in
            !items.isEmpty && items.allSatisfy { $0.state.isTerminal }
        }
    }
}

/// Creates `count` tiny real files with the given names in a fresh temp dir; returns their URLs.
func makeTempFiles(_ names: [String], in dir: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try names.map { name in
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}

func withDeniedSQLitePragma(in store: Any, _ body: () throws -> Void) throws {
    try withSQLiteAuthorization(
        in: store,
        authorizing: { action, _, _ in
            action == SQLITE_PRAGMA ? SQLITE_DENY : SQLITE_OK
        }, body)
}

/// Records a failed test read even when a notification callback cannot throw.
func queueEntryForTesting(
    in queue: any UploadBackupSyncQueueStore, source: UploadSourceIdentity, revision: UploadBackupRevision,
    file: StaticString = #filePath, line: UInt = #line
) -> UploadBackupSyncQueueEntry? {
    do { return try queue.entry(for: source, revision: revision) } catch {
        XCTFail("The test queue read failed: \(error)", file: file, line: line)
        return nil
    }
}
