import Foundation
import PhotosCore

public enum MLSmartSearchQueryError: Error, Equatable {
    /// Smart Search is disabled, has no active model, or has no indexed coverage yet.
    case unavailable
    /// The model epoch changed while the query was in flight; the result was discarded.
    case staleEpoch
}

/// The single universal Smart Search lifecycle: one state machine, one implementation of
/// enable/disable, model selection, download, verification, activation, indexing, switching
/// and purge for every Apple platform. Platform code renders snapshots and calls intents;
/// it never makes lifecycle decisions.
///
/// Durability model:
/// - Installations are transactional (see `MLModelInstaller`).
/// - Multi-step operations (switch, purge) journal a `pendingOperation` before mutating
///   shared state and complete it on the next `start()` after a crash.
/// - Vectors are keyed by `MLModelDescriptor`, so even an interrupted cleanup can never make
///   an old epoch queryable: queries always use the active descriptor.
public actor MLSmartSearchLifecycle {
    public struct Configuration: Sendable {
        /// Delay before re-attempting indexing after a pass ends with transient failures.
        public var indexRetryDelay: Duration
        /// Cadence for rechecking policy suspension independently of failure retries.
        public var closedGateRecheckDelay: Duration
        /// Minimum download-fraction change worth emitting to observers.
        public var downloadProgressStep: Double
        /// Maximum native Vision work in one scheduling turn.
        public var nativeAnalysisQuantumAssets: Int
        /// Maximum semantic work in one scheduling turn.
        public var semanticQuantumAssets: Int
        /// Minimum interval between foreground catalog checks.
        public var catalogRefreshInterval: Duration

        public init(
            indexRetryDelay: Duration = .seconds(120),
            closedGateRecheckDelay: Duration = .seconds(1),
            downloadProgressStep: Double = 0.01,
            nativeAnalysisQuantumAssets: Int = 32,
            semanticQuantumAssets: Int = 128,
            catalogRefreshInterval: Duration = .seconds(15 * 60)
        ) {
            self.indexRetryDelay = indexRetryDelay
            self.closedGateRecheckDelay = closedGateRecheckDelay
            self.downloadProgressStep = downloadProgressStep
            self.nativeAnalysisQuantumAssets = max(1, nativeAnalysisQuantumAssets)
            self.semanticQuantumAssets = max(1, semanticQuantumAssets)
            self.catalogRefreshInterval = max(.zero, catalogRefreshInterval)
        }
    }

    public struct Dependencies: Sendable {
        public var catalog: MLModelCatalog
        public var catalogProvider: any MLModelCatalogProvider
        public var layout: MLModelInstallLayout
        public var stateStore: any MLSmartSearchStateStore
        public var installer: MLModelInstaller
        public var storeProvider: any MLIndexStoreProvider
        public var runtimeProvider: any MLSmartSearchRuntimeProvider
        /// The host's atomic library inventory. Startup hydration is explicitly non-authoritative
        /// so a transient empty timeline can never erase a completed index.
        public var assetsProvider: @Sendable () async -> MLAssetInventorySnapshot
        /// Creates the one native-analysis runtime for this account session. It is recreated after
        /// a full disable/purge so no closed SQLite handle can survive re-enabling Smart Search.
        public var nativeSearchFactory: (@Sendable () async -> (any MLNativeSearchServing)?)?
        /// Product-visible native search backends supported by this composition. This is separate
        /// from the live runtime so the shared UI doesn't flicker or hide OCR while the native
        /// index is being opened behind the resource coordinator.
        public var advertisedNativeSearchBackends: Set<MLSearchBackend>
        public var governor: any MLIndexingGovernor
        /// Cross-feature admission owner for model loading, inference and indexing quanta.
        /// Network downloads remain governed by their transport and never hold a heavy permit.
        public var resourceCoordinator: LibraryResourceCoordinator
        /// `false` in Release builds: developer-only catalog entries cannot be listed,
        /// selected, or activated.
        public var allowsDeveloperModels: Bool
        /// Core-level gate. Hosts may omit UI, but lifecycle work is independently blocked here so
        /// a platform cannot accidentally activate an unsupported or unlicensed feature.
        public var featureAvailability: AppFeatureAvailability
        /// Adapter-injected sustained-work envelope. Scheduling and ramp state remain Core-owned.
        public var indexingCapacityProfile: MLIndexingCapacityProfile

        public init(
            catalog: MLModelCatalog,
            catalogProvider: (any MLModelCatalogProvider)? = nil,
            layout: MLModelInstallLayout,
            stateStore: any MLSmartSearchStateStore,
            installer: MLModelInstaller,
            storeProvider: any MLIndexStoreProvider,
            runtimeProvider: any MLSmartSearchRuntimeProvider,
            assetsProvider: @escaping @Sendable () async -> MLAssetInventorySnapshot,
            nativeSearchFactory: (@Sendable () async -> (any MLNativeSearchServing)?)? = nil,
            advertisedNativeSearchBackends: Set<MLSearchBackend> = [],
            governor: any MLIndexingGovernor,
            resourceCoordinator: LibraryResourceCoordinator = .shared,
            allowsDeveloperModels: Bool,
            featureAvailability: AppFeatureAvailability = .available,
            indexingCapacityProfile: MLIndexingCapacityProfile = .constrained
        ) {
            self.catalog = catalog
            self.catalogProvider = catalogProvider ?? StaticMLModelCatalogProvider(catalog)
            self.layout = layout
            self.stateStore = stateStore
            self.installer = installer
            self.storeProvider = storeProvider
            self.runtimeProvider = runtimeProvider
            self.assetsProvider = assetsProvider
            self.nativeSearchFactory = nativeSearchFactory
            self.advertisedNativeSearchBackends = advertisedNativeSearchBackends
            self.governor = governor
            self.resourceCoordinator = resourceCoordinator
            self.allowsDeveloperModels = allowsDeveloperModels
            self.featureAvailability = featureAvailability
            self.indexingCapacityProfile = indexingCapacityProfile
        }
    }

    private let deps: Dependencies
    private let configuration: Configuration
    private let storageMeter: MLSmartSearchStorageMeter
    private var catalog: MLModelCatalog

    private var persistent = MLSmartSearchPersistentState()
    private var phase: MLSmartSearchPhase = .disabled
    private var indexingState: MLSmartSearchIndexingState = .idle
    private var session: (any MLSmartSearchSession)?
    private var nativeSearch: (any MLNativeSearchServing)?
    private var nativeParallelismRamp: MLNativeParallelismRamp
    private var activeModel: MLInstalledModel?
    /// Bumped on every activation/deactivation; in-flight queries from an older generation
    /// discard their results.
    private var sessionGeneration: UInt64 = 0
    private var lastCoverage = MLIndexCoverage(total: 0, indexed: 0, permanentlyUnindexable: 0)
    private var lastNativeProgress: MLDerivedPipelineProgress?
    private var semanticUnavailableAssetUIDs: Set<PhotoUID> = []
    private var nativeUnavailableAssetUIDs: Set<PhotoUID> = []
    private var libraryGeneration: UInt64 = 0
    private var semanticIndexedLibraryGeneration: UInt64?
    private var nativeIndexedLibraryGeneration: UInt64?
    private var lastEmittedDownloadFraction: Double = -1
    private var lastCatalogRefreshAt: ContinuousClock.Instant?
    private var catalogRefreshInProgress = false
    private var catalogRefreshTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0

    /// `true` while a model switch is mid-flight: the still-running old-epoch index loop must
    /// not overwrite switch/download phases.
    private var switchInProgress = false
    private var indexTask: Task<Void, Never>?
    /// Presentation events are best-effort and never awaited by the indexer. A pass identity
    /// prevents delayed UI work from changing the phase of a later catch-up pass.
    private var activeIndexPassID: UUID?
    private var acceptedIndexProgressSettled = 0
    private var observers: [UUID: AsyncStream<MLSmartSearchSnapshot>.Continuation] = [:]
    private var kickWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Monotonic wake token. A library or condition change that arrives during a pass must be
    /// observed before the indexing loop parks after that pass.
    private var kickGeneration: UInt64 = 0
    private var started = false
    private var stateLoadFailed = false
    /// A known permanent runtime failure is not retried by automatic wakeups or repeated intents
    /// during this actor session. The marker is deliberately in-memory: it is not invented
    /// persisted state, and a relaunch gets a chance to recover from a changed environment.
    private struct BlockedRuntimeFailure: Sendable {
        let modelID: MLModelID
        let revision: String
        let failure: MLRuntimeFailure
    }

    private struct ActivationToken: Sendable {
        let generation: UInt64
        let entry: MLModelCatalogEntry
    }
    private var blockedRuntimeFailure: BlockedRuntimeFailure?
    /// Terminal: set by `shutdown()`. Every intent becomes a no-op, so a host tearing the
    /// session down can never race new lifecycle work against its account purge.
    private var isShutDown = false

    public init(dependencies: Dependencies, configuration: Configuration = Configuration()) {
        self.deps = dependencies
        self.configuration = configuration
        self.storageMeter = MLSmartSearchStorageMeter(layout: dependencies.layout)
        self.catalog = dependencies.catalog
        self.nativeParallelismRamp = MLNativeParallelismRamp(
            ceiling: 1,
            profile: dependencies.indexingCapacityProfile
        )
    }

    // MARK: - Observation

    public func currentSnapshot() -> MLSmartSearchSnapshot { makeSnapshot() }

    public func storageBreakdown() async -> MLSmartSearchStorageBreakdown {
        await storageMeter.measure()
    }

    /// Snapshot stream; yields the current state immediately, then every transition.
    public func snapshots() -> AsyncStream<MLSmartSearchSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit() {
        let snapshot = makeSnapshot()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func makeSnapshot() -> MLSmartSearchSnapshot {
        MLSmartSearchSnapshot(
            isEnabled: persistent.isEnabled,
            isVisualSearchEnabled: persistent.isVisualSearchEnabled,
            selectedModelID: persistent.selectedModelID,
            phase: phase,
            installedModelBytes: activeModel?.record.installedByteCount ?? 0,
            availableModels: catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels),
            isSearchAvailable: persistent.isEnabled
                && ((persistent.isVisualSearchEnabled && session != nil && lastCoverage.indexed > 0)
                    || (nativeSearch != nil && (lastNativeProgress?.completed ?? 0) > 0)),
            indexingState: indexingState
        )
    }

    // MARK: - Startup / recovery

    /// Restore persisted state, finish any journaled operation, and resume work. Idempotent.
    public func start() async {
        guard !started, !isShutDown else { return }
        started = true
        guard deps.featureAvailability == .available else {
            phase = .disabled
            emit()
            return
        }
        guard restorePersistentState() else { return }
        // Publish the durable user intent before any capability probe, catalog request, database
        // setup or model load can suspend. Controllers must never invent "off" while an enabled
        // cold start is still restoring its runtime.
        phase = persistent.isEnabled ? .selectingModel : .disabled
        indexingState = .idle
        emit()
        if persistent.isEnabled {
            await activateNativeSearch()
            startIndexingLoopIfAvailable()
            startCatalogRefreshLoopIfNeeded()
        }
        if persistent.isEnabled, !(await refreshCatalog()) {
            await recoverLocallyInstalledSemanticModelAfterCatalogFailure()
            return
        }
        await resumePersistentState()
    }

    private func restorePersistentState() -> Bool {
        do {
            persistent = try deps.stateStore.load() ?? MLSmartSearchPersistentState()
            stateLoadFailed = false
            return true
        } catch {
            stateLoadFailed = true
            phase = .failed(
                MLSmartSearchFailure(
                    kind: .storage,
                    isRetryable: true,
                    debugDescription: "state read failed: \(String(describing: error))"
                ))
            emit()
            return false
        }
    }

    private func resumePersistentState() async {
        switch persistent.pendingOperation {
        case .purge:
            // A purge that began before a crash completes before anything else may run.
            await performPurge()
            return
        case .switchModel(let from, let to):
            guard
                await completeSwitchCleanup(
                    from: from,
                    to: to,
                    descriptor: persistent.activatedDescriptor
                )
            else { return }
        case .disableVisualSearch(let model):
            guard
                await completeVisualSearchDisable(
                    model: model,
                    descriptor: persistent.activatedDescriptor
                )
            else { return }
        case nil:
            break
        }

        guard persistent.isEnabled else {
            phase = .disabled
            indexingState = .idle
            emit()
            return
        }
        await activateNativeSearch()
        guard persistent.isVisualSearchEnabled, persistent.selectedModelID != nil else {
            phase = .selectingModel
            emit()
            startIndexingLoopIfAvailable()
            return
        }
        await activateSelectedModel()
    }

    /// Stops new work, awaits active tasks, releases model resources, and closes storage.
    /// Call this before account purge or sign-out so no task retains files in the search root.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        activationGeneration &+= 1
        await stopCatalogRefreshLoop()
        await deps.installer.cancelAllInstalls()
        await stopIndexing()
        await teardownSession()
        await shutdownNativeSearch()
        deps.storeProvider.closeStore()
        for continuation in observers.values {
            continuation.finish()
        }
        observers = [:]
    }

    // MARK: - Intents

    public func setEnabled(_ enabled: Bool) async {
        guard !isShutDown, deps.featureAvailability == .available,
            enabled != persistent.isEnabled
        else { return }
        activationGeneration &+= 1
        if enabled {
            persistent.isEnabled = true
            // Persist enablement before starting any download or index work. A failed write
            // leaves an honest retryable state and cannot create unowned derived data.
            guard persistState() else { return }
            startCatalogRefreshLoopIfNeeded()
            // Publish the durable user intent before capability probes, database setup, or
            // catalog I/O. Settings must never appear blocked by background initialization.
            phase = .selectingModel
            emit()
            await activateNativeSearch(intent: .userInitiated)
            guard !isShutDown, persistent.isEnabled else { return }
            startIndexingLoopIfAvailable()
            guard await refreshCatalog() else { return }
            guard !isShutDown, persistent.isEnabled else { return }
            let selectable = catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels)
            guard !selectable.isEmpty else {
                phase = .notInstalled(downloadable: false)
                emit()
                return
            }
            guard let selectedID = persistent.selectedModelID,
                selectable.contains(where: { $0.id == selectedID })
            else {
                persistent.selectedModelID = nil
                persistent.activatedRevision = nil
                persistent.activatedDescriptor = nil
                guard persistState() else { return }
                phase = .selectingModel
                emit()
                return
            }
            await activateSelectedModel(intent: .userInitiated)
        } else {
            await performPurge()
        }
    }

    /// Explicit full disable + purge (same as `setEnabled(false)`, exposed for the destructive
    /// confirmation flow).
    public func disableAndPurge() async {
        guard !isShutDown else { return }
        await performPurge()
    }

    /// Independently controls the optional semantic image model. Turning it off removes only
    /// semantic vectors and model artifacts; Apple Vision text, document and barcode search
    /// remains enabled and keeps its durable progress.
    public func setVisualSearchEnabled(_ enabled: Bool) async {
        guard !isShutDown, persistent.isEnabled,
            enabled != persistent.isVisualSearchEnabled
        else { return }
        activationGeneration &+= 1

        if enabled {
            persistent.isVisualSearchEnabled = true
            guard persistState() else {
                persistent.isVisualSearchEnabled = false
                return
            }
            phase = .selectingModel
            emit()
            if persistent.selectedModelID == nil {
                startIndexingLoopIfAvailable()
            } else {
                await activateSelectedModel(intent: .userInitiated)
            }
            return
        }

        let selectedModel = persistent.selectedModelID
        persistent.pendingOperation = .disableVisualSearch(model: selectedModel)
        persistent.isVisualSearchEnabled = false
        guard persistState() else {
            persistent.pendingOperation = nil
            persistent.isVisualSearchEnabled = true
            return
        }
        phase = .deleting
        emit()
        _ = await completeVisualSearchDisable(
            model: selectedModel,
            descriptor: persistent.activatedDescriptor
        )
    }

    /// Select a model. The same selection is a no-op; another model runs the transactional switch,
    /// retires the old epoch, activates the new model, and starts a clean reindex.
    public func select(_ id: MLModelID) async {
        guard !isShutDown, persistent.isEnabled else { return }
        guard let target = catalog.entry(for: id), isSelectable(target) else { return }

        if id == persistent.selectedModelID {
            guard !persistent.isVisualSearchEnabled else { return }
            await setVisualSearchEnabled(true)
            return
        }

        // Selecting another model is an explicit new runtime candidate. Do not carry a permanent
        // failure from the previous model epoch into that candidate.
        activationGeneration &+= 1
        let selectionGeneration = activationGeneration
        blockedRuntimeFailure = nil

        let previousSelection = persistent.selectedModelID
        let previousActivatedRevision = persistent.activatedRevision
        let previousActivatedDescriptor = persistent.activatedDescriptor
        let previousID = persistent.isVisualSearchEnabled ? previousSelection : nil
        let startsWithoutActiveModel = previousID == nil
        if startsWithoutActiveModel {
            // Persist an initial optional-model choice before download so a failed transfer is
            // retryable after relaunch. Existing active models use the switch journal below and
            // remain serving until their replacement is installed.
            persistent.isVisualSearchEnabled = true
            persistent.selectedModelID = id
            persistent.activatedRevision = nil
            persistent.activatedDescriptor = nil
            guard persistState() else {
                persistent.isVisualSearchEnabled = false
                persistent.selectedModelID = previousSelection
                persistent.activatedRevision = previousActivatedRevision
                persistent.activatedDescriptor = previousActivatedDescriptor
                return
            }
        }
        switchInProgress = true
        defer { switchInProgress = false }

        // Make the target installable without disturbing the current installation. A hosted target
        // is ready only when its exact signed revision is installed.
        let targetRecord =
            if let plan = target.downloadPlan {
                deps.installer.installedRecord(for: target, revision: plan.revision)
            } else {
                deps.installer.anyInstalledRecord(for: target)
            }
        if targetRecord == nil {
            guard target.isDownloadable else {
                if previousID == nil {
                    phase = .notInstalled(downloadable: false)
                    emit()
                    startIndexingLoopIfAvailable()
                    return
                }
                // Nothing to switch to yet: keep the current model active and report why.
                phase = .switchingModel(to: id)
                emit()
                phase = .failed(
                    MLSmartSearchFailure(
                        kind: .download,
                        isRetryable: false,
                        debugDescription: "no hosted artifact for \(id.rawValue)"
                    ))
                emit()
                await activateSelectedModel(intent: .userInitiated)
                return
            }
            guard await downloadAndInstall(target, expectedGeneration: selectionGeneration) != nil else { return }
        }

        guard !isShutDown, persistent.isEnabled,
            activationGeneration == selectionGeneration
        else { return }

        // Journal the switch before touching shared state. If the journal write fails, revert in
        // memory and keep the current model serving.
        // Keep the activated descriptor until cleanup commits so catalog drift cannot retarget it.
        persistent.pendingOperation = .switchModel(from: previousID, to: id)
        persistent.selectedModelID = id
        persistent.activatedRevision = nil
        guard persistState() else {
            persistent.pendingOperation = nil
            if startsWithoutActiveModel {
                persistent.isVisualSearchEnabled = true
                persistent.selectedModelID = id
                persistent.activatedRevision = nil
                persistent.activatedDescriptor = nil
            } else {
                persistent.selectedModelID = previousID
                persistent.activatedRevision = previousActivatedRevision
                persistent.activatedDescriptor = previousActivatedDescriptor
            }
            return
        }
        phase = .switchingModel(to: id)
        emit()

        // Retire the old epoch, commit the journal, then activate the new epoch from a clean slate.
        // Keep this ordered and idempotent so it also serves crash recovery.
        await stopIndexing()
        guard !isShutDown, persistent.isEnabled,
            activationGeneration == selectionGeneration
        else { return }
        await teardownSession()
        guard !isShutDown, persistent.isEnabled,
            activationGeneration == selectionGeneration
        else { return }
        guard
            await completeSwitchCleanup(
                from: previousID,
                to: id,
                descriptor: previousActivatedDescriptor,
                expectedGeneration: selectionGeneration
            )
        else { return }
        guard !isShutDown, persistent.isEnabled,
            activationGeneration == selectionGeneration
        else { return }
        await activateSelectedModel(intent: .userInitiated)
    }

    /// Retry after a retryable failure (download, model load, storage). A storage failure may
    /// have interrupted a journaled operation; recovery re-runs that operation (idempotent)
    /// instead of blindly re-activating over it.
    public func retry() async {
        guard !isShutDown else { return }
        if stateLoadFailed {
            guard restorePersistentState() else { return }
            await resumePersistentState()
            return
        }
        guard !isShutDown, persistent.isEnabled || persistent.pendingOperation == .purge,
            case .failed(let failure) = phase, failure.isRetryable
        else { return }
        if failure.kind == .catalog {
            guard await refreshCatalog() else { return }
            if persistent.selectedModelID == nil {
                phase = .selectingModel
                emit()
                startIndexingLoopIfAvailable()
            } else {
                await activateSelectedModel(intent: .userInitiated)
            }
            return
        }
        if failure.kind == .storage, persistent.isEnabled, persistent.selectedModelID == nil {
            guard persistState() else { return }
            await activateNativeSearch(intent: .userInitiated)
            phase = .selectingModel
            emit()
            startIndexingLoopIfAvailable()
            return
        }
        switch persistent.pendingOperation {
        case .purge:
            await performPurge()
        case .switchModel(let from, let to):
            guard
                await completeSwitchCleanup(
                    from: from,
                    to: to,
                    descriptor: persistent.activatedDescriptor
                )
            else { return }
            await activateSelectedModel(intent: .userInitiated)
        case .disableVisualSearch(let model):
            _ = await completeVisualSearchDisable(
                model: model,
                descriptor: persistent.activatedDescriptor
            )
        case nil:
            await activateSelectedModel(intent: .userInitiated)
        }
    }

    /// Install a developer-provided local model artifact for `id` (developer environments
    /// only). The artifact is hashed, staged and installed with the same guarantees as a
    /// download.
    public func installDeveloperModel(from artifactDirectory: URL, for id: MLModelID) async {
        guard !isShutDown,
            deps.allowsDeveloperModels,
            persistent.isEnabled,
            persistent.isVisualSearchEnabled,
            let entry = catalog.entry(for: id)
        else { return }
        phase = .installing
        emit()
        do {
            _ = try await deps.installer.installFromLocalArtifact(entry, artifactDirectory: artifactDirectory)
        } catch {
            phase = .failed(
                MLSmartSearchFailure(
                    kind: .installation,
                    isRetryable: true,
                    debugDescription: String(describing: error)
                ))
            emit()
            return
        }
        if persistent.selectedModelID == id {
            blockedRuntimeFailure = nil
            await activateSelectedModel(intent: .userInitiated)
        } else {
            await select(id)
        }
    }

    /// The host's library changed (new or deleted assets): schedule an indexing catch-up.
    public func noteLibraryChanged() {
        libraryGeneration &+= 1
        kick()
    }

    /// Scheduling conditions changed (thermal recovered, power connected, app foregrounded).
    public func noteConditionsChanged() async {
        kick()
        await refreshCatalogIfDue()
    }

    /// Drop cached vector blocks and release model residency under memory pressure.
    public func releaseMemory() async {
        await session?.releaseMemory()
    }

    // MARK: - Search

    /// Epoch-guarded semantic query against the active model. Results from a superseded model
    /// generation are discarded, never returned.
    public func search(_ text: String, limit: Int = 50) async throws -> MLSearchResults {
        guard !isShutDown, persistent.isEnabled, persistent.isVisualSearchEnabled,
            let session, lastCoverage.indexed > 0
        else {
            throw MLSmartSearchQueryError.unavailable
        }
        let generation = sessionGeneration
        let results = try await deps.resourceCoordinator.withHeavyPermit(
            LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small)
        ) { _ in
            try await session.search(text, limit: limit)
        }
        guard generation == sessionGeneration else {
            throw MLSmartSearchQueryError.staleEpoch
        }
        return results
    }

    public func availableSearchScopes() async -> [MLSearchScope] {
        var backends = deps.advertisedNativeSearchBackends
        if persistent.isVisualSearchEnabled, session != nil, lastCoverage.indexed > 0 {
            backends.insert(.semantic)
        }
        if let nativeSearch {
            backends.formUnion(await nativeSearch.availableBackends())
        }
        return MLSearchScopePolicy.availableScopes(for: backends)
    }

    /// Shared query path for every host. Independent score spaces are fused by stable rank only;
    /// semantic similarity and token-match counts are never added or compared.
    public func searchUIDs(
        _ text: String,
        scope: MLSearchScope = .all,
        limit: Int = 50
    ) async throws -> [PhotoUID] {
        guard !isShutDown, persistent.isEnabled, limit > 0 else {
            throw MLSmartSearchQueryError.unavailable
        }
        let semanticRequested = scope == .all || scope == .semantic
        let nativeRequested = scope == .all || scope == .text || scope == .documents || scope == .barcodes
        var semanticUIDs: [PhotoUID] = []
        var nativeUIDs: [PhotoUID] = []
        var hasBackend = false

        if semanticRequested, persistent.isVisualSearchEnabled,
            session != nil, lastCoverage.indexed > 0
        {
            hasBackend = true
            semanticUIDs = try await search(text, limit: limit).results.map(\.uid)
        }
        if nativeRequested, let nativeSearch {
            let backends = await nativeSearch.availableBackends()
            let scopedBackends: Set<MLSearchBackend> =
                switch scope {
                case .all: backends
                case .text: [.recognizedText, .documentText]
                case .documents: [.documentText]
                case .barcodes: [.barcodePayload]
                case .semantic, .similar: []
                }
            if !backends.isDisjoint(with: scopedBackends) {
                hasBackend = true
                nativeUIDs = await nativeSearch.search(text, scope: scope, limit: limit)
            }
        }
        guard hasBackend else { throw MLSmartSearchQueryError.unavailable }
        if scope == .all {
            return MLSearchRankFusion.interleaved([semanticUIDs, nativeUIDs], limit: limit)
        }
        return Array((semanticRequested ? semanticUIDs : nativeUIDs).prefix(limit))
    }

    // MARK: - Activation

    /// A model may be selected/activated in this environment: developer environments see every
    /// entry; release environments require the production track AND a product-usable license.
    private func isSelectable(_ entry: MLModelCatalogEntry) -> Bool {
        deps.allowsDeveloperModels
            || entry.isReleaseReady
    }

    /// Native Apple analysis is the zero-download baseline. It is activated independently from
    /// semantic model selection so OCR/barcode search can index and serve on its own.
    private func activateNativeSearch(intent: LibraryWorkIntent = .automatic) async {
        guard persistent.isEnabled, nativeSearch == nil else { return }
        guard let nativeSearchFactory = deps.nativeSearchFactory else { return }
        let generation = activationGeneration
        let created: (any MLNativeSearchServing)?
        do {
            created = try await deps.resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .mlModelLoading, intent: intent, memoryClass: .medium)
            ) { _ in
                await nativeSearchFactory()
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !isShutDown, persistent.isEnabled, activationGeneration == generation else {
            await created?.shutdown()
            return
        }
        let createdProgress = await created?.progress()
        let createdCeiling = await created?.maximumConcurrentAssets() ?? 1
        guard !isShutDown, persistent.isEnabled, activationGeneration == generation else {
            await created?.shutdown()
            return
        }
        nativeSearch = created
        lastNativeProgress = createdProgress
        if nativeSearch != nil {
            nativeParallelismRamp = MLNativeParallelismRamp(
                ceiling: createdCeiling,
                profile: deps.indexingCapacityProfile
            )
        }
        nativeIndexedLibraryGeneration = nil
        if nativeSearch != nil {
            let aggregate = aggregateProgress()
            indexingState =
                aggregate.totalWorkUnits > 0 && aggregate.isComplete
                ? .ready(aggregate)
                : .indexing(aggregate)
            // progress() reads the durable derived store. Publish restored OCR availability now;
            // semantic catalog/model startup must not keep an already-searchable native index hidden.
            emit()
        }
    }

    private func startIndexingLoopIfAvailable() {
        guard !isShutDown, indexTask == nil, session != nil || nativeSearch != nil else { return }
        startIndexingLoop()
    }

    private func isCurrent(_ token: ActivationToken) -> Bool {
        guard !isShutDown,
            persistent.isEnabled,
            persistent.isVisualSearchEnabled,
            persistent.selectedModelID == token.entry.id,
            activationGeneration == token.generation,
            catalog.entry(for: token.entry.id) == token.entry
        else {
            return false
        }
        return true
    }

    private func activateSelectedModel(intent: LibraryWorkIntent = .automatic) async {
        guard !isShutDown, persistent.isEnabled, persistent.pendingOperation == nil else {
            return
        }

        let token: ActivationToken? =
            if persistent.isVisualSearchEnabled,
                let selectedID = persistent.selectedModelID,
                let entry = catalog.entry(for: selectedID),
                isSelectable(entry)
            {
                ActivationToken(generation: activationGeneration, entry: entry)
            } else {
                nil
            }
        await activateNativeSearch(intent: intent)
        guard !isShutDown, persistent.isEnabled else { return }
        guard let token else {
            phase = .selectingModel
            emit()
            startIndexingLoopIfAvailable()
            return
        }
        guard isCurrent(token) else { return }

        let entry = token.entry
        let selectedID = entry.id

        let previousModel = activeModel?.entry.id == selectedID ? activeModel : nil
        let record: MLModelInstallRecord?
        if let plan = entry.downloadPlan {
            if let installed = deps.installer.installedRecord(for: entry, revision: plan.revision) {
                record = installed
            } else {
                record = await downloadAndInstall(
                    entry,
                    preserving: previousModel,
                    expectedGeneration: token.generation
                )
            }
        } else {
            record = deps.installer.anyInstalledRecord(for: entry)
        }

        guard isCurrent(token) else { return }
        guard let record else {
            if !entry.isDownloadable {
                phase = .notInstalled(downloadable: false)
                emit()
                startIndexingLoopIfAvailable()
            }
            return
        }

        // Model preparation can compile and load Core ML resources. Stop indexing first, but keep
        // the current session alive until the replacement has passed runtime validation.
        await stopIndexing()
        guard isCurrent(token) else { return }
        phase = .preparingModel
        emit()

        guard let store = deps.storeProvider.openStore() else {
            phase = .failed(
                MLSmartSearchFailure(kind: .storage, isRetryable: true, debugDescription: "index store unavailable"))
            emit()
            startIndexingLoopIfAvailable()
            return
        }
        guard isCurrent(token) else { return }

        let installed = MLInstalledModel(
            entry: entry,
            record: record,
            installDirectory: deps.layout.installDirectory(for: entry.id, revision: record.revision),
            runtimeCacheDirectory: deps.layout.runtimeCacheDirectory(
                for: entry.id,
                revision: record.revision
            )
        )
        if let blocked = blockedRuntimeFailure,
            blocked.modelID == selectedID,
            blocked.revision == record.revision
        {
            phase =
                previousModel == nil
                ? .failed(
                    MLSmartSearchFailure(
                        kind: .modelLoad,
                        isRetryable: blocked.failure.isRetryable,
                        debugDescription: blocked.failure.debugDescription
                    ))
                : .ready(lastCoverage)
            emit()
            startIndexingLoopIfAvailable()
            return
        }
        let governor = deps.governor
        let runtimeProvider = deps.runtimeProvider
        do {
            let newSession = try await deps.resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .mlModelLoading, intent: intent, memoryClass: .large)
            ) { _ in
                try await runtimeProvider.makeSession(
                    model: installed,
                    store: store,
                    shouldContinueIndexing: { governor.permitsIndexing() }
                )
            }
            guard isCurrent(token) else {
                await newSession.shutdown()
                return
            }
            let previousRevision = persistent.activatedRevision
            let previousDescriptor = previousModel?.entry.descriptor ?? persistent.activatedDescriptor
            let indexInvalidated =
                previousRevision != nil
                && (previousRevision != record.revision || previousDescriptor != entry.descriptor)
            if indexInvalidated, let previousDescriptor {
                store.removeAll(for: previousDescriptor)
                lastCoverage = MLIndexCoverage(total: 0, indexed: 0, permanentlyUnindexable: 0)
                semanticUnavailableAssetUIDs = []
                semanticIndexedLibraryGeneration = nil
            }
            persistent.activatedRevision = record.revision
            persistent.activatedDescriptor = entry.descriptor
            guard persistState() else {
                persistent.activatedRevision = previousRevision
                persistent.activatedDescriptor = previousDescriptor
                await newSession.shutdown()
                if isCurrent(token), previousModel != nil {
                    phase = .ready(lastCoverage)
                    emit()
                    startIndexingLoopIfAvailable()
                }
                return
            }

            let previousSession = session
            session = newSession
            activeModel = installed
            blockedRuntimeFailure = nil
            sessionGeneration &+= 1
            if let previousSession {
                await previousSession.shutdown()
            }
            guard isCurrent(token) else { return }
            if previousRevision != nil, previousRevision != record.revision {
                await deps.installer.removeInstalledRevisions(
                    of: entry.id,
                    keeping: record.revision
                )
            }
            guard isCurrent(token) else { return }
            startIndexingLoop()
        } catch is CancellationError {
            return
        } catch let failure as MLRuntimeFailure {
            guard isCurrent(token) else { return }
            if failure.isPermanent {
                blockedRuntimeFailure = BlockedRuntimeFailure(
                    modelID: selectedID,
                    revision: record.revision,
                    failure: failure
                )
            }
            if previousModel != nil {
                phase = .ready(lastCoverage)
                emit()
                startIndexingLoopIfAvailable()
            } else {
                phase = .failed(
                    MLSmartSearchFailure(
                        kind: .modelLoad,
                        isRetryable: failure.isRetryable,
                        debugDescription: failure.debugDescription
                    ))
                emit()
                startIndexingLoopIfAvailable()
            }
        } catch {
            guard isCurrent(token) else { return }
            if previousModel != nil {
                phase = .ready(lastCoverage)
                emit()
                startIndexingLoopIfAvailable()
            } else {
                phase = .failed(
                    MLSmartSearchFailure(
                        kind: .modelLoad,
                        isRetryable: true,
                        debugDescription: String(describing: error)
                    ))
                emit()
                startIndexingLoopIfAvailable()
            }
        }
    }

    /// Download + verify + install `entry`. Returns the record, or `nil` after reporting a
    /// failure phase.
    private func downloadAndInstall(
        _ entry: MLModelCatalogEntry,
        preserving previousModel: MLInstalledModel? = nil,
        expectedGeneration: UInt64? = nil
    ) async -> MLModelInstallRecord? {
        if let expectedGeneration,
            isShutDown || activationGeneration != expectedGeneration
        {
            return nil
        }
        phase = .downloading(MLModelTransferProgress(bytesReceived: 0, totalBytes: entry.downloadPlan?.totalByteCount))
        lastEmittedDownloadFraction = -1
        emit()
        do {
            let record = try await deps.installer.install(entry) { [weak self] progress in
                guard let self else { return }
                await self.noteDownloadProgress(progress, expectedGeneration: expectedGeneration)
            }
            if let expectedGeneration,
                isShutDown || activationGeneration != expectedGeneration
            {
                return nil
            }
            phase = .installing
            emit()
            return record
        } catch is CancellationError {
            if let expectedGeneration,
                isShutDown || activationGeneration != expectedGeneration
            {
                return nil
            }
            phase =
                previousModel == nil
                ? persistent.isEnabled ? .notInstalled(downloadable: entry.isDownloadable) : .disabled
                : .ready(lastCoverage)
            emit()
            startIndexingLoopIfAvailable()
            return nil
        } catch let error as MLModelInstallError {
            if let expectedGeneration,
                isShutDown || activationGeneration != expectedGeneration
            {
                return nil
            }
            if error == .cancelled {
                phase =
                    previousModel == nil
                    ? persistent.isEnabled ? .notInstalled(downloadable: entry.isDownloadable) : .disabled
                    : .ready(lastCoverage)
                emit()
                startIndexingLoopIfAvailable()
                return nil
            }
            let kind: MLSmartSearchFailure.Kind
            var isRetryable = true
            switch error {
            case .checksumMismatch, .sizeMismatch, .unsafeArtifactPath:
                kind = .verification
            case .artifactMissing, .ambiguousModelArtifact, .installRecordUnreadable, .notDownloadable:
                kind = .installation
            case .licenseProhibitsDistribution:
                // Retrying cannot change the license; this stays blocked until the catalog
                // ships an entry whose weights are legally distributable.
                kind = .installation
                isRetryable = false
            case .cancelled:
                kind = .download
            }
            phase =
                previousModel == nil
                ? .failed(
                    MLSmartSearchFailure(
                        kind: kind,
                        isRetryable: isRetryable,
                        debugDescription: String(describing: error)
                    ))
                : .ready(lastCoverage)
            emit()
            startIndexingLoopIfAvailable()
            return nil
        } catch {
            if let expectedGeneration,
                isShutDown || activationGeneration != expectedGeneration
            {
                return nil
            }
            phase =
                previousModel == nil
                ? .failed(
                    MLSmartSearchFailure(
                        kind: .download,
                        isRetryable: true,
                        debugDescription: String(describing: error)
                    ))
                : .ready(lastCoverage)
            emit()
            startIndexingLoopIfAvailable()
            return nil
        }
    }

    private func noteDownloadProgress(
        _ progress: MLModelTransferProgress,
        expectedGeneration: UInt64? = nil
    ) {
        if let expectedGeneration,
            isShutDown || activationGeneration != expectedGeneration
        {
            return
        }
        guard case .downloading = phase else { return }
        let fraction = progress.fraction ?? 0
        if fraction >= 1 {
            phase = .verifying
            emit()
            return
        }
        // Coalesce: only whole steps reach observers, so UI never storms.
        guard fraction - lastEmittedDownloadFraction >= configuration.downloadProgressStep else { return }
        lastEmittedDownloadFraction = fraction
        phase = .downloading(progress)
        emit()
    }

    private func acceptsIndexEvent(
        _ progress: MLIndexProgress,
        generation: UInt64,
        passID: UUID
    ) -> Bool {
        guard !switchInProgress else { return false }
        guard generation == sessionGeneration, passID == activeIndexPassID else { return false }
        guard let activeModel, progress.descriptor == activeModel.entry.descriptor else { return false }
        switch phase {
        case .preparingModel, .indexing, .waiting, .ready:
            return true
        default:
            // Purge, model switching and failures own their visible phase until settled.
            return false
        }
    }

    private func noteEmbeddingProduced(
        _ progress: MLIndexProgress,
        generation: UInt64,
        passID: UUID
    ) {
        guard acceptsIndexEvent(progress, generation: generation, passID: passID) else { return }
        lastCoverage = MLIndexCoverage(
            total: progress.totalAssets,
            indexed: progress.indexed + progress.alreadyIndexed,
            permanentlyUnindexable: progress.permanentFailure
        )
        acceptedIndexProgressSettled = progress.settled
        phase = .indexing(progress)
        indexingState = .indexing(aggregateProgress())
        emit()
    }

    private func noteIndexProgress(
        _ progress: MLIndexProgress,
        generation: UInt64,
        passID: UUID
    ) {
        guard acceptsIndexEvent(progress, generation: generation, passID: passID) else { return }
        guard case .indexing = phase else { return }
        guard progress.settled >= acceptedIndexProgressSettled else { return }
        acceptedIndexProgressSettled = progress.settled
        lastCoverage = MLIndexCoverage(
            total: progress.totalAssets,
            indexed: progress.indexed + progress.alreadyIndexed,
            permanentlyUnindexable: progress.permanentFailure
        )
        phase = .indexing(progress)
        indexingState = .indexing(aggregateProgress())
        emit()
    }

    // MARK: - Indexing loop

    private func startIndexingLoop() {
        indexTask?.cancel()
        let generation = sessionGeneration
        indexTask = Task { await runIndexingLoop(generation: generation) }
    }

    private func runIndexingLoop(generation: UInt64) async {
        var scheduledLibraryGeneration: UInt64?
        var scheduledAssets: [PhotoUID] = []
        var scheduledNativeAssets: [MLPipelineAssetRevision] = []

        while !Task.isCancelled,
            generation == sessionGeneration,
            persistent.isEnabled,
            session != nil || nativeSearch != nil
        {
            let observedKickGeneration = kickGeneration
            let observedLibraryGeneration = libraryGeneration
            let semanticNeedsPass =
                session != nil
                && (!lastCoverage.isComplete
                    || semanticIndexedLibraryGeneration != observedLibraryGeneration)
            let nativeNeedsPass =
                nativeSearch != nil
                && (lastNativeProgress?.isComplete != true
                    || nativeIndexedLibraryGeneration != observedLibraryGeneration)

            if !semanticNeedsPass, !nativeNeedsPass {
                let aggregate = aggregateProgress()
                indexingState = .ready(aggregate)
                if session != nil { updatePhaseFromIndexLoop(.ready(lastCoverage)) }
                emit()
                await waitForKick(timeout: nil, since: observedKickGeneration)
                continue
            }

            guard deps.governor.permitsIndexing() else {
                if let activeModel {
                    refreshCoverageFromStoreCount(descriptor: activeModel.entry.descriptor)
                    updatePhaseFromIndexLoop(.waiting(lastCoverage))
                }
                if let nativeSearch { lastNativeProgress = await nativeSearch.progress() }
                indexingState = .waiting(aggregateProgress())
                emit()
                await waitForKick(timeout: configuration.closedGateRecheckDelay, since: observedKickGeneration)
                continue
            }

            if scheduledLibraryGeneration != observedLibraryGeneration {
                let inventory = await deps.assetsProvider()
                guard inventory.isAuthoritative else {
                    if let activeModel {
                        refreshCoverageFromStoreCount(descriptor: activeModel.entry.descriptor)
                        updatePhaseFromIndexLoop(.waiting(lastCoverage))
                    }
                    if let nativeSearch { lastNativeProgress = await nativeSearch.progress() }
                    indexingState = .waiting(aggregateProgress())
                    emit()
                    await waitForKick(timeout: nil, since: observedKickGeneration)
                    continue
                }
                scheduledAssets = inventory.uids
                scheduledNativeAssets = scheduledAssets.compactMap { uid in
                    try? MLPipelineAssetRevision(
                        uid: uid,
                        sourceRevision: "uid-v1:\(uid.volumeID):\(uid.nodeID)"
                    )
                }
                scheduledLibraryGeneration = observedLibraryGeneration
            }
            guard generation == sessionGeneration else { return }

            // Native Vision receives the first turn; native and semantic workloads remain serial.
            let nativeOutcome: MLDerivedPipelinePassOutcome?
            var nativeLeaseDecision: LibraryWorkContinuationDecision?
            if nativeNeedsPass, let nativeSearch {
                do {
                    let assets = scheduledNativeAssets
                    let maximumAssets = min(
                        configuration.nativeAnalysisQuantumAssets,
                        deps.indexingCapacityProfile.nativeQuantumAssets
                    )
                    let governor = deps.governor
                    let requestedParallelism = nativeParallelismRamp.currentParallelism
                    let previousSettled = lastNativeProgress?.settled ?? 0
                    let permitRequestedAt = ContinuousClock.now
                    let permitted = try await deps.resourceCoordinator.withHeavyPermit(
                        LibraryWorkRequest(
                            workload: .mlIndexing,
                            intent: .automatic,
                            memoryClass: .medium,
                            demand: LibraryWorkDemand(
                                maximumInternalParallelism: requestedParallelism,
                                maximumItemsPerQuantum: maximumAssets,
                                maximumWallTime: deps.indexingCapacityProfile.automaticTimeSlice
                            )
                        )
                    ) { lease in
                        let startedAt = ContinuousClock.now
                        let runtimeBefore = lease.currentRuntimeSnapshot()
                        let limit = min(maximumAssets, lease.budget.maxItemsPerQuantum)
                        let outcome = await nativeSearch.indexQuantum(
                            assets: assets,
                            libraryGeneration: observedLibraryGeneration,
                            maximumAssets: limit,
                            maximumConcurrentAssets: lease.budget.internalParallelism,
                            shouldContinue: {
                                governor.permitsIndexing() && lease.shouldContinue()
                            },
                            observer: MLDerivedPipelineObserver { [weak self] progress in
                                await self?.noteNativeIndexProgress(progress, generation: generation)
                            }
                        )
                        let decision = lease.continuationDecision()
                        Self.emitIndexQuantum(
                            pipeline: "native",
                            parallelism: lease.budget.internalParallelism,
                            assetLimit: limit,
                            processed: max(0, outcome.progress.settled - previousSettled),
                            duration: startedAt.duration(to: ContinuousClock.now),
                            wait: permitRequestedAt.duration(to: startedAt),
                            policyReason: lease.budget.reason,
                            yieldReason: Self.yieldReason(
                                decision,
                                completedReason: String(describing: outcome.reason)
                            ),
                            rampStep: requestedParallelism,
                            runtimeBefore: runtimeBefore,
                            runtimeAfter: lease.currentRuntimeSnapshot()
                        )
                        return (outcome, decision)
                    }
                    nativeOutcome = permitted.0
                    nativeLeaseDecision = permitted.1
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            } else {
                nativeOutcome = nil
            }
            guard generation == sessionGeneration, !Task.isCancelled else { return }

            if let nativeOutcome {
                nativeParallelismRamp.note(
                    nativeQuantumDisposition(
                        outcome: nativeOutcome,
                        leaseDecision: nativeLeaseDecision
                    )
                )
                lastNativeProgress = nativeOutcome.progress
                // The detailed UID set is only needed to suppress assets with terminal input
                // failures. On the overwhelmingly common zero-failure path, avoid a second
                // derived-store scan after every short indexing quantum.
                nativeUnavailableAssetUIDs =
                    nativeOutcome.progress.permanentFailure == 0
                    ? []
                    : await nativeSearch?.unavailableAssetUIDs() ?? []
                if nativeOutcome.reason == .drained, nativeOutcome.progress.isComplete {
                    nativeIndexedLibraryGeneration = observedLibraryGeneration
                }
                if nativeOutcome.reason == .storageFailure {
                    let failure = MLSmartSearchFailure(
                        kind: .storage,
                        isRetryable: true,
                        debugDescription: "native analysis store unavailable"
                    )
                    indexingState = .failed(failure)
                    emit()
                    await waitForKick(timeout: configuration.indexRetryDelay, since: observedKickGeneration)
                    continue
                }
            }

            var semanticOutcome: MLIndexPassOutcome?
            var semanticQuantumLimit: Int?
            var semanticLeaseDecision: LibraryWorkContinuationDecision?
            if semanticNeedsPass,
                let session,
                let activeModel,
                deps.governor.permitsIndexing(),
                !Task.isCancelled
            {
                let passID = UUID()
                activeIndexPassID = passID
                acceptedIndexProgressSettled = 0
                let observer = MLIndexPassObserver(
                    embeddingProduced: { [weak self] progress in
                        await self?.noteEmbeddingProduced(progress, generation: generation, passID: passID)
                    },
                    progressUpdated: { [weak self] progress in
                        await self?.noteIndexProgress(progress, generation: generation, passID: passID)
                    }
                )
                let assets = scheduledAssets
                let governor = deps.governor
                let maximumAssets = min(
                    configuration.semanticQuantumAssets,
                    deps.indexingCapacityProfile.semanticQuantumAssets
                )
                let outcome: MLIndexPassOutcome
                do {
                    let permitRequestedAt = ContinuousClock.now
                    let permitted = try await deps.resourceCoordinator.withHeavyPermit(
                        LibraryWorkRequest(
                            workload: .mlIndexing,
                            intent: .automatic,
                            memoryClass: .large,
                            demand: LibraryWorkDemand(
                                maximumInternalParallelism: 1,
                                maximumItemsPerQuantum: maximumAssets,
                                maximumWallTime: deps.indexingCapacityProfile.automaticTimeSlice
                            )
                        )
                    ) { lease in
                        let startedAt = ContinuousClock.now
                        let runtimeBefore = lease.currentRuntimeSnapshot()
                        let limit = min(maximumAssets, lease.budget.maxItemsPerQuantum)
                        let outcome = await session.indexQuantum(
                            assets,
                            libraryGeneration: observedLibraryGeneration,
                            maximumAssets: limit,
                            shouldContinue: {
                                governor.permitsIndexing() && lease.shouldContinue()
                            },
                            observer: observer
                        )
                        let decision = lease.continuationDecision()
                        Self.emitIndexQuantum(
                            pipeline: "semantic",
                            parallelism: 1,
                            assetLimit: limit,
                            processed: outcome.report.total,
                            duration: startedAt.duration(to: ContinuousClock.now),
                            wait: permitRequestedAt.duration(to: startedAt),
                            policyReason: lease.budget.reason,
                            yieldReason: Self.yieldReason(
                                decision,
                                completedReason: outcome.ranToCompletion
                                    ? "completed"
                                    : outcome.report.total >= limit
                                        ? "workQuantumCompleted"
                                        : "policySuspended"
                            ),
                            rampStep: 1,
                            runtimeBefore: runtimeBefore,
                            runtimeAfter: lease.currentRuntimeSnapshot()
                        )
                        return (outcome, limit, decision)
                    }
                    outcome = permitted.0
                    semanticQuantumLimit = permitted.1
                    semanticLeaseDecision = permitted.2
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                semanticOutcome = outcome
                if activeIndexPassID == passID { activeIndexPassID = nil }
                acceptedIndexProgressSettled = 0
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                lastCoverage = outcome.coverage
                semanticUnavailableAssetUIDs = await session.permanentlyUnavailableAssetUIDs(scheduledAssets)
                if outcome.ranToCompletion {
                    removeDeletedAssets(current: scheduledAssets, descriptor: activeModel.entry.descriptor)
                    semanticIndexedLibraryGeneration = observedLibraryGeneration
                }
            }
            guard generation == sessionGeneration, !Task.isCancelled else { return }

            let semanticComplete =
                semanticOutcome.map { $0.ranToCompletion && $0.coverage.isComplete }
                ?? !semanticNeedsPass
            let nativeComplete = nativeOutcome?.progress.isComplete ?? !nativeNeedsPass
            if semanticComplete && nativeComplete {
                indexingState = .ready(aggregateProgress())
                if semanticOutcome != nil { updatePhaseFromIndexLoop(.ready(lastCoverage)) }
                emit()
                await waitForKick(timeout: nil, since: observedKickGeneration)
            } else if deps.governor.permitsIndexing(),
                nativeOutcome?.reason == .workQuantumCompleted
                    || Self.didYield(nativeLeaseDecision)
                    || Self.didYield(semanticLeaseDecision)
                    || semanticOutcome.map({
                        !$0.ranToCompletion
                            && $0.report.total >= (semanticQuantumLimit ?? configuration.semanticQuantumAssets)
                    }) == true
            {
                indexingState = .indexing(aggregateProgress())
                emit()
                // A fair work quantum ended. Re-evaluate priorities immediately rather than
                // presenting a retry wait or sleeping for the transient-failure interval.
                continue
            } else {
                indexingState = .waiting(aggregateProgress())
                if semanticOutcome != nil { updatePhaseFromIndexLoop(.waiting(lastCoverage)) }
                emit()
                let delay =
                    deps.governor.permitsIndexing()
                    ? configuration.indexRetryDelay
                    : configuration.closedGateRecheckDelay
                await waitForKick(timeout: delay, since: observedKickGeneration)
            }
        }
    }

    private func nativeQuantumDisposition(
        outcome: MLDerivedPipelinePassOutcome,
        leaseDecision: LibraryWorkContinuationDecision?
    ) -> MLIndexingQuantumDisposition {
        if case .yield(let reason) = leaseDecision {
            return reason == .timeSliceCompleted ? .clean : .resourceYield
        }
        switch outcome.reason {
        case .drained, .workQuantumCompleted:
            return .clean
        case .policySuspended, .cancelled:
            return .resourceYield
        case .retryPending, .storageFailure:
            return .neutralFailure
        }
    }

    nonisolated private static func emitIndexQuantum(
        pipeline: String,
        parallelism: Int,
        assetLimit: Int,
        processed: Int,
        duration: Duration,
        wait: Duration,
        policyReason: LibraryWorkPolicyReason,
        yieldReason: String,
        rampStep: Int,
        runtimeBefore: LibraryRuntimeSnapshot,
        runtimeAfter: LibraryRuntimeSnapshot
    ) {
        let fields = [
            "pipeline": pipeline,
            "parallelism": "\(parallelism)",
            "assetLimit": "\(assetLimit)",
            "processed": "\(processed)",
            "durationMs": "\(milliseconds(duration))",
            "waitMs": "\(milliseconds(wait))",
            "policyReason": policyReason.rawValue,
            "yieldReason": yieldReason,
            "rampStep": "\(rampStep)",
            "thermalBefore": String(describing: runtimeBefore.thermalLevel),
            "thermalAfter": String(describing: runtimeAfter.thermalLevel),
            "memoryBefore": String(describing: runtimeBefore.memoryBudgetTier),
            "memoryAfter": String(describing: runtimeAfter.memoryBudgetTier),
        ]
        PhotoDiagnostics.shared.emitSupport("MLIndexQuantum", fields)
        PhotoDiagnostics.shared.emitDebug("MLIndexQuantum", fields)
    }

    nonisolated private static func yieldReason(
        _ decision: LibraryWorkContinuationDecision,
        completedReason: String
    ) -> String {
        if case .yield(let reason) = decision { return reason.rawValue }
        return completedReason
    }

    nonisolated private static func didYield(
        _ decision: LibraryWorkContinuationDecision?
    ) -> Bool {
        if case .yield = decision { return true }
        return false
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
        let (wholeSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return UInt64.max }
        let (total, additionOverflow) = wholeSeconds.addingReportingOverflow(milliseconds)
        return additionOverflow ? UInt64.max : total
    }

    private func noteNativeIndexProgress(
        _ progress: MLDerivedPipelineProgress,
        generation: UInt64
    ) {
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        if let current = lastNativeProgress,
            progress.generation < current.generation
                || (progress.generation == current.generation && progress.settled < current.settled)
        {
            return
        }
        lastNativeProgress = progress
        let aggregate = aggregateProgress()
        indexingState = aggregate.isComplete ? .ready(aggregate) : .indexing(aggregate)
        emit()
    }

    private func aggregateProgress() -> MLSmartSearchAggregateProgress {
        let semanticIsActive = persistent.isVisualSearchEnabled && session != nil
        let semanticTotal = semanticIsActive ? lastCoverage.total : 0
        let semanticSettled =
            !semanticIsActive
            ? 0
            : min(lastCoverage.total, lastCoverage.indexed + lastCoverage.permanentlyUnindexable)
        let semanticUnavailable = semanticIsActive ? lastCoverage.permanentlyUnindexable : 0
        let nativeTotal = nativeSearch == nil ? 0 : (lastNativeProgress?.total ?? 0)
        let nativeSettled = nativeSearch == nil ? 0 : (lastNativeProgress?.settled ?? 0)
        let nativeUnavailable = nativeSearch == nil ? 0 : (lastNativeProgress?.unavailableAssets ?? 0)
        let unavailableUIDs = (semanticIsActive ? semanticUnavailableAssetUIDs : [])
            .union(nativeSearch == nil ? [] : nativeUnavailableAssetUIDs)
        var unavailableReasons =
            nativeSearch == nil
            ? [:]
            : (lastNativeProgress?.unavailableAssetReasons ?? [:])
        if semanticUnavailable > 0 {
            unavailableReasons[.analysisFailed, default: 0] += semanticUnavailable
        }
        return MLSmartSearchAggregateProgress(
            totalWorkUnits: semanticTotal + nativeTotal,
            settledWorkUnits: semanticSettled + nativeSettled,
            permanentlyUnavailableAssets: max(
                unavailableUIDs.count,
                max(semanticUnavailable, nativeUnavailable)
            ),
            unavailableAssetReasons: unavailableReasons
        )
    }

    /// Phase writes from the index loop are suppressed while a switch or purge is staging
    /// its own phases.
    private func updatePhaseFromIndexLoop(_ newPhase: MLSmartSearchPhase) {
        guard !switchInProgress, !phase.isBusy || phase == .preparingModel else { return }
        phase = newPhase
    }

    /// Drop vectors for assets that no longer exist in the library.
    private func removeDeletedAssets(current: [PhotoUID], descriptor: MLModelDescriptor) {
        guard let store = deps.storeProvider.openStore() else { return }
        let currentSet = Set(current)
        let deleted = store.allTrackedUIDs(for: descriptor).filter { !currentSet.contains($0) }
        store.remove(uids: deleted, descriptor: descriptor)
    }

    private func refreshCoverageFromStoreCount(descriptor: MLModelDescriptor) {
        guard let store = deps.storeProvider.openStore() else { return }
        let indexed = store.count(for: descriptor)
        lastCoverage = MLIndexCoverage(
            total: max(lastCoverage.total, indexed),
            indexed: indexed,
            permanentlyUnindexable: lastCoverage.permanentlyUnindexable
        )
    }

    // MARK: - Kick / wait

    private func kick() {
        kickGeneration &+= 1
        let waiters = kickWaiters
        kickWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func waitForKick(timeout: Duration?, since observedGeneration: UInt64) async {
        guard kickGeneration == observedGeneration else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                kickWaiters[id] = continuation
                if let timeout {
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        await self?.resumeKickWaiter(id)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.resumeKickWaiter(id) }
        }
    }

    private func resumeKickWaiter(_ id: UUID) {
        guard let waiter = kickWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    // MARK: - Teardown / purge

    private func stopIndexing() async {
        indexTask?.cancel()
        // Resume any parked loop so cancellation lands at the next boundary.
        kick()
        _ = await indexTask?.value
        indexTask = nil
        activeIndexPassID = nil
        acceptedIndexProgressSettled = 0
    }

    private func teardownSession() async {
        sessionGeneration &+= 1
        activeIndexPassID = nil
        acceptedIndexProgressSettled = 0
        if let session {
            await session.shutdown()
        }
        session = nil
        activeModel = nil
        lastCoverage = MLIndexCoverage(total: 0, indexed: 0, permanentlyUnindexable: 0)
        semanticUnavailableAssetUIDs = []
        semanticIndexedLibraryGeneration = nil
    }

    private func shutdownNativeSearch() async {
        await nativeSearch?.shutdown()
        nativeSearch = nil
        nativeParallelismRamp = MLNativeParallelismRamp(
            ceiling: 1,
            profile: deps.indexingCapacityProfile
        )
        lastNativeProgress = nil
        nativeUnavailableAssetUIDs = []
        nativeIndexedLibraryGeneration = nil
    }

    /// Journaled switch cleanup, shared verbatim by the live switch path and crash recovery:
    /// retire the old epoch's vectors, remove the old artifacts (awaited, never fire-and-
    /// forget), then commit the journal. Idempotent; re-running after any interruption
    /// converges to the same state. Returns `false` when the journal commit could not be
    /// persisted; the pending operation stays journaled (and in memory) so `retry()` or the
    /// next `start()` finishes it.
    @discardableResult
    private func completeSwitchCleanup(
        from: MLModelID?,
        to: MLModelID,
        descriptor: MLModelDescriptor?,
        expectedGeneration: UInt64? = nil
    ) async -> Bool {
        if let expectedGeneration,
            isShutDown || !persistent.isEnabled || activationGeneration != expectedGeneration
        {
            return false
        }
        if let from {
            if let descriptor {
                deps.storeProvider.openStore()?.removeAll(for: descriptor)
            }
            if let previousEntry = catalog.entry(for: from) {
                await deps.installer.uninstall(previousEntry)
            }
            if let expectedGeneration,
                isShutDown || !persistent.isEnabled || activationGeneration != expectedGeneration
            {
                return false
            }
        }
        if let expectedGeneration,
            isShutDown || !persistent.isEnabled || activationGeneration != expectedGeneration
        {
            return false
        }
        persistent.selectedModelID = to
        persistent.isVisualSearchEnabled = true
        persistent.activatedRevision = nil
        persistent.activatedDescriptor = nil
        persistent.pendingOperation = nil
        guard persistState() else {
            // Keep the journal in memory too: retry/start re-run this exact cleanup.
            persistent.pendingOperation = .switchModel(from: from, to: to)
            persistent.activatedDescriptor = descriptor
            return false
        }
        return true
    }

    /// Crash-recoverable cleanup for the optional visual backend. The selected model ID remains
    /// as the user's preference, but no model bytes, semantic vectors or runtime session remain
    /// while the switch is off. Native derived artifacts live in a separate store and survive.
    @discardableResult
    private func completeVisualSearchDisable(
        model: MLModelID?,
        descriptor: MLModelDescriptor?
    ) async -> Bool {
        await deps.installer.cancelAllInstalls()
        await stopIndexing()
        await teardownSession()

        if let model {
            if let descriptor {
                deps.storeProvider.openStore()?.removeAll(for: descriptor)
            }
            if let entry = catalog.entry(for: model) {
                await deps.installer.uninstall(entry)
            }
        }

        persistent.isVisualSearchEnabled = false
        persistent.activatedRevision = nil
        persistent.activatedDescriptor = nil
        persistent.pendingOperation = nil
        guard persistState() else {
            persistent.pendingOperation = .disableVisualSearch(model: model)
            persistent.activatedDescriptor = descriptor
            return false
        }

        phase = .selectingModel
        let aggregate = aggregateProgress()
        indexingState = aggregate.isComplete ? .ready(aggregate) : .indexing(aggregate)
        emit()
        startIndexingLoopIfAvailable()
        return true
    }

    /// Full disable: stop everything, close every handle, delete every Smart Search artifact,
    /// return to the clean disabled state. Idempotent and journaled (a crash mid-purge
    /// completes on next start).
    private func performPurge() async {
        activationGeneration &+= 1
        // Journal first: any crash from here on re-runs the purge. If the journal itself
        // cannot be written, the purge does not start silently; the failure phase is honest
        // and `retry()` re-attempts the whole purge.
        persistent.pendingOperation = .purge
        persistent.isEnabled = false
        guard persistState() else { return }
        await stopCatalogRefreshLoop()

        phase = .deleting
        indexingState = .idle
        emit()

        await deps.installer.cancelAllInstalls()
        await stopIndexing()
        await teardownSession()
        await shutdownNativeSearch()
        deps.storeProvider.closeStore()

        // Everything Smart Search owns lives under the layout root; one recursive delete is
        // the provably complete purge (index DB + WAL/SHM, models, temp files, state).
        do {
            try FileManager.default.removeItem(at: deps.layout.rootDirectory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Already gone; purge is idempotent.
        } catch {
            // Files may remain: stay journaled (state file might survive inside the root) and
            // report a retryable storage failure instead of pretending the purge completed.
            phase = .failed(
                MLSmartSearchFailure(
                    kind: .storage,
                    isRetryable: true,
                    debugDescription: "purge failed: \(String(describing: error))"
                ))
            emit()
            return
        }

        // No persisted state left: a relaunch loads the default disabled state.
        persistent = MLSmartSearchPersistentState()
        blockedRuntimeFailure = nil
        phase = .disabled
        indexingState = .idle
        emit()
    }

    /// Persist the current state. On failure: emit an honest, retryable `.failed(.storage)`
    /// phase and return `false`; callers must not continue without an atomic state commit.
    private func persistState() -> Bool {
        do {
            try deps.stateStore.save(persistent)
            stateLoadFailed = false
            return true
        } catch {
            phase = .failed(
                MLSmartSearchFailure(
                    kind: .storage,
                    isRetryable: true,
                    debugDescription: "state write failed: \(String(describing: error))"
                ))
            emit()
            return false
        }
    }

    private func recoverLocallyInstalledSemanticModelAfterCatalogFailure() async {
        guard !isShutDown,
            persistent.isEnabled,
            persistent.isVisualSearchEnabled,
            let selectedID = persistent.selectedModelID,
            let entry = catalog.entry(for: selectedID),
            isSelectable(entry)
        else {
            return
        }
        let hasVerifiedInstall: Bool
        if let plan = entry.downloadPlan {
            hasVerifiedInstall = deps.installer.installedRecord(for: entry, revision: plan.revision) != nil
        } else {
            hasVerifiedInstall = deps.installer.anyInstalledRecord(for: entry) != nil
        }
        guard hasVerifiedInstall else { return }
        await activateSelectedModel()
    }

    /// Refreshes only the signed distribution data. Runtime contracts, dimensions and
    /// licensing remain compiled into the app and are validated by the provider.
    private func refreshCatalog() async -> Bool {
        phase = .loadingCatalog
        emit()
        do {
            let refreshed = try await deps.catalogProvider.catalog()
            guard !isShutDown else { return false }
            catalog = refreshed
            lastCatalogRefreshAt = .now
            return true
        } catch {
            guard !isShutDown else { return false }
            phase = .failed(
                MLSmartSearchFailure(
                    kind: .catalog,
                    isRetryable: true,
                    debugDescription: String(describing: error)
                ))
            emit()
            return false
        }
    }

    private func refreshCatalogIfDue() async {
        guard started, !isShutDown, persistent.isEnabled, !catalogRefreshInProgress else { return }
        let now = ContinuousClock.now
        if let lastCatalogRefreshAt,
            lastCatalogRefreshAt.duration(to: now) < configuration.catalogRefreshInterval
        {
            return
        }

        catalogRefreshInProgress = true
        defer { catalogRefreshInProgress = false }
        guard let refreshed = try? await deps.catalogProvider.catalog() else { return }
        guard !isShutDown, persistent.isEnabled else { return }
        lastCatalogRefreshAt = now
        let previousCatalog = catalog
        catalog = refreshed
        let recoveredFromCatalogFailure =
            if case .failed(let failure) = phase {
                failure.kind == .catalog
            } else {
                false
            }
        if previousCatalog != refreshed || recoveredFromCatalogFailure { emit() }

        if persistent.selectedModelID == nil {
            phase = .selectingModel
            emit()
            startIndexingLoopIfAvailable()
            return
        }

        if !persistent.isVisualSearchEnabled {
            phase = .selectingModel
            emit()
            startIndexingLoopIfAvailable()
            return
        }

        guard let selectedID = persistent.selectedModelID,
            let entry = refreshed.entry(for: selectedID),
            isSelectable(entry)
        else {
            if recoveredFromCatalogFailure {
                phase = activeModel == nil ? .selectingModel : .ready(lastCoverage)
                emit()
                startIndexingLoopIfAvailable()
            }
            return
        }
        if let previousEntry = previousCatalog.entry(for: selectedID),
            previousEntry.descriptor != entry.descriptor
                || previousEntry.downloadPlan != entry.downloadPlan
        {
            activationGeneration &+= 1
        }

        let needsActivation: Bool
        if let plan = entry.downloadPlan {
            let active = activeModel?.entry.id == selectedID ? activeModel : nil
            needsActivation =
                active == nil
                || active?.record.revision != plan.revision
                || active?.entry.descriptor != entry.descriptor
                || active?.entry.downloadPlan != entry.downloadPlan
        } else if let active = activeModel, active.entry.id == selectedID {
            needsActivation = active.entry.descriptor != entry.descriptor
        } else {
            needsActivation = deps.installer.anyInstalledRecord(for: entry) != nil
        }
        if needsActivation {
            await activateSelectedModel(intent: .automatic)
        } else if recoveredFromCatalogFailure {
            phase = activeModel == nil ? .selectingModel : .ready(lastCoverage)
            emit()
            startIndexingLoopIfAvailable()
        }
    }

    private func startCatalogRefreshLoopIfNeeded() {
        guard catalogRefreshTask == nil,
            configuration.catalogRefreshInterval > .zero
        else { return }
        let interval = configuration.catalogRefreshInterval
        catalogRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshCatalogIfDue()
            }
        }
    }

    private func stopCatalogRefreshLoop() async {
        let task = catalogRefreshTask
        catalogRefreshTask = nil
        task?.cancel()
        _ = await task?.value
    }
}
