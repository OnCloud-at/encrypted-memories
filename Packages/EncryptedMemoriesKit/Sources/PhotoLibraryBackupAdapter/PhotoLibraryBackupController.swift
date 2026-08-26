import Foundation
import Observation
import PhotosCore
import UploadCore

#if canImport(Darwin)
    import Darwin
#endif

enum BackupCatalogReplayPolicy {
    enum Action: Equatable {
        case skip
        case markCompleted
        case replay
    }

    static func action(
        state: UploadBackupCatalogReplayState,
        queueCount: Int,
        catalogCount: Int
    ) -> Action {
        if state == .completed { return .skip }
        if state == .inProgress { return catalogCount > 0 ? .replay : .markCompleted }
        if queueCount > 0 || catalogCount == 0 { return .markCompleted }
        return .replay
    }
}

private actor InstantWorkCompletion {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private struct InstantWorkItem: Sendable {
    let task: Task<Void, Never>
    let completion: InstantWorkCompletion
}

private struct StartedBackupRun: Sendable {
    let runID: String
    let task: Task<Void, Never>
}

/// Coordinates shared Photo Library backup behavior across Apple platforms.
///
/// Consent contract: backup never enables itself. `enableBackup()` is the only entry point that
/// requests photo access, and it must be called from an explicit user action. Once enabled, the
/// controller may resume interrupted work on launch.
@MainActor
@Observable
public final class PhotoLibraryBackupController {
    public struct Configuration {
        /// Per-account directory holding the backup stores (sign-out purge covers it wholesale).
        public var accountDataDirectory: URL
        public var databasePolicy: LibraryDatabasePolicy
        public var defaults: UserDefaults

        public init(
            accountDataDirectory: URL,
            databasePolicy: LibraryDatabasePolicy,
            defaults: UserDefaults = .standard
        ) {
            self.accountDataDirectory = accountDataDirectory
            self.databasePolicy = databasePolicy
            self.defaults = defaults
        }
    }

    private static let enabledDefaultsKey = "photoBackup.enabled.v1"
    private static let userPausedDefaultsKey = "photoBackup.userPaused.v1"
    static let queueDatabaseFileName = "photo-backup-sync-queue-v1.sqlite"
    static let stateDatabaseFileName = "photo-backup-state-v1.sqlite"
    static let catalogDatabaseFileName = "photo-library-catalog-v1.sqlite"
    static let lockDatabaseFileName = "backup-execution-lock-v1.sqlite"

    /// Lease used when reaping abandoned locks before a start; matches the lock store default so a
    /// crashed/expired owner is recoverable while a healthy owner (heartbeat every 30s) never is.
    private static let lockLease: TimeInterval = BackupExecutionLockManifestStore.defaultLeaseInterval
    private static let heartbeatInterval: TimeInterval = 30
    private static let liveChangeDebounceNanoseconds: UInt64 = 750_000_000
    static let instantWorkRetirementTimeout: Duration = .milliseconds(250)

    public private(set) var accessState: PhotoBackupAccessState
    public private(set) var isEnabled: Bool
    /// Durable user "pause": no passes run and no auto-resume fires until the user resumes. Distinct
    /// from a policy pause (thermal/battery, transient) and from `isEnabled` (the whole feature off).
    public private(set) var isUserPaused: Bool
    public private(set) var status = BackupStatus()
    public private(set) var isSyncing = false
    public private(set) var lastMessage: String?
    /// Exact Core-derived eligibility time for the next automatic attempt. Platform schedulers may
    /// request an OS window around this date but never invent their own retry cadence.
    public private(set) var nextAutomaticAttemptAt: Date?
    /// Latest catalog scan tally for diagnostics. It is not upload progress and is not shown in the backup
    /// status row.
    public private(set) var lastCatalogProgress: PhotoLibraryCatalogProgress?
    /// Bumps only when durable queue truth records newly uploaded media bytes. UI hosts observe this
    /// to refresh their library immediately; duplicate matches do not cause needless timeline loads.
    public private(set) var uploadedLibraryMutationRevision: UInt64 = 0

    /// False when the dedupe manifest, backup stores, or execution lock could not open - backup
    /// then refuses to run rather than risking duplicate uploads or multiple drainers.
    public var isAvailable: Bool {
        runner != nil
            && lockStore != nil
            && queueStore?.isOperational() == true
            && catalogStore?.isOperational() == true
    }

    /// Identity of the currently active orchestration pass. Platform expiration handlers use this
    /// value to cancel only the run whose ownership they received, never a later replacement run.
    public var activeExecutionRunID: String? { activeRunID }

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let catalogStore: PhotoLibraryCatalogManifestStore?
    private let lockStore: BackupExecutionLockManifestStore?
    private let statusProjector: BackupStatusProjector?
    private let statusProjectionGeneration = UUID()
    private var statusProjectionRevision: UInt64 = 0
    private var lastAppliedStatusProjectionRevision: UInt64 = 0
    private let tempStore: BackupTempFileStore
    private let monitor: PhotoLibraryChangeMonitor
    private let defaults: UserDefaults
    private let retryPolicy: BackupRetryPolicy
    private var statusSetupTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    /// Targeted enqueue fired by the change observer while a pass is running. A photo added mid-backup
    /// enters the durable queue and is drained by the current pass.
    private var instantEnqueueTask: Task<Void, Never>?
    /// Every detached catalog sync spawned by `enqueueRecentChangesIntoRunningPass` for the active
    /// pass. The handles remain owned until the pass releases its lock, or until a retained retirement
    /// task joins them after the bounded expiration wait.
    private var instantWorkItems: [InstantWorkItem] = []
    private var instantWorkRetirementTask: Task<Void, Never>?
    private var instantWorkRetirementRunID: String?
    /// Blocks new passes and targeted work while a bounded expiration wait has handed writers to the
    /// retained retirement task. `isSyncing` remains true until that task releases the run lock.
    private var isRetiringInstantWork = false
    private var heartbeatTask: Task<Void, Never>?
    /// One retained runner stop per active run. The handle remains owned until the run has passed
    /// the stop barrier, so repeated expiration and shutdown requests join the same operation.
    private var runnerStopTask: Task<Void, Never>?
    private var runnerStopRunID: String?
    /// Periodically asks the off-main projector for durable queue truth while a pass runs. The task
    /// never reads SQLite itself and hands only an immutable projection back to this main-actor model.
    private var statusRefreshTask: Task<Void, Never>?
    /// One date-driven wake for the earliest eligible queue item. Replaces the old fixed 45-second
    /// poll, which repeatedly started empty runs for draft-blocked rows.
    private var autoResumeTask: Task<Void, Never>?
    private var consecutiveNoProgressRuns = 0
    private var backedUpAtRunStart = 0
    private var lastObservedUploadedCount: Int?
    private var activeRunID: String?
    private var pendingSyncAfterStop = false
    private var isShuttingDown = false
    private var isScanning = false
    /// Previously failed items receive one fresh attempt on the first pass of each app launch.
    /// Permanently invalid items are not retried on every pass.
    private var didAutoRetryFailedThisLaunch = false
    private var lastProjectedProgress = BackupSyncProgress()
    private var executionOpportunityIssue: BackupExecutionOpportunityIssue?

    #if DEBUG
        private var runnerStopOperationForTesting: (@Sendable () async -> Void)?
    #endif

    /// Platform hook: invoked with `true` when a backup pass is actively running (so the host app may
    /// keep the display awake / request background time) and `false` the moment backup goes idle,
    /// paused, or finished. The controller stays UIKit-agnostic; the iOS app injects a closure that
    /// toggles `UIApplication.shared.isIdleTimerDisabled`, macOS leaves the default no-op. Called at
    /// every `isSyncing` transition so the timer never pins the screen after backup ends.
    public var idleTimerHook: ((Bool) -> Void)?

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading
    ) {
        let directory = configuration.accountDataDirectory
        defaults = configuration.defaults
        let retryPolicy = BackupRetryPolicy()
        self.retryPolicy = retryPolicy
        accessState = PhotoLibraryAuthorization.currentState()
        isEnabled = configuration.defaults.bool(forKey: Self.enabledDefaultsKey)
        isUserPaused = configuration.defaults.bool(forKey: Self.userPausedDefaultsKey)
        tempStore = BackupTempFileStore(
            directory: directory.appendingPathComponent("photo-backup-temp", isDirectory: true))
        monitor = PhotoLibraryChangeMonitor(tokenURL: directory.appendingPathComponent("photo-backup-change-token.v1"))

        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(Self.queueDatabaseFileName),
            policy: configuration.databasePolicy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(Self.stateDatabaseFileName),
            policy: configuration.databasePolicy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore
        statusProjector = queueStore.map {
            BackupStatusProjector(queue: $0)
        }
        // Catalog + lock are independent of the upload composition: they open even before an
        // identity resolver exists, so inventory/ownership survive a partial account bring-up.
        let catalogStore = PhotoLibraryCatalogManifestStore(
            url: directory.appendingPathComponent(Self.catalogDatabaseFileName),
            policy: configuration.databasePolicy
        )
        self.catalogStore = catalogStore
        lockStore = BackupExecutionLockManifestStore(
            url: directory.appendingPathComponent(Self.lockDatabaseFileName),
            policy: configuration.databasePolicy,
            leaseInterval: Self.lockLease
        )

        if let queueStore, let stateStore, let catalogStore, let identityResolver {
            let preflight = UploadBackupPreflightIndex(store: stateStore)
            engine = UploadBackupSyncEngine(
                preflight: preflight,
                queue: queueStore,
                remoteProofResolver: identityResolver
            )
            runner = BackupSyncRunner(
                queue: queueStore,
                preflight: preflight,
                resolver: PhotoLibraryResourceResolver(
                    tempStore: tempStore,
                    cloudIdentifierProvider: { localIdentifier in
                        catalogStore.entry(for: localIdentifier)?.cloudIdentifier
                    }
                ),
                identityResolver: identityResolver,
                uploader: uploader,
                configuration: .init(retry: retryPolicy),
                throttleInputs: { AppleBackupRuntimeSignals.current() }
            )
        } else {
            engine = nil
            runner = nil
        }

        tempStore.sweep()
        if let statusProjector {
            let generation = statusProjectionGeneration
            let initialContext = projectionContext
            statusSetupTask = Task {
                await statusProjector.start(
                    generation: generation,
                    revision: 0,
                    context: initialContext
                ) { @MainActor [weak self] projection in
                    self?.applyStatusProjection(projection)
                }
                if let runner {
                    await runner.setOnProgress { snapshot in
                        statusProjector.submit(snapshot, generation: generation)
                    }
                }
            }
        }
        if isEnabled {
            startObservingChanges()
            Task { @MainActor [weak self] in
                await self?.statusSetupTask?.value
                self?.resumeEnabledBackupAfterLaunch()
            }
        }
    }

    // MARK: - Enable / disable (explicit consent only)

    /// Requests read-write photo access and, when granted (full OR limited), turns backup on and
    /// starts the first pass. Call only from an explicit user action - the UI must explain what
    /// will happen before invoking this.
    public func enableBackup() async {
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        startObservingChanges()
        // Re-enabling is an explicit user action. Give failed items a fresh start.
        queueStore?.requeueFailed(updatedAt: Date())
        refreshFromQueue()
        if isSyncing {
            pendingSyncAfterStop = true
            stopSync()
            return
        }
        await retryFailedAndSync()
    }

    public func disableBackup() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedDefaultsKey)
        pendingSyncAfterStop = false
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        monitor.stopObserving()
        stopSync()
        if !isSyncing {
            refreshFromQueue()
        }
    }

    public func refreshAccessState() {
        accessState = PhotoLibraryAuthorization.currentState()
    }

    // MARK: - Sync lifecycle

    /// Ordinary foreground pass. Explicit "Back up now" actions use `retryFailedAndSync()` so they
    /// alone may clear durable retry dates; lifecycle/change-driven calls honor persisted backoff.
    public func syncNow() {
        _ = startSync(owner: .foreground)
    }

    /// Durable user pause: stop the current pass AND suppress every automatic (re)start until the user
    /// resumes. Persisted so it survives relaunch. This is what the Pause button does; unlike a bare
    /// `stopSync()`, a change notification or the auto-resume can't quietly restart behind the user.
    public func pauseBackup() {
        guard !isUserPaused else { return }
        isUserPaused = true
        defaults.set(true, forKey: Self.userPausedDefaultsKey)
        pendingSyncAfterStop = false
        stopSync()
        if !isSyncing { refreshFromQueue() }  // reflect "Pausiert" immediately
    }

    /// Clears the durable pause and immediately resumes every retryable row.
    public func resumeBackup() async {
        guard isUserPaused else { return }
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedDefaultsKey)
        await retryFailedAndSync()
    }

    /// Manual "back up now": make failed, draft-blocked, and future-backoff work due immediately,
    /// invalidate the short-lived remote dedupe view, then run. Automatic passes keep their durable
    /// dates; only explicit user intent bypasses the wait, and all duplicate safety remains intact.
    public func retryFailedAndSync() async {
        if let runner {
            _ = await runner.makeRetryableWorkEligibleNow()
        } else {
            _ = queueStore?.makeRetryableWorkEligible(updatedAt: Date())
            _ = queueStore?.setRuntimeIssue(nil, for: .remoteIndexPreparation)
        }
        refreshFromQueue()
        if !isSyncing { _ = startSync(owner: .manual) }
    }

    /// Every item still preventing a complete backup. Proven remote deletions are intentionally absent:
    /// they are successful policy outcomes reported as aggregate information, not failed work.
    public func failedItems(limit: Int = 200) -> [BackupFailedItem] {
        guard let queueStore else { return [] }
        let states: [UploadBackupSyncQueueState] = [
            .failed, .failedPermanent, .sourceMissing, .blockedByDraft, .discovered, .queuedForUpload,
        ]
        var entries: [UploadBackupSyncQueueEntry] = []
        for state in states where entries.count < limit {
            entries += queueStore.entries(
                in: state,
                updatedBefore: .distantFuture,
                limit: limit - entries.count
            )
        }
        return entries.map { entry in
            let record = BackupIssueRecord.decode(entry.lastError)
            let issue = record?.kind ?? Self.defaultIssue(for: entry.state)
            let isPermanent = entry.state == .sourceMissing || entry.state == .failedPermanent
            return BackupFailedItem(
                id:
                    "\(entry.source.kind.rawValue)/\(entry.source.identifier)/\(entry.source.resource.rawValue)#\(entry.revision.rawValue)",
                filename: entry.originalFilename,
                reason: record?.detail ?? Self.defaultIssueDetail(for: issue),
                isPermanent: isPermanent,
                issue: issue,
                nextAttemptAt: record?.nextAttemptAt,
                isRetryable: !isPermanent && issue.isRetryable,
                source: entry.source,
                revision: entry.revision
            )
        }
    }

    /// Hides a permanent item warning without ever changing the backup-success count.
    public func dismissFailedItem(_ item: BackupFailedItem) {
        guard item.isPermanent,
            let source = item.source,
            let revision = item.revision,
            queueStore?.dismissPermanentFailure(
                source: source,
                revision: revision,
                updatedAt: Date()
            ) == true
        else { return }
        refreshFromQueue()
    }

    /// True while at least one failed item can still be retried (i.e. it is not a permanently-gone
    /// local file), so the detail sheet can offer "try again".
    public var hasRetryableFailures: Bool {
        queueStore?.containsAny(in: [.failed, .blockedByDraft, .discovered, .queuedForUpload]) == true
    }

    /// Platform adapters report whether an OS background opportunity was accepted. This changes only
    /// presentation truth; queue execution and retry semantics remain entirely shared.
    public func setExecutionOpportunityIssue(_ issue: BackupExecutionOpportunityIssue?) {
        guard executionOpportunityIssue != issue else { return }
        executionOpportunityIssue = issue
        refreshFromQueue()
    }

    /// Real work projection for OS execution windows. The app's backup row continues to use
    /// `status`; catalog discovery is included here only so a long PhotoKit scan cannot look stalled
    /// to the operating system before queue reconciliation has a denominator.
    public var backgroundExecutionProgress: BackupExecutionProgress? {
        PhotoLibraryBackupExecutionProgress.combined(
            catalog: lastCatalogProgress?.executionProgress,
            queue: status.executionProgress,
            isScanning: isScanning
        )
    }

    /// Runs one catch-up pass for an OS background window.
    /// `onRunStarted` receives the run ID for expiration-safe cancellation.
    /// Checkpointed state lets the next pass resume unfinished work.
    public func backgroundCatchUp(
        owner: BackupExecutionOwner = .background,
        onRunStarted: (@MainActor (String) -> Void)? = nil
    ) async {
        guard let run = startSync(owner: owner) else { return }
        onRunStarted?(run.runID)
        await run.task.value
    }

    /// The single entry point that starts a pass. Acquires durable execution ownership before any
    /// draining: a crashed/expired owner's stale lock is reaped here, and a live lock held by a
    /// different run makes this call stand down instead of starting a second drainer.
    private func startSync(owner: BackupExecutionOwner) -> StartedBackupRun? {
        guard !isShuttingDown, isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing,
            !isRetiringInstantWork, runnerStopTask == nil,
            let engine, let runner, let queueStore, let catalogStore
        else { return nil }
        guard queueStore.isOperational(), catalogStore.isOperational() else {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            refreshFromQueue()
            return nil
        }
        if owner != .manual,
            let retryAt = queueStore.runtimeIssue(for: .remoteIndexPreparation)?.nextAttemptAt,
            retryAt > Date()
        {
            refreshFromQueue()
            scheduleAutoResumeIfOutstanding()
            return nil
        }
        guard let lockStore else {
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return nil
        }

        let runID = UUID().uuidString
        // Recovery must precede the drain: clear any owner that stopped heartbeating (crash,
        // OS kill, BG expiration) so a dead run can never permanently block backup.
        let processContext = Self.processContext
        lockStore.recoverAbandonedProcessLocks(
            currentProcessContext: processContext,
            isProcessAlive: Self.processIsAlive
        )
        lockStore.recoverStaleLocks(olderThan: Date().addingTimeInterval(-Self.lockLease))
        switch lockStore.acquire(owner: owner, runID: runID, phase: "scanning", processContext: processContext) {
        case .acquired:
            break
        case .busy:
            // Another live run owns the queue (e.g. a foreground pass while a BG window fires).
            // Stand down: its own drain covers the work; a second drainer is never allowed.
            return nil
        case .unavailable:
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return nil
        }
        activeRunID = runID

        // Retry previously failed items once per launch.
        if !didAutoRetryFailedThisLaunch {
            didAutoRetryFailedThisLaunch = true
            queueStore.requeueFailed(updatedAt: Date())
        }

        autoResumeTask?.cancel()
        autoResumeTask = nil  // a pass is starting; the timer's job is done
        instantEnqueueTask?.cancel()
        instantEnqueueTask = nil
        isSyncing = true
        backedUpAtRunStart = lastProjectedProgress.backedUp
        updateIdleTimerIfNeeded()
        isScanning = false
        lastMessage = nil
        status = BackupStatus(
            progress: lastProjectedProgress, isScanning: false,
            executionOpportunityIssue: executionOpportunityIssue
        )
        refreshFromQueue()
        startHeartbeat(runID: runID)
        startStatusRefresh()
        let statusSetupTask = self.statusSetupTask

        // The task inherits the main actor, but all heavy phases (`scan`, `runUntilDrained`) are
        // awaits onto other actors/off-actor structs - the main thread stays free for UI.
        let task = Task { [weak self, monitor, tempStore, engine, runner, queueStore, catalogStore, statusSetupTask] in
            await statusSetupTask?.value
            self?.refreshFromQueue()
            // Scan and reconcile run concurrently. Reconcile drains existing work and newly enqueued
            // items, and it is the only runner caller. A slow scan cannot block uploads.
            self?.beginScanPhase()
            let scanDone = BackupScanSignal()
            let workIntent: LibraryWorkIntent = owner == .manual ? .userInitiated : .automatic
            async let reconcile: Void = Self.reconcileWhileScanning(
                runner: runner,
                scanDone: scanDone,
                workIntent: workIntent
            )
            do {
                try await Self.replayCatalogIfQueueNeedsRecovery(
                    catalogStore: catalogStore,
                    queueStore: queueStore,
                    engine: engine
                )
                let preparedChanges = await Self.prepareChangesOffMainActor(monitor)
                try await self?.runScanPass(
                    engine: engine,
                    runner: runner,
                    catalogStore: catalogStore,
                    changes: preparedChanges.changes
                )
                monitor.commit(preparedChanges)
            } catch is CancellationError {
                // The one-shot completion signal below releases the reconcile loop cleanly.
            } catch {
                self?.reportSyncMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishScanPhase()

            await scanDone.markDone()
            await reconcile  // drains the tail enqueued during the scan, then returns
            tempStore.sweep()  // every export is re-derivable; nothing to keep between passes
            await self?.finishSync(runID: runID)
        }
        syncTask = task
        return StartedBackupRun(runID: runID, task: task)
    }

    /// Replays durable inventory only when the queue may be incomplete.
    /// Catalog sync writes queue rows before advancing the catalog, so replay is safe and idempotent.
    private nonisolated static func replayCatalogIfQueueNeedsRecovery(
        catalogStore: PhotoLibraryCatalogManifestStore,
        queueStore: UploadBackupSyncQueueManifestStore,
        engine: UploadBackupSyncEngine
    ) async throws {
        let queueCount = queueStore.count()
        guard queueStore.isOperational(), catalogStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        let catalogCount = catalogStore.snapshot().present
        guard catalogStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        let replayState = queueStore.catalogReplayState()
        guard queueStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }
        switch BackupCatalogReplayPolicy.action(
            state: replayState,
            queueCount: queueCount,
            catalogCount: catalogCount
        ) {
        case .skip:
            return
        case .markCompleted:
            // Upgrade path for queues created before the replay marker existed. A non-empty queue
            // cannot be behind its catalog: catalog sync durably writes every queue chunk first.
            guard queueStore.setCatalogReplayState(.completed) else {
                throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
            }
            return
        case .replay:
            break
        }
        guard replayState == .inProgress || queueStore.setCatalogReplayState(.inProgress) else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }

        var cursor: String?
        while true {
            try Task.checkCancellation()
            let entries = catalogStore.presentEntries(afterLocalIdentifier: cursor, limit: 500)
            guard catalogStore.isOperational() else {
                throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
            }
            guard !entries.isEmpty else {
                guard queueStore.setCatalogReplayState(.completed) else {
                    throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
                }
                return
            }
            let candidates = entries.compactMap {
                PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: $0))
            }
            _ = try await engine.enqueueBatch(candidates)
            cursor = entries.last?.localIdentifier
        }
    }

    private nonisolated static func prepareChangesOffMainActor(
        _ monitor: PhotoLibraryChangeMonitor
    ) async -> PhotoLibraryChangeMonitor.PreparedChangeSet {
        await Task.detached(priority: .utility) {
            monitor.prepareChanges()
        }.value
    }

    /// The reconcile loop: repeatedly drains runnable queue rows to the backend until the index scan
    /// has signalled completion AND nothing runnable remains. Runs concurrently with the scan, so a
    /// slow or resuming scan never delays uploads. Static + the heavy work is on the runner actor, so
    /// it never touches the main thread and does not depend on the controller's lifetime.
    private static func reconcileWhileScanning(
        runner: BackupSyncRunner,
        scanDone: BackupScanSignal,
        workIntent: LibraryWorkIntent
    ) async {
        while !Task.isCancelled {
            let progress = await runner.runUntilDrained(mode: .eligibleOnly, workIntent: workIntent)
            guard await runner.isQueueOperational() else { return }
            // A failed remote index cannot safely dedupe anything, and a closed runtime policy has
            // no eligible transport. End this pass and let the controller's typed retry scheduler
            // choose the next attempt instead of hammering either condition four times per second.
            if progress.remoteIndexPreparationFailed || progress.isPausedByPolicy { return }
            if await scanDone.isDone() {
                // The scan may have enqueued rows between our last claim and its done-signal; one more
                // drain guarantees they upload before we return.
                await runner.runUntilDrained(mode: .eligibleOnly, workIntent: workIntent)
                return
            }
            // Yield the CPU and let the scan enqueue more before the next drain (no hot empty spin).
            // A cancelled sleep drops straight out via the loop condition; no busy loop on stop.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Runs the scan phase through the persistent catalog driver. `nonisolated` keeps SQLite and
    /// PhotoKit enumeration off the main actor.
    private nonisolated func runScanPass(
        engine: UploadBackupSyncEngine,
        runner: BackupSyncRunner,
        catalogStore: PhotoLibraryCatalogManifestStore,
        changes: PhotoLibraryChangeMonitor.ChangeSet
    ) async throws {
        let sync = PhotoLibraryCatalogSync(
            store: catalogStore,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.lastCatalogProgress = progress }
            },
            onRemoved: { identifiers in
                _ = await runner.removePhotoLibraryAssets(identifiers)
            }
        )
        let needsFullScan = changes.requiresFullRescan || !catalogStore.hasCompletedFullScan()
        guard catalogStore.isOperational() else {
            throw UploadError.backend(L10n.string("backup.error_local_state_unavailable"))
        }

        // Enqueue recently added or changed assets first on every pass, including during backfill. A photo
        // saved by another app or edited while the initial full scan runs must not wait for it.
        if !changes.requiresFullRescan {
            let targeted = Array(Set(changes.changedIdentifiers + changes.deletedIdentifiers))
            if !targeted.isEmpty {
                _ = try await sync.run(engine: engine, identifiers: targeted)
            }
        }

        if needsFullScan {
            if changes.requiresFullRescan {
                guard catalogStore.clearFullScanResumePoint() else {
                    throw UploadError.backend("Photo library scan state could not be reset")
                }
            }
            _ = try await sync.run(engine: engine, identifiers: nil)
        }
    }

    private func resumeEnabledBackupAfterLaunch() {
        refreshAccessState()
        guard isEnabled, accessState.allowsBackup, !isSyncing else { return }
        syncNow()
    }

    /// Stops only the active run identified by the caller. OS expiration handlers must use this
    /// overload so an expired attempt cannot cancel a foreground run or a later replacement run.
    public func stopSync(runID: String) {
        guard activeRunID == runID else { return }
        stopCurrentSync()
    }

    /// Explicit user actions may stop whichever run is currently active.
    public func stopSync() {
        stopCurrentSync()
    }

    private func stopCurrentSync() {
        // Cancel the scan and reconcile tasks before stopping the runner. Otherwise the next drain loop
        // can reset the runner stop flag; runner.stop() also aborts an in-flight upload.
        syncTask?.cancel()
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        instantEnqueueTask?.cancel()
        instantWorkItems.forEach { $0.task.cancel() }
        guard activeRunID != nil else { return }
        requestRunnerStop()
    }

    /// Creates the stop operation synchronously on the main actor after orchestration cancellation.
    /// A run keeps this handle until `completeSyncRun` crosses the settlement barrier.
    private func requestRunnerStop() {
        guard let runID = activeRunID, runnerStopTask == nil else { return }
        #if DEBUG
            if let operation = runnerStopOperationForTesting {
                let task = Task { await operation() }
                runnerStopRunID = runID
                runnerStopTask = task
                return
            }
        #endif
        guard let runner else { return }
        let task = Task { await runner.stop() }
        runnerStopRunID = runID
        runnerStopTask = task
    }

    #if DEBUG
        @discardableResult
        internal func installSyncRunForTesting(
            runID: String,
            task: Task<Void, Never>
        ) -> Bool {
            guard syncTask == nil, activeRunID == nil, runnerStopTask == nil else { return false }
            activeRunID = runID
            syncTask = task
            isSyncing = true
            return true
        }

        internal func installRunnerStopOperationForTesting(
            _ operation: @escaping @Sendable () async -> Void
        ) {
            runnerStopOperationForTesting = operation
        }

        internal func finishSyncForTesting(runID: String) async {
            await finishSync(runID: runID)
        }

        internal var isRunnerStopPendingForTesting: Bool {
            runnerStopTask != nil
        }

        internal var runnerStopRunIDForTesting: String? {
            runnerStopRunID
        }

        /// Installs a synthetic targeted-work task for deterministic lifecycle tests.
        /// The task models a PhotoKit/SQLite writer that can ignore cancellation while it is blocked.
        @discardableResult
        internal func installInstantWorkTaskForTesting(_ task: Task<Void, Never>) -> Bool {
            guard !isShuttingDown, !isRetiringInstantWork else { return false }
            let completion = InstantWorkCompletion()
            let trackedTask = Task.detached(priority: .utility) {
                await task.value
                await completion.markCompleted()
            }
            instantWorkItems.append(InstantWorkItem(task: trackedTask, completion: completion))
            return true
        }

        /// Starts a synthetic targeted writer only when the controller accepts new targeted work.
        /// This seam lets lifecycle tests prove that retirement rejects a new writer before it starts.
        @discardableResult
        internal func startInstantWorkForTesting(
            _ operation: @escaping @Sendable () async -> Void
        ) -> Bool {
            guard !isShuttingDown, !isRetiringInstantWork else { return false }
            let completion = InstantWorkCompletion()
            let task = Task.detached(priority: .utility) {
                await operation()
                await completion.markCompleted()
            }
            instantWorkItems.append(InstantWorkItem(task: task, completion: completion))
            return true
        }

        internal var isRetiringInstantWorkForTesting: Bool { isRetiringInstantWork }

        internal func retireInstantWorkForTesting() async {
            guard !isRetiringInstantWork else { return }
            isRetiringInstantWork = true
            await retireInstantWorkTask()
        }

        internal func waitForInstantWorkRetirementForTesting() async {
            await instantWorkRetirementTask?.value
        }
    #endif

    /// Stops every account-scoped worker, awaits its final callback, then closes all SQLite owners.
    /// Sign-out must await this before removing `accountDataDirectory`.
    public func shutdown() async {
        isShuttingDown = true
        pendingSyncAfterStop = false
        monitor.stopObserving()
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        instantEnqueueTask?.cancel()
        let activeSync = syncTask
        let activeStatusSetup = statusSetupTask
        syncTask?.cancel()
        statusSetupTask = nil
        let activeEnqueue = instantEnqueueTask
        instantEnqueueTask = nil
        activeEnqueue?.cancel()
        requestRunnerStop()
        let activeStop = runnerStopTask
        await activeStop?.value
        await activeSync?.value
        await activeStatusSetup?.value
        await activeEnqueue?.value
        await joinInstantWorkTasksForShutdown()
        await runner?.setOnProgress(nil)
        await statusProjector?.stop()
        idleTimerHook?(false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        tempStore.sweep()
        queueStore?.close()
        stateStore?.close()
        catalogStore?.close()
        lockStore?.close()
    }

    // MARK: - Execution-lock heartbeat

    private func startHeartbeat(runID: String) {
        heartbeatTask?.cancel()
        guard let lockStore else {
            heartbeatTask = nil
            return
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Stop the pass when another owner acquires the execution lock.
                if !lockStore.heartbeat(runID: runID, phase: nil) { return }
                _ = self
            }
        }
    }

    /// Keeps the visible counter honest from the durable queue while a pass runs. SQLite work stays
    /// on `BackupStatusProjector`; this task only supplies current lifecycle context once per second.
    private func startStatusRefresh() {
        statusRefreshTask?.cancel()
        guard let statusProjector else {
            statusRefreshTask = nil
            return
        }
        let generation = statusProjectionGeneration
        statusRefreshTask = Task { @MainActor [weak self, statusProjector] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isSyncing, !Task.isCancelled else { return }
                let request = self.nextStatusProjectionRequest()
                _ = await statusProjector.projectNow(
                    context: request.context,
                    generation: generation,
                    revision: request.revision
                )
            }
        }
    }

    // MARK: - Change-driven incremental sync (foreground sessions)

    private func startObservingChanges() {
        monitor.startObserving { [weak self] in
            Task { @MainActor in self?.scheduleChangeDrivenSync() }
        }
    }

    private func scheduleChangeDrivenSync() {
        guard !isShuttingDown, isEnabled else { return }
        if isSyncing {
            // Keep a follow-up pass armed until the targeted change is durably consumed. The active
            // pass can finish during the debounce window; without this guard that one notification
            // would be cancelled at teardown and wait until a later launch.
            pendingSyncAfterStop = true
            // A pass is already running: enqueue newly changed assets into the durable queue so the
            // concurrent reconcile loop picks them up in this pass. Debounce bursts of edits into one
            // targeted enqueue. Transaction-safe: enqueue is an idempotent upsert keyed by source +
            // revision; the dedup preflight still runs per-item in the runner, so nothing bypasses it.
            // Do not commit the change token here; the running pass owns that commit.
            guard !isRetiringInstantWork else { return }
            instantEnqueueTask?.cancel()
            instantEnqueueTask = Task { [weak self, monitor, engine, catalogStore] in
                try? await Task.sleep(nanoseconds: Self.liveChangeDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown, self.isSyncing else { return }
                    self.enqueueRecentChangesIntoRunningPass(
                        monitor: monitor, engine: engine, catalogStore: catalogStore)
                }
            }
            return
        }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveChangeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isShuttingDown, self.isEnabled, !self.isSyncing else { return }
                self.syncNow()
            }
        }
    }

    /// Targeted enqueue of changes that arrived while a pass is running. Reads the change token without
    /// committing (the running pass owns the commit), runs a targeted catalog sync for exactly those
    /// identifiers so each becomes a durable `discovered` queue row with its real revision, and lets
    /// the concurrent reconcile loop drain it this pass. Re-enqueueing an asset the pass already
    /// handled is an idempotent upsert no-op (the queue's ON CONFLICT guard keeps state forward-only:
    /// a row already in checking/uploading/etc. is never regressed to discovered); the runner's per-
    /// item dedup preflight is never bypassed.
    private func enqueueRecentChangesIntoRunningPass(
        monitor: PhotoLibraryChangeMonitor,
        engine: UploadBackupSyncEngine?,
        catalogStore: PhotoLibraryCatalogManifestStore?
    ) {
        guard !isShuttingDown, !isRetiringInstantWork,
            let engine, let runner, let catalogStore
        else { return }
        let prepared = monitor.prepareChanges()
        // requiresFullRescan means the token is untrusted (expired); the running pass's own full scan
        // covers it; do not spin a targeted enqueue from an unreliable id list.
        guard !prepared.changes.requiresFullRescan else { return }
        let targeted = Array(Set(prepared.changes.changedIdentifiers + prepared.changes.deletedIdentifiers))
        guard !targeted.isEmpty else { return }
        // Off the main actor: the catalog sync enumerates PhotoKit and writes SQLite. Tracked so the
        // exit paths can cancel it if the pass ends before this completes.
        let completion = InstantWorkCompletion()
        let task = Task.detached(priority: .utility) {
            let sync = PhotoLibraryCatalogSync(
                store: catalogStore,
                onRemoved: { identifiers in
                    _ = await runner.removePhotoLibraryAssets(identifiers)
                }
            )
            _ = try? await sync.run(engine: engine, identifiers: targeted)
            await completion.markCompleted()
            // The durable rows are now runnable; the concurrent reconcile loop claims them on its next
            // drain cycle (within its ~250 ms inter-drain sleep); no explicit wake needed.
        }
        instantWorkItems.append(InstantWorkItem(task: task, completion: completion))
    }

    // MARK: - Status projection

    private var projectionContext: BackupStatusProjectionContext {
        BackupStatusProjectionContext(
            isScanning: isScanning,
            isRunning: isSyncing,
            isUserPaused: isUserPaused,
            executionOpportunityIssue: executionOpportunityIssue
        )
    }

    private func applyStatusProjection(_ projection: BackupStatusProjection) {
        guard projection.generation == statusProjectionGeneration,
            projection.revision >= lastAppliedStatusProjectionRevision
        else { return }
        lastAppliedStatusProjectionRevision = projection.revision
        lastProjectedProgress = projection.progress
        nextAutomaticAttemptAt = projection.progress.outstanding.nextAttemptAt
        guard projection.status != status else { return }
        status = projection.status
        noteUploadedLibraryMutation(projection.progress.uploaded)
    }

    private func beginScanPhase() {
        lastCatalogProgress = nil
        isScanning = true
        refreshFromQueue()
    }

    private func finishScanPhase() {
        isScanning = false
        refreshFromQueue()
    }

    /// Cancels every targeted writer and waits briefly before deciding whether retirement is needed.
    /// A PhotoKit/SQLite write may ignore cancellation, so the bounded wait preserves forward progress
    /// while an unfinished writer keeps the run lock and heartbeat through a retained join task.
    private func retireInstantWorkTask() async {
        let workItems = instantWorkItems
        instantWorkItems.removeAll(keepingCapacity: false)
        guard !workItems.isEmpty else {
            isRetiringInstantWork = false
            instantWorkRetirementRunID = nil
            return
        }

        workItems.forEach { $0.task.cancel() }
        let deadline = ContinuousClock.now + PhotoLibraryBackupController.instantWorkRetirementTimeout
        while ContinuousClock.now < deadline {
            var allCompleted = true
            for item in workItems {
                if !(await item.completion.isCompleted()) {
                    allCompleted = false
                    break
                }
            }
            if allCompleted { break }
            // The enclosing pass is commonly cancelled during expiration. Sleep in a detached task
            // so cancellation does not turn this bounded wait into a busy loop on the main actor.
            await Task.detached(priority: .utility) { () -> Void in
                try? await Task.sleep(for: .milliseconds(5))
            }.value
        }

        var remaining: [InstantWorkItem] = []
        for item in workItems {
            if await item.completion.isCompleted() {
                await item.task.value
            } else {
                remaining.append(item)
            }
        }
        guard !remaining.isEmpty else {
            isRetiringInstantWork = false
            instantWorkRetirementRunID = nil
            return
        }

        // Keep the exact run owner and heartbeat until every writer returns. The task itself is
        // retained by the controller so shutdown can join it before closing account SQLite stores.
        instantWorkRetirementTask = Task { @MainActor [weak self] in
            for item in remaining {
                await item.task.value
            }
            guard let self else { return }
            await self.finishInstantWorkRetirement()
        }
    }

    /// Joins active retirement and every targeted catalog writer before explicit account teardown
    /// closes stores. Unlike expiration retirement, this path has no deadline.
    private func joinInstantWorkTasksForShutdown() async {
        let retirement = instantWorkRetirementTask
        await retirement?.value

        let activeItems = instantWorkItems
        instantWorkItems.removeAll(keepingCapacity: false)
        for item in activeItems {
            item.task.cancel()
            await item.task.value
        }
        isRetiringInstantWork = false
        instantWorkRetirementRunID = nil
    }

    private func finishSync(runID: String) async {
        guard activeRunID == runID else { return }
        // The pass is still the lock owner while its final enqueue and every targeted writer retire.
        // This also rejects new targeted work during the re-entrant waits below.
        isRetiringInstantWork = true
        instantWorkRetirementRunID = runID
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        instantEnqueueTask?.cancel()
        let activeEnqueue = instantEnqueueTask
        instantEnqueueTask = nil
        await activeEnqueue?.value
        guard activeRunID == runID else { return }
        await retireInstantWorkTask()
        guard activeRunID == runID, !isRetiringInstantWork else { return }
        await completeSyncRun(runID: runID)
    }

    private func finishInstantWorkRetirement() async {
        let runID = instantWorkRetirementRunID
        instantWorkRetirementTask = nil
        instantWorkRetirementRunID = nil
        isRetiringInstantWork = false
        guard let runID else { return }
        await completeSyncRun(runID: runID)
    }

    private func completeSyncRun(runID: String) async {
        let stopTask = runnerStopRunID == runID ? runnerStopTask : nil
        await stopTask?.value
        guard activeRunID == runID else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lockStore?.release(runID: runID)
        activeRunID = nil
        isSyncing = false
        updateIdleTimerIfNeeded()
        isScanning = false
        syncTask = nil
        if runnerStopRunID == runID {
            runnerStopTask = nil
            runnerStopRunID = nil
        }
        let shouldRestart = pendingSyncAfterStop && isEnabled && accessState.allowsBackup
        pendingSyncAfterStop = false
        guard !isShuttingDown else { return }
        let request = nextStatusProjectionRequest()
        let finalProjection = await statusProjector?.projectNow(
            context: request.context,
            generation: statusProjectionGeneration,
            revision: request.revision
        )
        guard activeRunID == nil else { return }
        guard queueStore?.isOperational() == true, catalogStore?.isOperational() == true else {
            lastMessage = L10n.string("backup.error_local_state_unavailable")
            return
        }
        let finalProgress = finalProjection?.progress ?? lastProjectedProgress
        let currentBackedUp = finalProgress.backedUp
        if currentBackedUp > backedUpAtRunStart {
            consecutiveNoProgressRuns = 0
        } else {
            consecutiveNoProgressRuns = min(16, consecutiveNoProgressRuns + 1)
        }
        if shouldRestart { syncNow() } else { scheduleAutoResumeIfOutstanding(progress: finalProgress) }
    }

    /// Schedules exactly one wake at the queue's earliest typed eligibility date. If an
    /// unexpected row has no date, use the shared exponential retry policy and increase it only after
    /// a no-progress run. This keeps recovery persistent without hot-looping empty passes.
    private func scheduleAutoResumeIfOutstanding(progress: BackupSyncProgress? = nil) {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        guard !isShuttingDown, isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing,
            queueStore?.isOperational() == true,
            catalogStore?.isOperational() == true
        else { return }
        let p = progress ?? lastProjectedProgress
        guard p.waiting + p.checking + p.uploading + p.blocked > 0 else { return }  // No work remains.
        let currentTime = Date()
        guard
            let wakeAt = BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: p.outstanding.count,
                queueDate: p.outstanding.nextAttemptAt,
                consecutiveNoProgressRuns: consecutiveNoProgressRuns,
                now: currentTime,
                retryPolicy: retryPolicy
            )
        else { return }
        nextAutomaticAttemptAt = wakeAt
        var scheduledProgress = p
        scheduledProgress.outstanding.nextAttemptAt = wakeAt
        status = BackupStatus(
            progress: scheduledProgress, isScanning: false, isUserPaused: isUserPaused,
            executionOpportunityIssue: executionOpportunityIssue
        )
        autoResumeTask = Task { @MainActor [weak self] in
            let delay = max(0, wakeAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isEnabled, !self.isUserPaused, !self.isSyncing else { return }
            self.nextAutomaticAttemptAt = nil
            self.syncNow()
        }
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func refreshFromQueue() {
        guard let statusProjector else { return }
        let request = nextStatusProjectionRequest()
        let generation = statusProjectionGeneration
        Task {
            _ = await statusProjector.projectNow(
                context: request.context,
                generation: generation,
                revision: request.revision
            )
        }
    }

    private func nextStatusProjectionRequest() -> (
        context: BackupStatusProjectionContext,
        revision: UInt64
    ) {
        statusProjectionRevision &+= 1
        return (projectionContext, statusProjectionRevision)
    }

    private func noteUploadedLibraryMutation(_ uploadedCount: Int) {
        guard let previous = lastObservedUploadedCount else {
            lastObservedUploadedCount = uploadedCount
            return
        }
        if uploadedCount > previous {
            uploadedLibraryMutationRevision &+= 1
        }
        lastObservedUploadedCount = uploadedCount
    }

    /// Keeps the display awake while a backup pass is actively running (iOS host implements
    /// `idleTimerHook`). When idle, paused, or disabled the hook receives `false` so the screen
    /// auto-locks. This method is called at every transition of `isSyncing` to guarantee the timer state
    /// stays in sync and never pins the display after backup ends, even on cancelled/exiting paths.
    private func updateIdleTimerIfNeeded() {
        idleTimerHook?(isSyncing)
    }

    private static func defaultIssue(for state: UploadBackupSyncQueueState) -> BackupIssueKind {
        switch state {
        case .sourceMissing: .sourceMissing
        case .blockedByDraft: .remoteDraft
        case .failedPermanent: .remoteDraftStale
        case .skippedRemoteDeletion: .remoteDeletion
        default: .unknown
        }
    }

    private static func defaultIssueDetail(for issue: BackupIssueKind) -> String {
        switch issue {
        case .network: L10n.string("backup.issue_network")
        case .deviceStorage: L10n.string("backup.issue_device_storage")
        case .remoteDraft: L10n.string("backup.issue_remote_draft")
        case .remoteDraftStale: L10n.string("backup.issue_remote_draft_stale")
        case .sourceMissing: L10n.string("backup.error_source_missing")
        case .permission: L10n.string("backup.issue_permission")
        case .unsupported: L10n.string("backup.issue_unsupported")
        case .remoteService: L10n.string("backup.issue_remote_service")
        case .localState: L10n.string("backup.error_local_state_unavailable")
        case .remoteDeletion: L10n.string("backup.state_skipped_remote_deletion")
        case .unknown: L10n.string("backup.fail_reason_generic")
        }
    }

    /// Non-secret debugging hint recorded on the lock (platform + pid); never load-bearing.
    private static var processContext: String {
        let process = ProcessInfo.processInfo
        #if os(macOS)
            let platform = "macos"
        #else
            let platform = "ios"
        #endif
        return "\(platform)/pid-\(process.processIdentifier)"
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == Int32(ProcessInfo.processInfo.processIdentifier) { return true }
        #if canImport(Darwin)
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        #else
            return true
        #endif
    }
}

/// One-shot completion flag shared between the index scan and the concurrent reconcile loop: the scan
/// sets it when it finishes (or gives up) so the reconcile loop knows to make one final drain pass and
/// stop, instead of polling forever.
actor BackupScanSignal {
    private var done = false
    func markDone() { done = true }
    func isDone() -> Bool { done }
}
