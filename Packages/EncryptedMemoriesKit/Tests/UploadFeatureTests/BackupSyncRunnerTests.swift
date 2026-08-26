import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Fake time: `now` only advances when the runner sleeps, so backoff scheduling is fully
/// deterministic and instant.
final class BackupTestClock: BackupSchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 1_720_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(for seconds: TimeInterval) async throws {
        lock.withLock {
            _sleeps.append(seconds)
            current = current.addingTimeInterval(max(0, seconds))
        }
        await Task.yield()
    }
}

/// Scripted `BackupResourceResolving`: per-source behavior, resolve counting.
final class ScriptedBackupResolver: BackupResourceResolving, @unchecked Sendable {
    enum Behavior {
        case standard
        case missing
        /// Throw `error` for the first `times` resolves, then behave like `.standard`.
        case transientFailure(times: Int)
        /// Throw `BackupTempFileError.diskBudgetExceeded` for the first `times` resolves, then
        /// behave like `.standard`. Models a device low on space while a pass runs.
        case diskPressure(times: Int)
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var remainingFailures: [String: Int] = [:]
    private var _resolveCounts: [String: Int] = [:]
    /// Fixed mtime so resolved revisions match the seeded queue rows (no drift) unless a test
    /// overrides it per source.
    let defaultModified: Date
    private var modifiedOverrides: [String: Date] = [:]
    /// Secondary filenames per source id - resolved entries become Live-Photo-style compounds.
    private var secondaryNames: [String: [String]] = [:]
    private var metadataByIdentifier: [String: [PhotoUploadAdditionalMetadata]] = [:]
    private var deferredIdentifiers: Set<String> = []
    private var preparationProgressIdentifiers: Set<String> = []
    private var capturedPreparationHandlers: [String: BackupResourcePreparationHandler] = [:]
    private var mismatchOnceIdentifiers: Set<String> = []
    private var materializeCounts: [String: Int] = [:]

    func setSecondaries(_ names: [String], for identifier: String) {
        lock.withLock { secondaryNames[identifier] = names }
    }

    func setAdditionalMetadata(_ metadata: [PhotoUploadAdditionalMetadata], for identifier: String) {
        lock.withLock { metadataByIdentifier[identifier] = metadata }
    }

    func setDeferredMaterialization(for identifier: String, mismatchOnce: Bool = false) {
        lock.withLock {
            deferredIdentifiers.insert(identifier)
            if mismatchOnce { mismatchOnceIdentifiers.insert(identifier) }
        }
    }

    func setPreparationProgress(for identifier: String) {
        _ = lock.withLock { preparationProgressIdentifiers.insert(identifier) }
    }

    func emitCapturedPreparationProgress(
        for identifier: String,
        _ progress: BackupResourcePreparationProgress
    ) {
        lock.withLock { capturedPreparationHandlers[identifier] }?(progress)
    }

    func materializeCount(for identifier: String) -> Int {
        lock.withLock { materializeCounts[identifier] ?? 0 }
    }

    init(defaultModified: Date) {
        self.defaultModified = defaultModified
    }

    func set(_ behavior: Behavior, for identifier: String) {
        lock.withLock {
            behaviors[identifier] = behavior
            if case .transientFailure(let times) = behavior { remainingFailures[identifier] = times }
            if case .diskPressure(let times) = behavior { remainingFailures[identifier] = times }
        }
    }

    func setModified(_ date: Date, for identifier: String) {
        lock.withLock { modifiedOverrides[identifier] = date }
    }

    func resolveCount(for identifier: String) -> Int {
        lock.withLock { _resolveCounts[identifier] ?? 0 }
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        let id = entry.source.identifier
        let behavior: Behavior = lock.withLock {
            _resolveCounts[id, default: 0] += 1
            return behaviors[id] ?? .standard
        }
        func consumeFailure() -> Bool {
            lock.withLock {
                let left = remainingFailures[id] ?? 0
                if left > 0 {
                    remainingFailures[id] = left - 1
                    return true
                }
                return false
            }
        }
        switch behavior {
        case .missing:
            return nil
        case .transientFailure:
            if consumeFailure() { throw UploadError.backend("transient resolve failure for \(id)") }
        case .diskPressure:
            if consumeFailure() { throw BackupTempFileStore.BackupTempFileError.diskBudgetExceeded }
        case .standard:
            break
        }

        // Standard resolution (also reached once a transient/disk-pressure budget is exhausted).
        do {
            let modified = lock.withLock { modifiedOverrides[id] } ?? defaultModified
            let secondaries = lock.withLock { secondaryNames[id] } ?? []
            let additionalMetadata = lock.withLock { metadataByIdentifier[id] } ?? []
            let isDeferred = lock.withLock { deferredIdentifiers.contains(id) }
            let snapshot = UploadBackupAssetSnapshot(
                source: entry.source,
                revision: UploadBackupRevision(date: modified),
                editRevision: .unavailable,
                resourceCount: 1 + secondaries.count
            )
            let descriptor = UploadResourceDescriptor(
                source: entry.source,
                fileURL: URL(fileURLWithPath: entry.source.identifier),
                filename: entry.originalFilename,
                fileSize: entry.byteCount ?? 1,
                modificationDate: modified,
                precomputedSHA1Digest: isDeferred ? Self.digest(seed: entry.source.identifier) : nil
            )
            let materialize: (@Sendable () async throws -> UploadResourceDescriptor)?
            if isDeferred {
                materialize = { @Sendable [self] in
                    let shouldMismatch = lock.withLock {
                        materializeCounts[id, default: 0] += 1
                        return mismatchOnceIdentifiers.remove(id) != nil
                    }
                    return UploadResourceDescriptor(
                        source: entry.source,
                        fileURL: URL(fileURLWithPath: entry.source.identifier + ".materialized"),
                        filename: entry.originalFilename,
                        fileSize: entry.byteCount ?? 1,
                        modificationDate: modified,
                        precomputedSHA1Digest: shouldMismatch
                            ? Data(repeating: 0xFF, count: 20)
                            : Self.digest(seed: entry.source.identifier)
                    )
                }
            } else {
                materialize = nil
            }
            return BackupResolvedResource(
                candidate: UploadBackupAssetCandidate(
                    snapshot: snapshot,
                    originalFilename: entry.originalFilename,
                    byteCount: entry.byteCount
                ),
                descriptor: descriptor,
                mediaType: "image/jpeg",
                additionalMetadata: additionalMetadata,
                captureDate: modified,
                secondaries: secondaries.map { name in
                    BackupSecondaryResource(
                        descriptor: UploadResourceDescriptor(
                            source: UploadSourceIdentity(
                                kind: entry.source.kind,
                                identifier: entry.source.identifier,
                                resource: .livePairedVideo
                            ),
                            fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#\(name)"),
                            filename: name,
                            fileSize: 2,
                            modificationDate: modified
                        ),
                        mediaType: "video/quicktime",
                        additionalMetadata: additionalMetadata
                    )
                },
                materialize: materialize
            )
        }
    }

    func resolve(
        _ entry: UploadBackupSyncQueueEntry,
        onPreparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> BackupResolvedResource? {
        let reportsProgress = lock.withLock {
            preparationProgressIdentifiers.contains(entry.source.identifier)
        }
        guard reportsProgress else { return try await resolve(entry) }
        lock.withLock { capturedPreparationHandlers[entry.source.identifier] = onPreparationProgress }

        onPreparationProgress(.init(phase: .identity, fraction: 0.25))
        await Task.yield()
        guard let resolved = try await resolve(entry) else { return nil }
        onPreparationProgress(.init(phase: .identity, fraction: 1))
        await Task.yield()
        guard resolved.hasDeferredMaterialization else { return resolved }

        return BackupResolvedResource(
            candidate: resolved.candidate,
            descriptor: resolved.descriptor,
            mediaType: resolved.mediaType,
            additionalMetadata: resolved.additionalMetadata,
            captureDate: resolved.captureDate,
            secondaries: resolved.secondaries,
            materializeWithProgress: { reporter in
                reporter(.init(phase: .materializing, fraction: 0.2))
                await Task.yield()
                reporter(.init(phase: .materializing, fraction: 0.6))
                await Task.yield()
                reporter(.init(phase: .materializing, fraction: 1))
                return try await resolved.materializedDescriptor()
            },
            cleanup: resolved.cleanup
        )
    }

    private static func digest(seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }
}

/// Shared ordered event log for cross-component ordering assertions.
final class BackupEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) { lock.withLock { _events.append(event) } }
    var events: [String] { lock.withLock { _events } }

    func firstIndex(of event: String) -> Int? { events.firstIndex(of: event) }
}

final class BackupProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BackupSyncProgress] = []

    func append(_ value: BackupSyncProgress) { lock.withLock { values.append(value) } }
    var snapshots: [BackupSyncProgress] { lock.withLock { values } }
}

/// Queue store spy: delegates to the real SQLite store while logging every state write.
final class SpyQueueStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let log: BackupEventLog

    init(inner: UploadBackupSyncQueueManifestStore, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    @discardableResult
    func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        log.append("queue.upsert:\(entry.state.rawValue)")
        return inner.upsert(entry)
    }

    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        inner.entry(for: source, revision: revision)
    }

    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] { inner.nextRunnable(limit: limit) }

    func nextRunnableDate() -> Date? { inner.nextRunnableDate() }

    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        log.append("queue.claimRunnable")
        return inner.claimRunnable(limit: limit, claimedAt: claimedAt)
    }

    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry]
    {
        inner.entries(in: state, updatedBefore: updatedBefore, limit: limit)
    }

    @discardableResult
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        log.append("queue.requeueStaleActive")
        return inner.requeueStaleActive(before: cutoff, updatedAt: updatedAt)
    }

    @discardableResult
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        log.append("queue.state:\(state.rawValue)")
        return inner.updateState(
            source: source, revision: revision, state: state,
            attempts: attempts, lastError: lastError, updatedAt: updatedAt)
    }

    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        inner.remove(source: source, revision: revision)
    }

    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        inner.removeSources(kind: kind, identifiers: identifiers)
    }

    func summary() -> UploadBackupSyncQueueSummary { inner.summary() }
    func count() -> Int { inner.count() }
}

/// Simulates a scan upsert racing the runner immediately after it persisted a future retry. The
/// row becomes due again before `updateState` returns, exactly as a concurrent PhotoKit scan can do.
final class ReenqueueOnFirstRetryQueueStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var didReenqueue = false

    init(inner: UploadBackupSyncQueueManifestStore, now: @Sendable @escaping () -> Date) {
        self.inner = inner
        self.now = now
    }

    func isOperational() -> Bool { inner.isOperational() }
    func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool { inner.upsert(entry) }
    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        inner.entry(for: source, revision: revision)
    }
    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] { inner.nextRunnable(limit: limit) }
    func nextRunnableDate() -> Date? { inner.nextRunnableDate() }
    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        inner.claimRunnable(limit: limit, claimedAt: claimedAt)
    }
    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry]
    {
        inner.entries(in: state, updatedBefore: updatedBefore, limit: limit)
    }
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        inner.requeueStaleActive(before: cutoff, updatedAt: updatedAt)
    }
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard
            inner.updateState(
                source: source,
                revision: revision,
                state: state,
                attempts: attempts,
                lastError: lastError,
                updatedAt: updatedAt
            )
        else { return false }
        let shouldReenqueue = lock.withLock {
            guard !didReenqueue, state == .discovered, updatedAt > now() else { return false }
            didReenqueue = true
            return true
        }
        guard shouldReenqueue,
            var entry = inner.entry(for: source, revision: revision)
        else { return true }
        entry.state = .discovered
        entry.attempts = 0
        entry.lastError = nil
        entry.updatedAt = now()
        return inner.upsert(entry)
    }
    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        inner.remove(source: source, revision: revision)
    }
    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        inner.removeSources(kind: kind, identifiers: identifiers)
    }
    func summary() -> UploadBackupSyncQueueSummary { inner.summary() }
    func count() -> Int { inner.count() }
}

final class BackupThrottleSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BackupThrottleInputs]

    init(_ values: [BackupThrottleInputs]) { self.values = values }

    func next() -> BackupThrottleInputs {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? .unconstrained }
            return values.removeFirst()
        }
    }
}

/// Identity-resolver spy: delegates to the real pipeline while logging `recordUploaded`.
final class SpyIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let log: BackupEventLog

    init(inner: UploadDedupePipeline, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await inner.prepareRemoteIndex(progress: progress)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await inner.prime(descriptors)
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        log.append("manifest.recordUploaded")
        try await inner.recordUploaded(
            descriptor, identity: identity,
            remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
    }

    func invalidateCachedRemoteState() async {
        log.append("manifest.invalidateCachedRemoteState")
        await inner.invalidateCachedRemoteState()
    }

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        log.append("manifest.uploadDidFail")
        await inner.uploadDidFail(descriptor)
    }
}

final class PreparationFailingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: any UploadIdentityResolving
    init(inner: any UploadIdentityResolving) { self.inner = inner }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .indexing, completed: 10, total: 100))
        throw UploadError.backend("index unavailable")
    }
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        try await inner.recordUploaded(
            descriptor, identity: identity, remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID
        )
    }
}

final class RecordFailingIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let lock = NSLock()
    private var remainingFailures: Int

    init(inner: UploadDedupePipeline, failures: Int) {
        self.inner = inner
        remainingFailures = failures
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await inner.prepareRemoteIndex(progress: progress)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await inner.prime(descriptors)
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        let shouldFail = lock.withLock {
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if shouldFail {
            await inner.remoteCommitNeedsReconciliation(descriptor)
            throw UploadError.backend("simulated manifest failure")
        }
        try await inner.recordUploaded(
            descriptor,
            identity: identity,
            remoteVolumeID: remoteVolumeID,
            remoteLinkID: remoteLinkID
        )
    }

    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await inner.remoteCommitNeedsReconciliation(descriptor)
    }
}

actor StopAfterResolveIdentityResolver: UploadIdentityResolving {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var failureSettlements = 0

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        let digest = Data(repeating: 0x11, count: 20)
        return UploadPreflightResult(
            identity: UploadIdentity(
                correctedName: descriptor.filename,
                nameHash: "name-hash",
                sha1Hex: UploadContentSHA1.hexString(digest: digest),
                sha1Digest: digest,
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
    ) async throws {}

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        failureSettlements += 1
    }

    func hasStarted() -> Bool { started }
    func resumeResolve() {
        continuation?.resume()
        continuation = nil
    }
    func settlementCount() -> Int { failureSettlements }
}

/// Uploader that "crashes" after the remote side already accepted the bytes: the first call
/// registers an active remote duplicate with the checker, then throws - simulating a process
/// death between upload success and the manifest write.
final class CrashAfterUploadUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private let checker: FakeChecker
    private let contentHashByName: [String: String]
    private var _attempts = 0

    init(checker: FakeChecker, contentHashByName: [String: String]) {
        self.checker = checker
        self.contentHashByName = contentHashByName
    }

    var attempts: Int { lock.withLock { _attempts } }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let attempt: Int = lock.withLock {
            _attempts += 1
            return _attempts
        }
        let nameHash = "nh(\(request.name))"
        checker.remoteItemsByNameHash[nameHash] = [
            RemotePhotoDuplicate(
                nameHash: nameHash,
                contentHash: contentHashByName[request.name],
                linkState: .active,
                linkID: "remote-\(request.name)"
            )
        ]
        if attempt == 1 {
            throw UploadError.backend("process died after server accepted the upload")
        }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}
}

/// First transfer never completes until cancelled; the retry succeeds. Models an SDK continuation
/// that otherwise leaves one queue row in `.uploading` forever.
final class StallOnceUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private var attempts = 0
    private var cancellationCount = 0
    private var stalledContinuation: CheckedContinuation<PhotoUID, Error>?

    var uploadAttempts: Int { lock.withLock { attempts } }
    var cancellations: Int { lock.withLock { cancellationCount } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        if attempt > 1 { return testUID(request.name) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { stalledContinuation = continuation }
        }
    }

    func cancel(token: UUID) async {
        let continuation: CheckedContinuation<PhotoUID, Error>? = lock.withLock {
            cancellationCount += 1
            defer { stalledContinuation = nil }
            return stalledContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

actor BackupUploadTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }

    func isSignaled() -> Bool { signaled }
}

/// Ignores Swift task cancellation until its upload and native-cancel latches are released.
/// This models an SDK continuation that can return late after the caller requests cancellation.
final class NonCooperativeBackupUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    let uploadStarted = BackupUploadTestLatch()
    let uploadRelease = BackupUploadTestLatch()
    let cancelStarted = BackupUploadTestLatch()
    let cancelRelease = BackupUploadTestLatch()

    private let lock = NSLock()
    private var _uploadAttempts = 0
    private var _cancellations = 0

    var uploadAttempts: Int { lock.withLock { _uploadAttempts } }
    var cancellations: Int { lock.withLock { _cancellations } }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { _uploadAttempts += 1 }
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        await uploadStarted.signal()
        await uploadRelease.wait()
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancellations += 1 }
        await cancelStarted.signal()
        await cancelRelease.wait()
    }
}

final class BackupSyncRunnerTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
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

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-sync-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
            ))
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnavailableQueueStartsNoWorkAndCannotLookDrained() async throws {
        _ = seedEntry("must-remain-pending.heic")
        queueStore.close()

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()
        let queueIsOperational = await runner.isQueueOperational()

        XCTAssertFalse(queueIsOperational)
        XCTAssertFalse(progress.isRunning)
        XCTAssertTrue(uploader.requests.isEmpty, "a failed queue read must never start an upload")
    }

    func testDiskPressureNeverBurnsRetryBudgetAndRecovers() async throws {
        // More disk-pressure failures than the park threshold must not consume retry attempts.
        // Disk pressure must not park an item as `.failed`.
        let entry = seedEntry("crowded.jpg")
        resolver.set(.diskPressure(times: 7), for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed, "disk pressure must never park an item as failed")
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 8, "7 pressure failures, then success")
    }

    func testPersistedRetryDelaySurvivesRunnerRecreation() async throws {
        let entry = seedEntry("resume-after-backoff.jpg", ageSeconds: -30)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(try XCTUnwrap(clock.sleeps.first), 30, accuracy: 0.001)
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(uploader.requests.count, 1)
    }

    func testEligibleOnlyDrainLeavesFutureRetryAndProcessesNewDueWork() async throws {
        let delayed = seedEntry("delayed-retry.jpg", ageSeconds: -3_600)
        let runner = makeRunner()

        let idle = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(idle.isRunning)
        XCTAssertEqual(state(of: delayed), .discovered)
        XCTAssertTrue(clock.sleeps.isEmpty, "reconcile must not sleep behind a future retry date")
        XCTAssertTrue(uploader.requests.isEmpty)

        let newlyDiscovered = seedEntry("newly-discovered.jpg")
        let drained = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: newlyDiscovered), .completed)
        XCTAssertEqual(state(of: delayed), .discovered, "the delayed row keeps its eligibility date")
        XCTAssertEqual(uploader.requests.map(\.name), ["newly-discovered.jpg"])
        XCTAssertEqual(drained.uploaded, 1)
        XCTAssertFalse(drained.isRunning)
        XCTAssertTrue(clock.sleeps.isEmpty, "eligible-only reconciliation must return to observe new queue writes")
    }

    func testEligibleOnlyDrainReturnsImmediatelyWhenRuntimePolicyIsClosed() async throws {
        let due = seedEntry("offline.jpg")
        let runner = makeRunner(throttleInputs: {
            BackupThrottleInputs(isNetworkAvailable: false)
        })

        let progress = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(progress.isPausedByPolicy)
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(state(of: due), .discovered)
        XCTAssertTrue(clock.sleeps.isEmpty, "the controller owns the next date-driven retry")
        XCTAssertEqual(resolver.resolveCount(for: due.source.identifier), 0)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testClaimedRetryCannotBeDroppedWhenScanMakesItDueAgain() async throws {
        let entry = seedEntry("raced-retry.jpg")
        resolver.set(.transientFailure(times: 1), for: entry.source.identifier)
        let queue = ReenqueueOnFirstRetryQueueStore(inner: queueStore, now: { [clock] in clock!.now })

        let progress = await makeRunner(queue: queue).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 2)
        XCTAssertEqual(uploader.requests.map(\.name), ["raced-retry.jpg"])
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.checking, 0, "every atomically claimed row must have a worker")
    }

    func testEligibleOnlyPreservesPolicyPauseFromSecondRuntimeSample() async throws {
        let due = seedEntry("network-changed.jpg")
        let inputs = BackupThrottleSequence([
            .unconstrained,
            BackupThrottleInputs(isNetworkAvailable: false),
        ])

        let progress = await makeRunner(throttleInputs: { inputs.next() })
            .runUntilDrained(mode: .eligibleOnly)

        XCTAssertTrue(progress.isPausedByPolicy)
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(state(of: due), .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testSustainedDiskPressureEndsPassRunnableNotFailed() async throws {
        // The volume stays full for the whole pass: no item can ever export.
        let a = seedEntry("a.jpg")
        let b = seedEntry("b.jpg")
        resolver.set(.diskPressure(times: .max), for: a.source.identifier)
        resolver.set(.diskPressure(times: .max), for: b.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(progress.failed, 0, "a full disk must not manufacture permanent failures")
        XCTAssertEqual(uploader.requests.count, 0)
        XCTAssertEqual(state(of: a), .discovered, "rows stay runnable for the next pass")
        XCTAssertEqual(state(of: b), .discovered)
        let issue = try XCTUnwrap(
            BackupIssueRecord.decode(
                queueStore.entry(for: a.source, revision: a.revision)?.lastError
            ))
        XCTAssertEqual(issue.kind, .deviceStorage)
        XCTAssertNotNil(issue.nextAttemptAt)
    }

    func testRequeueFailedResetsParkedRowsToRunnable() {
        let failed = seedEntry("stuck.jpg", state: .failed, attempts: 4)
        let done = seedEntry("done.jpg", state: .completed)

        let count = queueStore.requeueFailed(updatedAt: clock.now)

        XCTAssertEqual(count, 1, "only the failed row is requeued")
        XCTAssertEqual(state(of: failed), .discovered)
        XCTAssertEqual(
            queueStore.entry(for: failed.source, revision: failed.revision)?.attempts, 0,
            "requeue grants a fresh retry budget")
        XCTAssertEqual(state(of: done), .completed, "terminal-success rows are untouched")
    }

    private func makePipeline(resourceCoordinator: LibraryResourceCoordinator = .shared) -> UploadDedupePipeline {
        UploadDedupePipeline(
            store: identityStore,
            hasher: hasher,
            checker: checker,
            resourceCoordinator: resourceCoordinator,
            now: { [clock] in clock!.now }
        )
    }

    func testTransientNetworkClassification() {
        // These are the network's fault, not the item's to never park, and they drive concurrency backoff.
        for code in [
            URLError.networkConnectionLost, .timedOut, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
        ] {
            XCTAssertTrue(BackupSyncRunner.isTransientNetwork(URLError(code)), "\(code) must be transient-network")
        }
        // The Proton SDK may surface the same as an NSError in the URL-error domain.
        XCTAssertTrue(
            BackupSyncRunner.isTransientNetwork(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(
            BackupSyncRunner.isTransientNetwork(
                UploadError.transport(code: NSURLErrorTimedOut, message: "timed out")))
        // Item-specific / non-network failures must not be treated as transient network.
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(URLError(.badURL)))
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(UploadError.backend("server said no")))
        XCTAssertFalse(BackupSyncRunner.isTransientNetwork(NSError(domain: "Other", code: NSURLErrorTimedOut)))
    }

    private func makeRunner(
        uploader: (any PhotoUploading)? = nil,
        identityResolver: (any UploadIdentityResolving)? = nil,
        resolver: (any BackupResourceResolving)? = nil,
        queue: (any UploadBackupSyncQueueStore)? = nil,
        retry: BackupRetryPolicy = BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
        throttle: BackupThrottlePolicy = BackupThrottlePolicy(baseConcurrency: 2),
        uploadStallTimeout: TimeInterval = 180,
        uploadStallPollInterval: TimeInterval = 5,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        throttleInputs: @Sendable @escaping () -> BackupThrottleInputs = { .unconstrained }
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queue ?? queueStore,
            preflight: preflight,
            resolver: resolver ?? self.resolver,
            identityResolver: identityResolver ?? makePipeline(resourceCoordinator: resourceCoordinator),
            uploader: uploader ?? self.uploader,
            resourceCoordinator: resourceCoordinator,
            configuration: BackupSyncRunner.Configuration(
                uploadStallTimeout: uploadStallTimeout,
                uploadStallPollInterval: uploadStallPollInterval,
                retry: retry,
                throttle: throttle
            ),
            throttleInputs: throttleInputs,
            clock: clock,
            now: { [clock] in clock!.now }
        )
    }

    func testStalledUploadIsCancelledAndRetriedWithoutParkingItem() async throws {
        let entry = seedEntry("stalled.jpg")
        let stalledUploader = StallOnceUploader()
        let runner = makeRunner(
            uploader: stalledUploader,
            uploadStallTimeout: 0.05,
            uploadStallPollInterval: 0.01
        )

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(stalledUploader.cancellations, 1)
        XCTAssertEqual(stalledUploader.uploadAttempts, 2)
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.failed, 0, "a stalled transport is retryable, not an item failure")
    }

    func testTimeoutJoinsNativeCancellationAndUploadBeforeRetry() async throws {
        let entry = seedEntry("timeout-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(
            uploader: stalledUploader,
            uploadStallTimeout: 0.05,
            uploadStallPollInterval: 0.01
        )
        let drainReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let returnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "timeout must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let returnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "native cancellation alone must not release the uploading row")

        await stalledUploader.uploadRelease.signal()
        _ = await drain.value

        let returnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(returnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "timeout must issue one native cancellation")
        XCTAssertEqual(stalledUploader.uploadAttempts, 2, "the settled timeout may retry once")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testTaskCancellationJoinsNativeCancellationAndUploadBeforeReversion() async throws {
        let entry = seedEntry("task-cancel-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(uploader: stalledUploader, uploadStallTimeout: 60, uploadStallPollInterval: 5)
        let drainReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        drain.cancel()
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let returnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "task cancellation must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let returnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(returnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "task cancellation must join the upload after native cancellation returns")

        await stalledUploader.uploadRelease.signal()
        _ = await drain.value

        let returnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(returnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "task cancellation must issue one native cancellation")
        XCTAssertEqual(state(of: entry), .queuedForUpload)
    }

    func testStopJoinsNativeCancellationAndUploadBeforeReversion() async throws {
        let entry = seedEntry("stop-join.jpg")
        let stalledUploader = NonCooperativeBackupUploader()
        let runner = makeRunner(uploader: stalledUploader, uploadStallTimeout: 60, uploadStallPollInterval: 5)
        let drainReturned = BackupUploadTestLatch()
        let stopReturned = BackupUploadTestLatch()
        let drain = Task {
            let progress = await runner.runUntilDrained()
            await drainReturned.signal()
            return progress
        }

        await stalledUploader.uploadStarted.wait()
        let stop = Task {
            await runner.stop()
            await stopReturned.signal()
        }
        await stalledUploader.cancelStarted.wait()
        await Task.yield()
        XCTAssertEqual(stalledUploader.cancellations, 1)
        let stopReturnedBeforeNativeCancel = await stopReturned.isSignaled()
        let drainReturnedBeforeNativeCancel = await drainReturned.isSignaled()
        XCTAssertFalse(stopReturnedBeforeNativeCancel)
        XCTAssertFalse(drainReturnedBeforeNativeCancel)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "stop must not requeue while native cancellation and upload remain blocked")

        await stalledUploader.cancelRelease.signal()
        await Task.yield()
        let stopReturnedBeforeUploadSettlement = await stopReturned.isSignaled()
        let drainReturnedBeforeUploadSettlement = await drainReturned.isSignaled()
        XCTAssertFalse(stopReturnedBeforeUploadSettlement)
        XCTAssertFalse(drainReturnedBeforeUploadSettlement)
        XCTAssertEqual(
            state(of: entry), .uploading,
            "stop must join the upload after native cancellation returns")

        await stalledUploader.uploadRelease.signal()
        await stop.value
        _ = await drain.value

        let stopReturnedAfterSettlement = await stopReturned.isSignaled()
        let drainReturnedAfterSettlement = await drainReturned.isSignaled()
        XCTAssertTrue(stopReturnedAfterSettlement)
        XCTAssertTrue(drainReturnedAfterSettlement)
        XCTAssertEqual(stalledUploader.cancellations, 1, "stop must issue one native cancellation")
        XCTAssertEqual(state(of: entry), .queuedForUpload)
    }

    func testStopAfterUploadDecisionSettlesClaimBeforeRevertingQueueRow() async throws {
        let entry = seedEntry("stop-after-resolve.jpg")
        let identityResolver = StopAfterResolveIdentityResolver()
        let runner = makeRunner(identityResolver: identityResolver)
        let drain = Task { await runner.runUntilDrained() }

        while !(await identityResolver.hasStarted()) {
            await Task.yield()
        }
        await runner.stop()
        await identityResolver.resumeResolve()
        let progress = await drain.value
        let settlementCount = await identityResolver.settlementCount()

        XCTAssertEqual(settlementCount, 1)
        XCTAssertEqual(state(of: entry), .discovered)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertFalse(progress.isRunning)
    }

    func testManifestFailureAfterRemoteCommitReconcilesWithoutSecondUpload() async throws {
        let entry = seedEntry("committed-before-manifest.jpg")
        let pipeline = makePipeline()
        let failing = RecordFailingIdentityResolver(inner: pipeline, failures: 2)

        _ = await makeRunner(identityResolver: failing).runUntilDrained(mode: .eligibleOnly)

        let pending = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertNotNil(pending.remoteCommitReconciliation)
        XCTAssertEqual(uploader.requests.count, 1, "the server commit happened exactly once")

        clock.advance(by: 2)
        let progress = await makeRunner(identityResolver: pipeline).runUntilDrained(mode: .eligibleOnly)

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(uploader.requests.count, 1, "reconciliation must never upload committed bytes again")
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    private func seedEntry(
        _ id: String,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        ageSeconds: TimeInterval = 60
    ) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/\(id)")),
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: id,
            byteCount: 4,
            state: state,
            attempts: attempts,
            updatedAt: clock.now.addingTimeInterval(-ageSeconds)
        )
        queueStore.upsert(entry)
        return entry
    }

    /// The (nameHash, contentHash) pair the pipeline will compute for a standard resolved entry.
    private func expectedHashes(id: String) -> (nameHash: String, contentHash: String) {
        let path = URL(fileURLWithPath: "/backup/\(id)").standardizedFileURL.path
        return ("nh(\(id))", expectedContentHash(path: path))
    }

    private func expectedContentHash(path: String) -> String {
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in path.utf8.enumerated() { digest[i % 20] ^= byte }
        let hex = UploadContentSHA1.hexString(digest: digest)
        return "ch(\(hex))"
    }

    private func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queueStore.entry(for: entry.source, revision: entry.revision)?.state
    }

    func testRemoteIndexPreparationFailureLeavesQueueRunnableAndFailsClosed() async throws {
        let entry = seedEntry("waiting.jpg")
        let runner = makeRunner(identityResolver: PreparationFailingIdentityResolver(inner: makePipeline()))

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .discovered)
        XCTAssertTrue(progress.remoteIndexPreparationFailed)
        XCTAssertEqual(progress.remoteIndexPreparation?.completed, 10)
        XCTAssertEqual(progress.remoteIndexPreparationIssue?.kind, .remoteService)
        var persistedIssue = try XCTUnwrap(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(persistedIssue.kind, .remoteService)
        XCTAssertEqual(persistedIssue.automaticRetryAttempt, 1)
        XCTAssertEqual(persistedIssue.nextAttemptAt, clock.now.addingTimeInterval(1))
        XCTAssertTrue(uploader.requests.isEmpty)

        let secondFailure = makeRunner(identityResolver: PreparationFailingIdentityResolver(inner: makePipeline()))
        _ = await secondFailure.runUntilDrained()
        persistedIssue = try XCTUnwrap(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(persistedIssue.automaticRetryAttempt, 2)
        XCTAssertEqual(persistedIssue.nextAttemptAt, clock.now.addingTimeInterval(2))

        let retry = makeRunner()
        let recovered = await retry.runUntilDrained()
        XCTAssertNil(queueStore.runtimeIssue(for: .remoteIndexPreparation))
        XCTAssertEqual(recovered.uploaded, 1)
    }

    func testManualRetryClearsPersistedRemoteIndexBackoff() async throws {
        XCTAssertTrue(
            queueStore.setRuntimeIssue(
                BackupIssueRecord(
                    kind: .remoteService,
                    detail: "temporarily unavailable",
                    nextAttemptAt: clock.now.addingTimeInterval(64),
                    automaticRetryAttempt: 7
                ),
                for: .remoteIndexPreparation
            ))

        let changed = await makeRunner().makeRetryableWorkEligibleNow()

        XCTAssertEqual(changed, 1)
        XCTAssertNil(queueStore.runtimeIssue(for: .remoteIndexPreparation))
    }

    func testRunRequeuesStaleActiveRowsAndProcessesThem() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let stuckUploading = seedEntry("stuck-upload.jpg", state: .uploading)
        let stuckChecking = seedEntry("stuck-check.jpg", state: .checking)

        let runner = makeRunner(queue: spyQueue)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(log.events.first, "queue.requeueStaleActive", "recovery must run before any draining")
        XCTAssertEqual(state(of: stuckUploading), .completed)
        XCTAssertEqual(state(of: stuckChecking), .completed)
        XCTAssertEqual(uploader.requests.count, 2)
        XCTAssertEqual(progress.uploaded, 2)
        XCTAssertEqual(progress.backedUp, 2)
        XCTAssertFalse(progress.isRunning)
    }

    func testSourceMissingIsRemovedWithoutFailure() async throws {
        let entry = seedEntry("gone.jpg")
        resolver.set(.missing, for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.sourceMissing, 0)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)

        // A second pass has no row to resurrect or re-resolve.
        _ = await runner.runUntilDrained()
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)
        XCTAssertNil(queueStore.entry(for: entry.source, revision: entry.revision))
    }

    func testPhotoLibraryDeletionCancelsInFlightUploadAndDoesNotRecreateQueueRow() async throws {
        let source = UploadSourceIdentity(
            kind: .photoLibraryAsset,
            identifier: "deleted-during-upload",
            resource: .primary
        )
        let entry = UploadBackupSyncQueueEntry(
            source: source,
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: "deleted.heic",
            byteCount: 4,
            updatedAt: clock.now
        )
        XCTAssertTrue(queueStore.upsert(entry))

        let stalledUploader = NonCooperativeBackupUploader()
        let runner = BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resolver,
            identityResolver: makePipeline(),
            uploader: stalledUploader,
            configuration: .init(uploadStallTimeout: 60, uploadStallPollInterval: 5),
            clock: BackupContinuousClock(),
            now: { [clock] in clock!.now }
        )
        let drain = Task { await runner.runUntilDrained() }
        await stalledUploader.uploadStarted.wait()

        let removal = Task { await runner.removePhotoLibraryAssets([source.identifier]) }
        await stalledUploader.cancelStarted.wait()

        XCTAssertNil(
            queueStore.entry(for: source, revision: entry.revision),
            "local deletion must become authoritative before native cancellation returns")
        let progressWhileNativeCancellationIsPending = await runner.currentProgress()
        XCTAssertEqual(progressWhileNativeCancellationIsPending.total, 0)

        await stalledUploader.cancelRelease.signal()
        await stalledUploader.uploadRelease.signal()
        let removed = await removal.value
        XCTAssertEqual(removed, 1)
        let progress = await drain.value

        XCTAssertEqual(stalledUploader.cancellations, 1)
        XCTAssertNil(queueStore.entry(for: source, revision: entry.revision))
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(progress.sourceMissing, 0)
    }

    func testDraftBlocksWithBackoffAndNeverCountsAsBackedUp() async throws {
        let entry = seedEntry("draft.jpg")
        let hashes = expectedHashes(id: "draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: nil, linkState: .draft, linkID: nil
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 1)
        XCTAssertEqual(progress.blocked, 1)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertLessThan(progress.fraction, 1.0, "a blocked row must keep the fraction honest")
        let issue = try XCTUnwrap(
            BackupIssueRecord.decode(
                queueStore.entry(for: entry.source, revision: entry.revision)?.lastError
            ))
        XCTAssertEqual(issue.kind, .remoteDraft)
        XCTAssertNotNil(issue.nextAttemptAt)

        // Next pass after the backoff window: re-checked once more, still blocked, attempts grow.
        clock.advance(by: 120)
        let findsBefore = checker.findCallCount
        _ = await runner.runUntilDrained()
        XCTAssertGreaterThan(checker.findCallCount, findsBefore, "the draft must be re-checked")
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 2)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testManualRetryRechecksDraftImmediatelyWithoutBlindUpload() async throws {
        let entry = seedEntry("manual-draft.jpg")
        let hashes = expectedHashes(id: "manual-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: nil,
                linkState: .draft,
                linkID: nil
            )
        ]
        let runner = makeRunner()
        _ = await runner.runUntilDrained()
        let first = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(first.state, .blockedByDraft)
        XCTAssertGreaterThan(first.updatedAt, clock.now)

        let findsBefore = checker.findCallCount
        let madeEligible = await runner.makeRetryableWorkEligibleNow()
        XCTAssertEqual(madeEligible, 1)
        let madeDue = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(madeDue.state, .discovered)
        XCTAssertEqual(madeDue.updatedAt, clock.now)
        XCTAssertEqual(madeDue.attempts, 1)

        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertGreaterThan(checker.findCallCount, findsBefore, "manual retry must bypass the cached draft answer")
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.state, .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 2)
        XCTAssertTrue(uploader.requests.isEmpty, "a repeated draft must remain fail-closed")
    }

    func testForeignDraftBecomesDismissiblePermanentFailureAtRetryLimit() async throws {
        let entry = seedEntry("foreign-draft.jpg")
        let hashes = expectedHashes(id: "foreign-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: nil,
                linkState: .draft,
                linkID: "foreign-draft",
                clientUID: "another-installation"
            )
        ]
        let runner = makeRunner(retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2))

        _ = await runner.runUntilDrained()
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        clock.advance(by: 120)
        let progress = await runner.runUntilDrained()

        let parked = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(parked.attempts, 2)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .remoteDraftStale)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.blocked, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testOwnInterruptedDraftUploadsThroughExplicitOverride() async throws {
        let entry = seedEntry("own-draft.jpg")
        let hashes = expectedHashes(id: "own-draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .draft,
                linkID: "own-draft",
                clientUID: "this-installation"
            )
        ]
        let pipeline = UploadDedupePipeline(
            store: identityStore,
            hasher: hasher,
            checker: checker,
            currentClientUID: "this-installation",
            now: { [clock] in clock!.now }
        )
        let runner = makeRunner(identityResolver: pipeline)

        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(uploader.requests.first).overrideExistingDraft)
    }

    func testActiveDuplicateBecomesAlreadyBackedUpWithoutUpload() async throws {
        let entry = seedEntry("dup.jpg")
        let hashes = expectedHashes(id: "dup.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash, contentHash: hashes.contentHash, linkState: .active, linkID: "remote-1"
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertTrue(uploader.requests.isEmpty, "an active duplicate must never re-upload bytes")
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(progress.fraction, 1.0)

        // The preflight index now proves the revision complete - the "backed up" claim is durable.
        let record = stateStore.record(
            for: entry.source,
            revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
    }

    func testActiveDuplicateNeverMaterializesDeferredBytes() async throws {
        let entry = seedEntry("deferred-duplicate.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        let hashes = expectedHashes(id: "deferred-duplicate.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: hashes.nameHash,
                contentHash: hashes.contentHash,
                linkState: .active,
                linkID: "remote-deferred"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(
            resolver.materializeCount(for: entry.source.identifier), 0,
            "hash-only PhotoKit probes must not create temp files for known duplicates")
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.backedUp, 1)
    }

    func testNewDeferredResourceMaterializesExactlyOnceBeforeUpload() async throws {
        let entry = seedEntry("deferred-new.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(resolver.materializeCount(for: entry.source.identifier), 1)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertTrue(uploader.requests[0].fileURL.path.hasSuffix(".materialized"))
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testDeferredResourceChangeIsRehashedBeforeAnyUpload() async throws {
        let entry = seedEntry("deferred-changing.jpg")
        resolver.setDeferredMaterialization(for: entry.source.identifier, mismatchOnce: true)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(
            resolver.materializeCount(for: entry.source.identifier), 2,
            "a changed export must be discarded and freshly resolved")
        XCTAssertEqual(uploader.requests.count, 1, "stale hash identity must never reach the uploader")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testTrashedAndDeletedRemoteDuplicatesAreNotBackedUp() async throws {
        let trashed = seedEntry("trashed.jpg")
        let deleted = seedEntry("deleted.jpg")
        let trashedHashes = expectedHashes(id: "trashed.jpg")
        let deletedHashes = expectedHashes(id: "deleted.jpg")
        checker.remoteItemsByNameHash[trashedHashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: trashedHashes.nameHash, contentHash: trashedHashes.contentHash, linkState: .trashed,
                linkID: "t-1"
            )
        ]
        checker.remoteItemsByNameHash[deletedHashes.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: deletedHashes.nameHash, contentHash: deletedHashes.contentHash, linkState: nil, linkID: "d-1"
            )
        ]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: trashed), .skippedRemoteDeletion)
        XCTAssertEqual(state(of: deleted), .skippedRemoteDeletion)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.skippedRemoteDeletions, 2)
        XCTAssertEqual(progress.backedUp, 0, "respected deletions must never count as backed up")
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(state(of: trashed)?.isTerminalSuccess, true)
        XCTAssertEqual(state(of: deleted)?.isTerminalSuccess, true)
        XCTAssertEqual(stateStore.count(), 0, "no preflight completeness record may exist for skipped deletions")
    }

    func testUploadRecordsManifestBeforeQueueCompletion() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let spyResolver = SpyIdentityResolver(inner: makePipeline(), log: log)
        _ = seedEntry("fresh.jpg")

        let runner = makeRunner(identityResolver: spyResolver, queue: spyQueue)
        _ = await runner.runUntilDrained()

        let recordIndex = try XCTUnwrap(log.firstIndex(of: "manifest.recordUploaded"))
        let completedIndex = try XCTUnwrap(log.firstIndex(of: "queue.state:completed"))
        XCTAssertLessThan(
            recordIndex, completedIndex,
            "the manifest must remember the upload before the queue row turns terminal")
    }

    func testCrashAfterUploadBeforeRecordResolvesToDuplicateOnRetry() async throws {
        let entry = seedEntry("crash.jpg")
        let hashes = expectedHashes(id: "crash.jpg")
        let crashingUploader = CrashAfterUploadUploader(
            checker: checker,
            contentHashByName: ["crash.jpg": hashes.contentHash]
        )

        let runner = makeRunner(uploader: crashingUploader)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(crashingUploader.attempts, 1, "the retry must NOT upload the bytes again")
        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(hasher.hashCount, 1, "the persisted identity must spare the rehash on retry")
    }

    func testTransientFailuresBackOffAndEventuallySucceed() async throws {
        let entry = seedEntry("flaky.jpg")
        resolver.set(.transientFailure(times: 3), for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 4)
        // Exponential waits for attempts 1..3 must actually be scheduled (no hot loop).
        for expected in [1.0, 2.0, 4.0] {
            XCTAssertTrue(clock.sleeps.contains(expected), "missing backoff wait of \(expected)s in \(clock.sleeps)")
        }
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testRetryBudgetParksAsFailedInsteadOfHotLooping() async throws {
        let entry = seedEntry("broken.jpg")
        resolver.set(.transientFailure(times: 99), for: entry.source.identifier)

        let runner = makeRunner(retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 3))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .failed)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 3)
        XCTAssertEqual(
            resolver.resolveCount(for: entry.source.identifier), 3, "parked items must stop consuming attempts")
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.needsAttention, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testRetryableServiceFailureDoesNotExhaustItemBudget() async throws {
        let entry = seedEntry("server-flaky.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["server-flaky.jpg": 5]
        )

        let runner = makeRunner(
            uploader: flakyUploader,
            retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2)
        )
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(flakyUploader.requests.count, 6)
        XCTAssertEqual(progress.failed, 0, "temporary service failures must never strand valid media")
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 8, 16],
            "service retries use durable capped backoff without consuming the item budget")
    }

    func testEnvironmentalBackoffOrdinalSurvivesRunnerRecreation() async throws {
        let entry = seedEntry("recreated-runner.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["recreated-runner.jpg": 2]
        )
        let retry = BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 2)

        _ = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        var stored = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        var issue = try XCTUnwrap(BackupIssueRecord.decode(stored.lastError))
        XCTAssertEqual(issue.automaticRetryAttempt, 1)
        XCTAssertEqual(issue.nextAttemptAt, clock.now.addingTimeInterval(1))
        XCTAssertEqual(stored.attempts, 0)

        clock.advance(by: 1)
        _ = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        stored = try XCTUnwrap(queueStore.entry(for: entry.source, revision: entry.revision))
        issue = try XCTUnwrap(BackupIssueRecord.decode(stored.lastError))
        XCTAssertEqual(issue.automaticRetryAttempt, 2)
        XCTAssertEqual(issue.nextAttemptAt, clock.now.addingTimeInterval(2))
        XCTAssertEqual(stored.attempts, 0)

        clock.advance(by: 2)
        let recovered = await makeRunner(uploader: flakyUploader, retry: retry)
            .runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(recovered.uploaded, 1)
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testNetworkAndServiceFailuresShareOneEnvironmentalBackoffSequence() async throws {
        let entry = seedEntry("mixed-outage.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            networkFailures: ["mixed-outage.jpg": 1],
            serviceFailures: ["mixed-outage.jpg": 1]
        )

        let progress = await makeRunner(uploader: flakyUploader).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2],
            "switching from a timeout to a Proton 503 must not reset automatic backoff")
    }

    func testEnvironmentalBackoffCapsWithoutParkingValidItem() async throws {
        let entry = seedEntry("long-outage.jpg")
        let flakyUploader = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            serviceFailures: ["long-outage.jpg": 7]
        )
        let retry = BackupRetryPolicy(baseDelay: 1, maxDelay: 4, maxAttempts: 2)

        let progress = await makeRunner(uploader: flakyUploader, retry: retry).runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0)
        XCTAssertEqual(clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 4, 4, 4, 4])
    }

    func testLegacyThrottleDoesNotOwnCriticalHeavyWorkAdmission() async throws {
        let entry = seedEntry("hot.jpg")

        let runner = makeRunner(throttleInputs: { BackupThrottleInputs(thermalLevel: .critical) })
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            state(of: entry), .completed,
            "the legacy network throttle does not own local heavy-work admission")
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testEnforcedCoordinatorDefersAutomaticBackupHeavyWorkUntilStableRecovery() async throws {
        let entry = seedEntry("coordinated.jpg")
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .critical))
        let coordinator = LibraryResourceCoordinator(
            runtimeState: runtimeState,
            recoveryDelay: .milliseconds(20)
        )
        await coordinator.startObserving()
        let runner = makeRunner(resourceCoordinator: coordinator)

        let drain = Task {
            await runner.runUntilDrained(mode: .eligibleOnly, workIntent: .automatic)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        let pausedMetrics = await coordinator.metrics()
        XCTAssertEqual(pausedMetrics.policyPauses, 1)

        runtimeState.update { $0.thermalLevel = .nominal }
        let progress = await drain.value
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        let finalMetrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(finalMetrics.permitsAcquired, 2)
        XCTAssertEqual(finalMetrics.permitsAcquired, finalMetrics.permitsReleased)
    }

    func testEnforcedCoordinatorAllowsOneFileManualBackupAtSeriousPressure() async throws {
        let entry = seedEntry("manual-hot.jpg")
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .serious))
        let coordinator = LibraryResourceCoordinator(runtimeState: runtimeState)
        let runner = makeRunner(resourceCoordinator: coordinator)

        let progress = await runner.runUntilDrained(
            mode: .eligibleOnly,
            workIntent: .userInitiated
        )

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1)
        let metrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(metrics.permitsAcquired, 2)
        XCTAssertEqual(metrics.permitsAcquired, metrics.permitsReleased)
    }

    func testConcurrentIdenticalContentUploadsExactlyOnce() async throws {
        let first = seedEntry("copy-a.jpg")
        let second = seedEntry("copy-b.jpg")
        hasher.contentSeeds["/backup/copy-a.jpg"] = "identical-bytes"
        hasher.contentSeeds["/backup/copy-b.jpg"] = "identical-bytes"
        let slowUploader = MockUploader(workDuration: .milliseconds(40), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            slowUploader.requests.count, 1,
            "identical bytes in the same wave must coalesce to one upload")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 2, "both sources must end up proven backed up")
        let states = [state(of: first), state(of: second)]
        XCTAssertTrue(states.contains(.completed) && states.contains(.alreadyBackedUp), "got \(states)")
    }

    func testLivePhotoCompoundUploadsPairedVideoWithPrimaryReference() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(
            uploader.requests.map(\.name), ["live.heic", "live.mov"],
            "the paired video uploads after its primary")
        XCTAssertEqual(
            uploader.requests.map(\.tags),
            [
                [PhotoTag.livePhotos.rawValue],
                [PhotoTag.livePhotos.rawValue],
            ], "both resources must carry Proton's Live Photo classification")
        let pairedRequest = try XCTUnwrap(uploader.requests.last)
        XCTAssertEqual(
            pairedRequest.mainPhotoUID, testUID("live.heic"),
            "the paired video must reference its freshly-uploaded primary")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1, "a compound is ONE user-facing item")
        let record = stateStore.record(
            for: entry.source, revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
        XCTAssertEqual(record?.resourceCount, 2)
    }

    func testPhotoMetadataFlowsToPrimaryAndSecondaryUploads() async throws {
        let entry = seedEntry("metadata.heic")
        let metadata = PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":4032}"#.utf8))
        resolver.setSecondaries(["metadata.mov"], for: entry.source.identifier)
        resolver.setAdditionalMetadata([metadata], for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.additionalMetadata), [[metadata], [metadata]])
    }

    func testTrashedSecondaryNeverMarksLivePhotoBackedUp() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(live.mov)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(live.mov)",
                contentHash: expectedContentHash(path: "/backup/live.heic#live.mov"),
                linkState: .trashed,
                linkID: "trashed-paired"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
        XCTAssertEqual(state(of: entry), .skippedRemoteDeletion)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertNil(
            stateStore.record(
                for: entry.source,
                revision: UploadBackupRevision(date: resolver.defaultModified)
            ))
    }

    func testDraftSecondaryParksLivePhotoInsteadOfClaimingSuccess() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        checker.remoteItemsByNameHash["nh(live.mov)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(live.mov)",
                contentHash: nil,
                linkState: .draft,
                linkID: "draft-paired"
            )
        ]

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic"])
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(progress.blocked, 1)
    }

    func testDraftSecondaryRespectsPrimaryDeletedAfterSuccessfulUpload() async throws {
        let entry = seedEntry("edited.jpg")
        resolver.setSecondaries(["Adjustments.plist"], for: entry.source.identifier)
        let pipeline = makePipeline()
        let primaryDescriptor = UploadResourceDescriptor(
            source: entry.source,
            fileURL: URL(fileURLWithPath: entry.source.identifier),
            filename: entry.originalFilename,
            fileSize: entry.byteCount ?? 1,
            modificationDate: resolver.defaultModified
        )
        let uploaded = try await pipeline.resolve(primaryDescriptor)
        try await pipeline.recordUploaded(
            primaryDescriptor,
            identity: uploaded.identity,
            remoteVolumeID: "vol",
            remoteLinkID: "uploaded-primary"
        )
        checker.remoteItemsByNameHash[uploaded.identity.nameHash] = [
            RemotePhotoDuplicate(
                nameHash: uploaded.identity.nameHash,
                contentHash: uploaded.identity.contentHash,
                linkState: .trashed,
                linkID: "uploaded-primary"
            )
        ]
        checker.remoteItemsByNameHash["nh(Adjustments.plist)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(Adjustments.plist)",
                contentHash: nil,
                linkState: .draft,
                linkID: "unfinished-adjustment"
            )
        ]

        let progress = await makeRunner(identityResolver: pipeline).runUntilDrained()

        XCTAssertEqual(state(of: entry), .skippedRemoteDeletion)
        XCTAssertEqual(progress.skippedRemoteDeletions, 1)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertTrue(uploader.requests.isEmpty, "a deliberately trashed primary must never be recreated")
        XCTAssertNil(stateStore.record(for: entry.source, revision: entry.revision))
    }

    func testPairedVideoFailureRetriesWithoutReuploadingPrimary() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let flaky = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            transientFailures: ["live.mov": 1]
        )

        let runner = makeRunner(uploader: flaky)
        let progress = await runner.runUntilDrained()

        // The retry pass resolves the primary via the manifest, so the compound settles as
        // alreadyBackedUp - either success state is honest; what matters is the byte counts.
        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(
            flaky.requests.filter { $0.name == "live.heic" }.count, 1,
            "the primary must never re-upload when only its paired video failed")
        XCTAssertEqual(
            flaky.requests.filter { $0.name == "live.mov" }.count, 2,
            "the paired video retries after its transient failure")
        // The retried paired video references the primary via its manifest link (no volume known
        // from a skip row - the transport resolves the photos volume for it).
        let retriedPaired = try XCTUnwrap(flaky.requests.last)
        XCTAssertEqual(retriedPaired.mainPhotoUID?.nodeID, testUID("live.heic").nodeID)
        XCTAssertEqual(progress.backedUp, 1)
    }

    func testSecondaryNetworkTimeoutNeverParksCompoundOrReuploadsPrimary() async throws {
        let entry = seedEntry("network-live.heic")
        resolver.setSecondaries(["network-live.mov"], for: entry.source.identifier)
        let flaky = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            networkFailures: ["network-live.mov": 6]
        )

        let progress = await makeRunner(uploader: flaky).runUntilDrained()

        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(progress.failed, 0, "a secondary timeout is environmental, never a permanent item failure")
        XCTAssertEqual(flaky.requests.filter { $0.name == "network-live.heic" }.count, 1)
        XCTAssertEqual(flaky.requests.filter { $0.name == "network-live.mov" }.count, 7)
        XCTAssertEqual(
            queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 0,
            "transient network retries must not burn the compound retry budget")
        XCTAssertEqual(
            clock.sleeps.filter { $0 >= 1 }, [1, 2, 4, 8, 16, 32],
            "network retries must not hot-loop at the first-delay interval")
    }

    func testLargeTransferPublishesEphemeralByteLivenessWithoutChangingDurableCount() async throws {
        let entry = seedEntry("large.mov")
        let recorder = BackupProgressRecorder()
        let runner = makeRunner(uploader: MockUploader(deliverProgress: true))
        await runner.setOnProgress { recorder.append($0) }

        let final = await runner.runUntilDrained()
        let active = recorder.snapshots.compactMap(\.activeTransfer)

        XCTAssertTrue(active.contains { ($0.fraction ?? 0) > 0 && $0.completedBytes > 0 })
        XCTAssertTrue(active.allSatisfy { $0.completedItemEquivalents < 1 })
        XCTAssertEqual(final.backedUp, 1)
        XCTAssertNil(final.activeTransfer, "ephemeral byte state must disappear when the item settles")
        XCTAssertEqual(state(of: entry), .completed)
    }

    func testPreparationAndUploadProgressHandoffIsMonotonicAndNeverDoubleCountsTerminalItem() async throws {
        let entry = seedEntry("prepared.mov")
        resolver.setDeferredMaterialization(for: entry.source.identifier)
        resolver.setPreparationProgress(for: entry.source.identifier)
        let recorder = BackupProgressRecorder()
        let runner = makeRunner(uploader: MockUploader(deliverProgress: true))
        await runner.setOnProgress { recorder.append($0) }

        let final = await runner.runUntilDrained()
        // Let already-enqueued, generation-guarded progress callbacks reach the actor. None may
        // resurrect execution state after the item has settled.
        resolver.emitCapturedPreparationProgress(
            for: entry.source.identifier,
            .init(phase: .materializing, fraction: 1)
        )
        for _ in 0..<5 { await Task.yield() }
        let afterLateCallbacks = await runner.currentProgress()
        let snapshots = recorder.snapshots.filter { $0.total > 0 }
        let execution = snapshots.map { Double($0.settled) + $0.activeExecutionItemEquivalents }

        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer == nil && $0.activeExecutionItemEquivalents > 0
            }, "identity work must advance background liveness before upload bytes exist")
        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer == nil && $0.activeExecutionItemEquivalents > 0.45
            }, "deferred PhotoKit materialization must remain visible before SDK upload starts")
        XCTAssertTrue(
            snapshots.contains {
                $0.activeTransfer != nil && $0.activeExecutionItemEquivalents > 0.70
            }, "upload progress must continue forward from the preparation floor")
        XCTAssertTrue(
            zip(execution, execution.dropFirst()).allSatisfy { $0 <= $1 },
            "stage and terminal handoffs must never move execution backwards")
        XCTAssertTrue(
            execution.allSatisfy { $0 <= 1 },
            "an active fraction and the same terminal item must never be counted together")
        XCTAssertEqual(final.backedUp, 1)
        XCTAssertEqual(final.activeExecutionItemEquivalents, 0)
        XCTAssertEqual(afterLateCallbacks.activeExecutionItemEquivalents, 0)
    }

    func testCompositeResolverRoutesAndRejectsUnknownKinds() async throws {
        let composite = CompositeBackupResourceResolver([.fileURL: resolver])
        let fileEntry = seedEntry("routed.jpg")
        let resolved = try await composite.resolve(fileEntry)
        XCTAssertEqual(resolved?.descriptor.filename, "routed.jpg")

        let photoEntry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            revision: UploadBackupRevision(rawValue: 1),
            originalFilename: "IMG.HEIC",
            updatedAt: clock.now
        )
        do {
            _ = try await composite.resolve(photoEntry)
            XCTFail("unregistered source kinds must fail loudly, not guess")
        } catch {}
    }

    func testUploadConcurrencyRespectsThrottleLimit() async throws {
        for index in 0..<8 { _ = seedEntry("file-\(index).jpg") }
        let slowUploader = MockUploader(workDuration: .milliseconds(30), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(progress.uploaded, 8)
        XCTAssertLessThanOrEqual(slowUploader.peakConcurrent, 2)
    }

    func testFileChangedAfterScanUploadsCurrentContentAndClosesBothRows() async throws {
        let entry = seedEntry("edited.jpg")
        let newModified = resolver.defaultModified.addingTimeInterval(500)
        resolver.setModified(newModified, for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed, "the scanned row must not linger as runnable")
        let driftedRow = queueStore.entry(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(driftedRow?.state, .completed, "the resolved revision must get its own truthful row")
        let record = stateStore.record(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(record?.isComplete, true, "backed-up proof must be recorded for the revision that was uploaded")
        XCTAssertEqual(uploader.requests.count, 1)
    }
}
