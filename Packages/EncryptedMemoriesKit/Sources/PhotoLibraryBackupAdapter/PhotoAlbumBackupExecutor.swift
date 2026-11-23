import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

/// `AlbumSyncBackupExecuting` over the standard backup pipeline, restricted to an explicit asset
/// list. Uses the same identity resolver (dedupe manifest + duplicate service) as full photo
/// backup and manual uploads - one duplicate authority, so album sync can never re-upload bytes
/// that any other path already settled.
///
/// The queue/state stores are album-sync-private, per-run scratch so counts stay scoped to the
/// current album. A queue receipt is nevertheless durable until its identity-manifest settlement
/// succeeds; the next serialized run replays every such receipt before resetting ordinary rows.
public final class PhotoAlbumBackupExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {
    static let queueDatabaseFileName = "album-sync-backup-queue-v1.sqlite"
    static let stateDatabaseFileName = "album-sync-backup-state-v1.sqlite"

    private let accountDataDirectory: URL
    private let databasePolicy: LibraryDatabasePolicy
    private let identityResolver: any UploadIdentityResolving
    private let uploader: any PhotoUploading
    private let tagAdder: (any PhotoTagAdding)?
    private let injectedResourceResolver: (any BackupResourceResolving)?
    private let injectedProofCatalog: (any UploadBackupAssetCatalog)?
    private let stopFenceAcquired: (@Sendable () async -> Void)?
    private let stopFenceBarrier: (@Sendable () async -> Void)?
    private let runtimeSignals: BackupRuntimeSignalSource
    private let clock: any BackupSchedulerClock
    private let now: @Sendable () -> Date
    private let appBuild: String?
    private let refusalStore: AlbumSyncRefusalStore
    private let log: BackgroundWorkLog

    private let lock = NSLock()
    private struct ActiveOperation {
        let id: UUID
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var activeOperation: ActiveOperation?
    private var activeRunner: BackupSyncRunner?
    private var stopOwnerCount = 0

    public init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)? = nil
    ) {
        self.accountDataDirectory = accountDataDirectory
        self.databasePolicy = databasePolicy
        self.identityResolver = identityResolver
        self.uploader = uploader
        self.tagAdder = tagAdder
        injectedResourceResolver = nil
        injectedProofCatalog = nil
        stopFenceAcquired = nil
        stopFenceBarrier = nil
        runtimeSignals = .apple
        clock = BackupContinuousClock()
        now = { Date() }
        appBuild = AppBuildInfo().build
        refusalStore = AlbumSyncRefusalStore(accountDataDirectory: accountDataDirectory)
        log = .system
    }

    init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)? = nil,
        resourceResolver: any BackupResourceResolving,
        proofCatalog: (any UploadBackupAssetCatalog)? = nil,
        stopFenceAcquired: (@Sendable () async -> Void)? = nil,
        stopFenceBarrier: (@Sendable () async -> Void)? = nil,
        runtimeSignals: BackupRuntimeSignalSource = .apple,
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        now: @Sendable @escaping () -> Date = { Date() },
        appBuild: String? = nil,
        refusalFileSystem: any DurableFileSystem = LocalDurableFileSystem(),
        log: BackgroundWorkLog = .system
    ) {
        self.accountDataDirectory = accountDataDirectory
        self.databasePolicy = databasePolicy
        self.identityResolver = identityResolver
        self.uploader = uploader
        self.tagAdder = tagAdder
        injectedResourceResolver = resourceResolver
        injectedProofCatalog = proofCatalog
        self.stopFenceAcquired = stopFenceAcquired
        self.stopFenceBarrier = stopFenceBarrier
        self.runtimeSignals = runtimeSignals
        self.clock = clock
        self.now = now
        self.appBuild = appBuild
        refusalStore = AlbumSyncRefusalStore(accountDataDirectory: accountDataDirectory, fileSystem: refusalFileSystem)
        self.log = log
    }

    public func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        try await withOperation { [self] in
            try await performEnsureBackedUp(localIdentifiers: localIdentifiers, onProgress: onProgress)
        }
    }

    private func withOperation<Value: Sendable>(
        _ operation: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let operationID = UUID()
        let startGate = PhotoAlbumBackupExecutorStartGate()
        var operationTask: Task<Value, any Error>?
        let admitted = lock.withLock {
            guard activeOperation == nil, stopOwnerCount == 0 else { return false }
            let task = Task { [self] in
                await startGate.wait()
                defer { finishOperation(id: operationID) }
                try Task.checkCancellation()
                return try await operation()
            }
            operationTask = task
            activeOperation = ActiveOperation(
                id: operationID, cancel: { task.cancel() }, wait: { _ = await task.result })
            return true
        }
        guard admitted, let operationTask else {
            throw AlbumSyncError.alreadyRunning
        }
        return try await withTaskCancellationHandler {
            await startGate.open()
            return try await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
    }

    private func performEnsureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        let queueURL = accountDataDirectory.appendingPathComponent(Self.queueDatabaseFileName)
        let stateURL = accountDataDirectory.appendingPathComponent(Self.stateDatabaseFileName)
        let tempStore = BackupTempFileStore(
            directory: accountDataDirectory.appendingPathComponent("album-sync-temp", isDirectory: true)
        )
        let resourceResolver = injectedResourceResolver ?? PhotoLibraryResourceResolver(tempStore: tempStore)

        guard
            let recoveryQueue = UploadBackupSyncQueueManifestStore(
                url: queueURL,
                policy: databasePolicy
            )
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        do {
            try await UploadRemoteCommitRecovery(
                queue: recoveryQueue,
                resolver: resourceResolver,
                identityResolver: identityResolver
            ).settleAll()
            try Task.checkCancellation()
        } catch {
            recoveryQueue.close()
            throw error
        }
        recoveryQueue.close()

        // AlbumSyncRunner serializes calls. Reset is allowed only after the complete strict receipt
        // scan above succeeds while this registered operation still owns the stores.
        try Task.checkCancellation()
        try resetScratchDatabaseFiles(urls: [queueURL, stateURL])
        guard !localIdentifiers.isEmpty else { return AlbumSyncBackupReport() }
        let refusals = refusalStore.read()
        guard
            let queueStore = UploadBackupSyncQueueManifestStore(
                url: queueURL,
                policy: databasePolicy
            ),
            let stateStore = UploadBackupStateManifestStore(
                url: stateURL,
                policy: databasePolicy
            )
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        defer {
            queueStore.close()
            stateStore.close()
        }

        let preflight = UploadBackupPreflightIndex(store: stateStore)
        let engine = UploadBackupSyncEngine(
            preflight: preflight,
            queue: queueStore,
            remoteProofResolver: identityResolver
        )
        let runner = BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: resourceResolver,
            identityResolver: identityResolver,
            uploader: uploader,
            tagAdder: tagAdder,
            throttleInputs: runtimeSignals.current,
            runtimeChanges: runtimeSignals.updates,
            clock: clock,
            now: now
        )
        lock.withLock { activeRunner = runner }
        defer { lock.withLock { activeRunner = nil } }

        await runner.setOnProgress { snapshot in onProgress(snapshot) }
        let catalog = injectedProofCatalog ?? PhotoLibraryBackupCatalog(localIdentifiers: localIdentifiers)
        _ = try await engine.scan(catalog)
        let carried = carry(refusals, into: queueStore)
        _ = await runner.runUntilDrained(workIntent: .userInitiated)
        writeBack(refusals, carry: carried, from: queueStore, localIdentifiers: localIdentifiers)
        try await runner.checkCancellation()
        try Task.checkCancellation()
        guard await runner.isQueueOperational(), queueStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        tempStore.sweep()

        return try AlbumSyncBackupReport.read(from: queueStore, localIdentifiers: localIdentifiers)
    }

    public func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        try await withOperation { [self] in
            try await performRemoteProofLinks(for: localIdentifiers)
        }
    }

    private func performRemoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        guard
            let queue = UploadBackupSyncQueueManifestStore(
                url: accountDataDirectory.appendingPathComponent(Self.queueDatabaseFileName),
                policy: databasePolicy)
        else { throw AlbumSyncError.mappingStoreUnavailable }
        defer { queue.close() }
        return try await AlbumSyncRemoteProofLookup.remoteLinks(
            for: localIdentifiers,
            catalog: injectedProofCatalog ?? PhotoLibraryBackupCatalog(localIdentifiers: localIdentifiers),
            queue: queue, resolver: identityResolver)
    }

    public func stop() async {
        let (operation, runner) = lock.withLock {
            stopOwnerCount += 1
            return (activeOperation, activeRunner)
        }
        defer {
            lock.withLock {
                precondition(stopOwnerCount > 0)
                stopOwnerCount -= 1
            }
        }
        await stopFenceAcquired?()
        operation?.cancel()
        await runner?.stop()
        await operation?.wait()
        await stopFenceBarrier?()
    }

    private func finishOperation(id: UUID) {
        lock.withLock {
            guard activeOperation?.id == id else { return }
            activeRunner = nil
            activeOperation = nil
        }
    }

    /// One row of the album queue.
    struct RowKey: Hashable {
        let source: UploadSourceIdentity
        let revision: UploadBackupRevision
    }

    /// What the carry did: the rows that it reached, and of those the rows that it made final. `isComplete` is false
    /// when a row read that throws or answers unknown, or a failed write, ended it early; the executor logs why.
    struct Carry: Equatable {
        var reached: Set<RowKey> = []
        var final: Set<RowKey> = []
        var isComplete = true
    }

    /// Writes the stored rounds onto the newly scanned rows of the same revision that still wait for their upload. A
    /// photo that Proton refused until the backup stopped becomes final again, so the runner does not upload it; under
    /// another build it gets one more round and keeps its rounds, so the next refusal stops it again. A running refusal
    /// keeps its rounds, so the next refusal continues them. An unknown row or a failed write ends the carry; the
    /// write-back then keeps the entries that the carry did not reach.
    func carry(_ refusals: AlbumSyncRefusalStore.Lookup, into queue: any UploadBackupSyncQueueStore) -> Carry {
        guard case .found(let entries) = refusals else { return Carry() }
        var carry = Carry()
        for entry in entries {
            let key = RowKey(source: entry.source, revision: entry.revision)
            let lookup: StoreLookup<UploadBackupSyncQueueEntry>
            do {
                lookup = try queue.decisionEntry(for: entry.source, revision: entry.revision)
            } catch {
                log.notice(.photoBackup, "albumSync.refusalsNotCarried", [(.init("reason"), .word("readError"))])
                carry.isComplete = false
                return carry
            }
            let row: UploadBackupSyncQueueEntry
            switch lookup {
            case .found(let found): row = found
            // Another album's photo, or a revision that the photo no longer has.
            case .absent:
                carry.reached.insert(key)
                continue
            case .unknown:
                log.notice(.photoBackup, "albumSync.refusalsNotCarried", [(.init("reason"), .word("unknownRow"))])
                carry.isComplete = false
                return carry
            }
            // A revision that the scan proved backed up keeps its state.
            guard row.state == .discovered || row.state == .queuedForUpload else {
                carry.reached.insert(key)
                continue
            }
            let stopped = BackupIssueRecord.decode(entry.lastError)?.serviceRejection?.stopsRetrying == true
            let reopens = appBuild != nil && entry.roundBuild != appBuild
            let stops = stopped && !reopens
            guard
                queue.updateState(
                    source: row.source, revision: row.revision, state: stops ? .failedPermanent : row.state,
                    attempts: nil, lastError: entry.lastError, updatedAt: row.updatedAt)
            else {
                log.notice(.photoBackup, "albumSync.refusalsNotCarried", [(.init("reason"), .word("failedWrite"))])
                carry.isComplete = false
                return carry
            }
            carry.reached.insert(key)
            if stops { carry.final.insert(key) }
        }
        return carry
    }

    /// Stores the rounds of this run's photos after the run; entries of other photos stay as they are.
    /// - A photo that Proton refused in this run gets its new record and this build as its round build.
    /// - A photo that ended backed up, whose scan found another revision, or that parked for another cause loses its
    ///   entry: the main backup also starts the rounds again after another failure.
    /// - A photo that the run did not attempt, or did not scan, keeps its entry. So does a photo that the carry did not
    ///   reach: its run started without its rounds, so its result in this run never replaces them.
    /// A file that could not be read is left alone. A file that does not decode, has a later format or is too large is
    /// replaced by this run's entries only, and the replacement is logged. A failed read of the queue writes nothing; a
    /// queue with a lasting failure or an open transaction refuses these complete reads, so it writes nothing either.
    /// After a temporary failure the reads can still succeed and see the committed rows: a row that did not park keeps
    /// its entry, so that is safe. A failed read and a failed write lose only the rounds of this run and are logged; the
    /// earlier file stays. A process that ends before the write-back can give a photo a second round under the same
    /// build.
    /// Returns whether the file now holds this run's result.
    @discardableResult
    func writeBack(
        _ refusals: AlbumSyncRefusalStore.Lookup, carry: Carry,
        from queue: any UploadBackupSyncQueueStore & UploadBackupSyncQueueObserving, localIdentifiers: [String]
    ) -> Bool {
        let earlier: [AlbumSyncRefusalStore.Entry]
        switch refusals {
        case .found(let entries): earlier = entries
        case .absent, .unknown(replaceable: true): earlier = []
        case .unknown(replaceable: false):
            log.notice(.photoBackup, "albumSync.refusalsNotSaved", [(.init("reason"), .word("unreadableFile"))])
            return false
        }
        let photos = Set(localIdentifiers)
        var refused: [RowKey: String] = [:]
        var parkedForAnotherCause: Set<RowKey> = []
        let rows: [UploadBackupQueueRowState]
        do {
            try queue.decisionForEachProblemEntry { row in
                guard row.state == .failed || row.state == .failedPermanent else { return true }
                let key = RowKey(source: row.source, revision: row.revision)
                if let record = row.lastError, BackupIssueRecord.decode(record)?.serviceRejection != nil {
                    if !carry.final.contains(key) { refused[key] = record }
                } else {
                    parkedForAnotherCause.insert(key)
                }
                return true
            }
            rows = try queue.decisionRows(
                kind: .photoLibraryAsset,
                identifiers: Set(earlier.filter { photos.contains($0.source.identifier) }.map(\.source.identifier)))
        } catch {
            log.notice(.photoBackup, "albumSync.refusalsNotSaved", [(.init("reason"), .word("queueRead"))])
            return false
        }
        var entries: [AlbumSyncRefusalStore.Entry] = []
        for entry in earlier {
            guard photos.contains(entry.source.identifier) else {
                entries.append(entry)
                continue
            }
            let key = RowKey(source: entry.source, revision: entry.revision)
            let sameSource = rows.filter { $0.source == entry.source }
            guard let row = sameSource.first(where: { $0.revision == entry.revision }) else {
                // Another revision starts fresh; a photo that the run did not scan keeps its rounds.
                if sameSource.isEmpty { entries.append(entry) }
                continue
            }
            if row.state == .completed || row.state == .alreadyBackedUp { continue }
            guard carry.reached.contains(key) else {
                refused.removeValue(forKey: key)
                entries.append(entry)
                continue
            }
            if let record = refused.removeValue(forKey: key) {
                entries.append(
                    .init(source: entry.source, revision: entry.revision, lastError: record, roundBuild: appBuild))
            } else if !parkedForAnotherCause.contains(key) {
                entries.append(entry)
            }
        }
        for (key, record) in refused {
            entries.append(.init(source: key.source, revision: key.revision, lastError: record, roundBuild: appBuild))
        }
        entries.sort { ($0.source.identifier, $0.revision.rawValue) < ($1.source.identifier, $1.revision.rawValue) }
        do {
            try refusalStore.replace(with: entries)
        } catch {
            log.notice(.photoBackup, "albumSync.refusalsNotSaved", [(.init("reason"), .word("write"))])
            return false
        }
        // A file that does not decode, has a later format or is too large loses the entries of other albums' photos.
        if case .unknown = refusals { log.notice(.photoBackup, "albumSync.refusalsReplaced") }
        return true
    }

    private func resetScratchDatabaseFiles(urls: [URL]) throws {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] {
                let target = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}

private actor PhotoAlbumBackupExecutorStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
