import Foundation
import Observation
import PhotosCore

/// Owns the filesystem-access lifetime of a user-picked artifact URL. The default begins/ends
/// the URL's security scope; tests inject counters to prove the scope outlives the install.
public struct MLScopedArtifactAccess: Sendable {
    public let begin: @Sendable (URL) -> Bool
    public let end: @Sendable (URL) -> Void

    public init(begin: @escaping @Sendable (URL) -> Bool, end: @escaping @Sendable (URL) -> Void) {
        self.begin = begin
        self.end = end
    }

    public static let securityScoped = MLScopedArtifactAccess(
        begin: { $0.startAccessingSecurityScopedResource() },
        end: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Main-actor observation surface over `MLSmartSearchLifecycle`; the single settings view model
/// both platforms bind to. Views read published state and call intents; every decision stays
/// in the lifecycle actor, and no lifecycle work runs on the main actor (intents hop straight
/// into the actor).
@MainActor
@Observable
public final class MLSmartSearchController {
    public private(set) var snapshot: MLSmartSearchSnapshot = .disabled
    public private(set) var presentation = MLSmartSearchPresentation(snapshot: .disabled)
    public private(set) var modelPresentation = MLSmartSearchModelPresentation(snapshot: .disabled)
    public private(set) var availableSearchScopes: [MLSearchScope] = [.all]
    public private(set) var storageBreakdown: MLSmartSearchStorageBreakdown = .empty

    @ObservationIgnored private let lifecycle: MLSmartSearchLifecycle
    @ObservationIgnored private let artifactAccess: MLScopedArtifactAccess
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var lastStorageMarker: StorageRefreshMarker?

    public init(lifecycle: MLSmartSearchLifecycle, artifactAccess: MLScopedArtifactAccess = .securityScoped) {
        self.lifecycle = lifecycle
        self.artifactAccess = artifactAccess
        observationTask = Task { [weak self, lifecycle] in
            // Attach before startup: restoring stores, refreshing the catalog and loading Core ML
            // may suspend. Every durable transition must reach presentation while that work runs.
            let snapshots = await lifecycle.snapshots()
            let startupTask = Task { await lifecycle.start() }
            defer { startupTask.cancel() }
            for await snapshot in snapshots {
                guard let self else { break }
                self.apply(snapshot)
                let scopes = await lifecycle.availableSearchScopes()
                self.availableSearchScopes = scopes.isEmpty ? [.all] : scopes
                self.refreshStorageIfSettled(snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
        storageTask?.cancel()
    }

    private func apply(_ snapshot: MLSmartSearchSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        self.presentation = MLSmartSearchPresentation(snapshot: snapshot)
        self.modelPresentation = MLSmartSearchModelPresentation(snapshot: snapshot)
    }

    // MARK: - Intents (fire-and-forget into the lifecycle actor)

    public func setEnabled(_ enabled: Bool) {
        Task { await lifecycle.setEnabled(enabled) }
    }

    public func select(_ id: MLModelID) {
        Task { await lifecycle.select(id) }
    }

    public func setVisualSearchEnabled(_ enabled: Bool) {
        Task { await lifecycle.setVisualSearchEnabled(enabled) }
    }

    public func retry() {
        Task { await lifecycle.retry() }
    }

    public func disableAndPurge() {
        Task { await lifecycle.disableAndPurge() }
    }

    /// Install a developer-provided artifact from a user-picked URL. The controller; not any
    /// view owns the filesystem-access lifetime: the security scope stays open until copy,
    /// validation and installation have fully completed inside the lifecycle actor.
    public func installDeveloperModel(from url: URL, for id: MLModelID) {
        let access = artifactAccess
        Task { [lifecycle] in
            let accessing = access.begin(url)
            defer { if accessing { access.end(url) } }
            await lifecycle.installDeveloperModel(from: url, for: id)
        }
    }

    public func noteLibraryChanged() {
        Task { await lifecycle.noteLibraryChanged() }
    }

    public func noteConditionsChanged() {
        Task { await lifecycle.noteConditionsChanged() }
    }

    public func refreshStorageBreakdown() {
        storageTask?.cancel()
        storageTask = Task { [weak self, lifecycle] in
            let breakdown = await lifecycle.storageBreakdown()
            guard !Task.isCancelled else { return }
            self?.storageBreakdown = breakdown
        }
    }

    /// The underlying lifecycle, for query coordination and host memory-pressure wiring.
    public nonisolated var lifecycleActor: MLSmartSearchLifecycle { lifecycle }

    private func refreshStorageIfSettled(_ snapshot: MLSmartSearchSnapshot) {
        guard let marker = StorageRefreshMarker(snapshot: snapshot), marker != lastStorageMarker else { return }
        lastStorageMarker = marker
        refreshStorageBreakdown()
    }

    private struct StorageRefreshMarker: Equatable {
        enum State: Equatable { case disabled, noModel, ready, failed }

        let state: State
        let visualSearchEnabled: Bool
        let installedModelBytes: Int64

        init?(snapshot: MLSmartSearchSnapshot) {
            let state: State
            if !snapshot.isEnabled {
                state = .disabled
            } else if case .ready = snapshot.indexingState {
                state = .ready
            } else {
                switch snapshot.phase {
                case .notInstalled, .selectingModel: state = .noModel
                case .ready: state = .ready
                case .failed: state = .failed
                default: return nil
                }
            }
            self.state = state
            self.visualSearchEnabled = snapshot.isVisualSearchEnabled
            self.installedModelBytes = snapshot.installedModelBytes
        }
    }
}

/// Debounced, epoch-safe query pipeline for the shared timeline search field.
///
/// Feed it the raw search text; it publishes ranked UIDs (or `nil` when search should
/// not filter; disabled, unavailable, empty query, or a failed query). Out-of-order and
/// stale-epoch responses are discarded, so a model switch can never surface old-epoch results.
@MainActor
@Observable
public final class MLSmartSearchQueryCoordinator {
    /// Ranked result UIDs for `resolvedQuery`, best first. During debounce or evaluation of a
    /// newer `requestedQuery`, the last resolved pair remains available so hosts can keep their currently
    /// committed grid authoritative until that newer query is committed.
    public private(set) var rankedUIDs: [PhotoUID]?
    public private(set) var isSearching = false
    /// Normalized query currently being resolved, and the exact query that owns `rankedUIDs`.
    /// Hosts never combine results with an independently committed lexical query by timing alone.
    public private(set) var requestedQuery: String?
    public private(set) var resolvedQuery: String?
    public private(set) var scope: MLSearchScope = .all
    @ObservationIgnored private let lifecycle: MLSmartSearchLifecycle
    @ObservationIgnored private let debounce: Duration
    /// Memory bound for candidate ranking. The model-calibrated Core policy chooses the final count.
    @ObservationIgnored private let maximumCandidateResults: Int
    @ObservationIgnored private var querySequence: UInt64 = 0
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    public init(
        lifecycle: MLSmartSearchLifecycle,
        initialScope: MLSearchScope = .all,
        debounce: Duration = .milliseconds(300),
        maximumCandidateResults: Int = 400
    ) {
        self.lifecycle = lifecycle
        self.scope = initialScope
        self.debounce = debounce
        self.maximumCandidateResults = maximumCandidateResults
    }

    deinit {
        pendingTask?.cancel()
    }

    public func update(query: String) {
        pendingTask?.cancel()
        querySequence &+= 1
        let sequence = querySequence
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rankedUIDs = nil
            isSearching = false
            requestedQuery = nil
            resolvedQuery = nil
            return
        }

        requestedQuery = trimmed
        isSearching = true
        let scope = self.scope
        pendingTask = Task { [lifecycle, debounce, maximumCandidateResults] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let results = try? await lifecycle.searchUIDs(
                trimmed,
                scope: scope,
                limit: maximumCandidateResults
            )
            guard !Task.isCancelled, sequence == self.querySequence else { return }
            self.rankedUIDs = results
            self.resolvedQuery = trimmed
            self.isSearching = false
        }
    }

    public func setScope(_ scope: MLSearchScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        if let requestedQuery { update(query: requestedQuery) }
    }

    public func clear() {
        pendingTask?.cancel()
        querySequence &+= 1
        rankedUIDs = nil
        isSearching = false
        requestedQuery = nil
        resolvedQuery = nil
    }
}
