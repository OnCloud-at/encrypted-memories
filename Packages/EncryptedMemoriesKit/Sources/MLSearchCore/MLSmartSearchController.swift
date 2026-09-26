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
    /// A switch-on that the lifecycle has not taken up yet. The switch shows on at once instead of flickering off
    /// until the lifecycle's snapshot arrives.
    public private(set) var isStartRequested = false

    @ObservationIgnored private let lifecycle: MLSmartSearchLifecycle
    @ObservationIgnored private let artifactAccess: MLScopedArtifactAccess
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    /// Numbers switch-on and switch-off intents in the order the person gave them.
    @ObservationIgnored private var startIntents: UInt64 = 0

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
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private func apply(_ snapshot: MLSmartSearchSnapshot) {
        // From here the snapshot shows the switch-on itself.
        if snapshot.isStartPending || snapshot.isEnabled { isStartRequested = false }
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        self.presentation = MLSmartSearchPresentation(snapshot: snapshot)
        self.modelPresentation = MLSmartSearchModelPresentation(snapshot: snapshot)
    }

    // MARK: - Intents (fire-and-forget into the lifecycle actor)

    /// Turns Smart Search on with the model that suits the device language; it downloads without asking.
    public func enableRecommended(preferredLanguages: [String] = Locale.preferredLanguages) {
        startIntents &+= 1
        let intent = startIntents
        isStartRequested = true
        Task { [weak self, lifecycle] in
            let accepted = await lifecycle.enableRecommended(preferredLanguages: preferredLanguages, intent: intent)
            guard !accepted, let self, self.startIntents == intent else { return }
            self.isStartRequested = false
        }
    }

    /// Turning the switch off again before Smart Search started drops that start.
    public func cancelRecommendedEnable() {
        startIntents &+= 1
        let intent = startIntents
        isStartRequested = false
        Task { [lifecycle] in await lifecycle.cancelRecommendedEnable(intent: intent) }
    }

    /// Turns Smart Search on with the chosen model, or switches to it when Smart Search is on.
    public func enable(with id: MLModelID) {
        Task { await lifecycle.enable(with: id) }
    }

    public func select(_ id: MLModelID) {
        Task { await lifecycle.select(id) }
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

    /// The underlying lifecycle, for query coordination and host memory-pressure wiring.
    public nonisolated var lifecycleActor: MLSmartSearchLifecycle { lifecycle }
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
