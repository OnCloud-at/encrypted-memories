import Foundation
import MLSearchCore
import Observation
import PhotosCore
import TimelineCore

/// Account-owned, event-driven suggestion refresh. Visible searches and foreground media always take priority.
@MainActor @Observable
public final class SmartSearchDiscoveryScheduler {
    public private(set) var discovery: SmartSearchDiscoveryModel
    public private(set) var isRefreshing = false

    private struct Input {
        let sections: [TimelineSection]
        let revision: UInt64
        let favorites: Set<PhotoUID>
        let coordinates: [PhotoCoordinate]
        let controller: MLSmartSearchController?
        let snapshot: MLSmartSearchSnapshot?
        let key: String
        let visualKey: String
    }

    @ObservationIgnored private let runtimeState: LibraryRuntimeState
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let placeName: SmartSearchDiscoveryModel.PlaceNameResolver
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var completedKey: String?
    @ObservationIgnored private var failedKey: String?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var eligible = false
    @ObservationIgnored private var evidenceKey: String?
    @ObservationIgnored private var evidence: [String: [PhotoUID]] = [:]

    public init(
        runtimeState: LibraryRuntimeState = .shared,
        debounce: Duration = .milliseconds(250),
        placeName: @escaping SmartSearchDiscoveryModel.PlaceNameResolver
    ) {
        self.runtimeState = runtimeState
        self.debounce = debounce
        self.placeName = placeName
        discovery = SmartSearchDiscoveryModel(refreshPolicy: .background, placeName: placeName)
    }

    public static func revisionKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int,
        smartSearch: MLSmartSearchController?
    ) -> String {
        let snapshot = smartSearch?.snapshot
        let visualKey = SmartSearchDiscoveryModel.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot)
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return [
            visualKey, "\(favoriteUIDs.hashValue)", "\(coordinateCount)", "\(day)",
            "\(snapshot?.isEnabled == true)", "\(snapshot?.isVisualSearchEnabled == true)",
            smartSearch.map { "\(ObjectIdentifier($0))" } ?? "-",
        ].joined(separator: "|")
    }

    public func update(
        sections: [TimelineSection], timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate], smartSearch: MLSmartSearchController?
    ) {
        if let input, input.controller !== smartSearch { reset() }
        let snapshot = smartSearch?.snapshot
        let visualKey = SmartSearchDiscoveryModel.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot)
        let key = Self.revisionKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
            coordinateCount: coordinates.count, smartSearch: smartSearch
        )
        guard input?.key != key else { return }
        input = Input(
            sections: sections, revision: timelineRevision, favorites: favoriteUIDs,
            coordinates: coordinates, controller: smartSearch, snapshot: snapshot, key: key, visualKey: visualKey)
        failedKey = nil
        retryCount = 0
        if observer == nil {
            eligible = Self.permitsRefresh(runtimeState.snapshot())
            let updates = runtimeState.updates()
            observer = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled, let self else { return }
                    self.conditionsChanged(snapshot)
                }
            }
        }
        schedule(after: debounce)
    }

    /// Called by account/scope teardown before its controllers and stores are retired.
    public func reset() {
        generation &+= 1
        task?.cancel()
        observer?.cancel()
        task = nil
        observer = nil
        input = nil
        completedKey = nil
        failedKey = nil
        evidenceKey = nil
        evidence = [:]
        retryCount = 0
        isRefreshing = false
        discovery = SmartSearchDiscoveryModel(refreshPolicy: .background, placeName: placeName)
    }

    private static func permitsRefresh(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.executionOpportunity == .foregroundActive
            && !snapshot.isLowPowerMode
            && snapshot.thermalLevel < .serious
            && snapshot.memoryPressure == .normal
            && snapshot.memoryHeadroom != .constrained && snapshot.memoryHeadroom != .critical
            && !snapshot.hasActiveUserInteraction && !snapshot.hasVisibleMediaDemand
            && snapshot.activeVideoPlaybackCount == 0 && snapshot.activeUserTransferCount == 0
            && snapshot.activeSearchCount == 0
    }

    private func conditionsChanged(_ snapshot: LibraryRuntimeSnapshot) {
        let wasEligible = eligible
        eligible = Self.permitsRefresh(snapshot)
        if !eligible {
            task?.cancel()
        } else if !wasEligible {
            failedKey = nil
            retryCount = 0
            schedule(after: debounce)
        }
    }

    private func schedule(after delay: Duration) {
        guard task == nil, eligible, let input, completedKey != input.key, failedKey != input.key else { return }
        let generation = generation
        task = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch {}
            guard let self, self.generation == generation else { return }
            var succeeded = false
            let current = self.input
            if !Task.isCancelled, self.eligible, let current {
                self.isRefreshing = true
                succeeded = await self.refresh(current)
            }
            guard self.generation == generation else { return }
            self.isRefreshing = false
            self.task = nil
            guard let current, !Task.isCancelled else {
                self.schedule(after: self.debounce)
                return
            }
            guard current.key == self.input?.key else {
                self.schedule(after: self.debounce)
                return
            }
            if succeeded {
                self.completedKey = current.key
            } else {
                let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
                guard self.retryCount < delays.count else {
                    PhotoDiagnostics.shared.increment("ml.suggestions.evidenceRetryExhausted")
                    self.failedKey = current.key
                    return
                }
                let delay = delays[self.retryCount]
                self.retryCount += 1
                self.schedule(after: delay)
            }
        }
    }

    private func refresh(_ input: Input) async -> Bool {
        let previous = discovery
        // Build later updates privately. Entering Search during cancellation keeps the published rows usable.
        let model =
            previous.hasComputed
            ? SmartSearchDiscoveryModel(refreshPolicy: .background, placeName: placeName) : previous
        let lifecycle = input.controller?.lifecycleActor
        let covered = await lifecycle?.semanticIndexedAssetCount() ?? 0
        guard !Task.isCancelled else { return false }
        // Publish cheap metadata first. Visual previews stay closed until the complete evidence batch succeeds.
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: nil, includeVisualConcepts: false
        )
        guard !Task.isCancelled else { return false }
        guard SmartSearchDiscoveryModel.visualIndexReady(input.snapshot), covered > 0, let lifecycle else {
            if !SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot)
                || !previous.forYou.contains(where: { $0.kind == .concept })
            {
                discovery = model
            }
            return true
        }
        if evidenceKey != input.visualKey {
            do {
                let fresh = try await lifecycle.searchSuggestionEvidence()
                guard !Task.isCancelled else { return false }
                evidence = fresh
                evidenceKey = input.visualKey
            } catch is CancellationError {
                return false
            } catch {
                PhotoDiagnostics.shared.increment("ml.suggestions.evidenceBatchFailed")
                return false
            }
        }
        let evidence = evidence
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: { prompt, limit in
                guard let matches = evidence[prompt] else { throw MLSmartSearchQueryError.unavailable }
                return Array(matches.prefix(max(0, limit)))
            }
        )
        guard !Task.isCancelled, model.lastRefreshCompleted else { return false }
        discovery = model
        return true
    }

    deinit {
        task?.cancel()
        observer?.cancel()
    }
}
