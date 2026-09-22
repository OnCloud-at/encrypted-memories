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

    private struct Input: Sendable {
        let sections: [TimelineSection]
        let revision: UInt64
        let favorites: Set<PhotoUID>
        let coordinates: [PhotoCoordinate]
        let controller: MLSmartSearchController?
        let snapshot: MLSmartSearchSnapshot?
        let key: String
        let contentKey: String
        let visualKey: String
        let libraryIsSettled: Bool
        let indexedAssetCount: @Sendable () async -> Int
        let searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?
        let cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)?
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
    @ObservationIgnored private var evidence: MLSearchBatchResults?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cacheGeneration: UInt64 = 0
    @ObservationIgnored private var preparedCacheKey: String?
    @ObservationIgnored private var cacheAccess: MLSearchSuggestionCacheAccess?
    @ObservationIgnored private var contentFingerprint: Data?

    #if DEBUG
        var cachedEvidenceAssetCount: Int { evidence?.scannedUIDs.count ?? 0 }
    #endif

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
        revisionKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinateCount,
            smartSearch: smartSearch, snapshot: smartSearch?.snapshot)
    }

    private static func revisionKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int,
        smartSearch: MLSmartSearchController?, snapshot: MLSmartSearchSnapshot?
    ) -> String {
        contentKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinateCount,
            smartSearch: smartSearch, snapshot: snapshot) + "|recovery:\(coverageState(snapshot).progressBucket)"
    }

    private static func contentKey(
        timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>, coordinateCount: Int,
        smartSearch: MLSmartSearchController?, snapshot: MLSmartSearchSnapshot?
    ) -> String {
        let visualKey = visualEvidenceKey(
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
        coordinates: [PhotoCoordinate], smartSearch: MLSmartSearchController?, libraryIsSettled: Bool = true
    ) {
        let lifecycle = smartSearch?.lifecycleActor
        let searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?
        let cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)?
        if let lifecycle {
            searchEvidence = { try await lifecycle.searchSuggestionEvidence() }
            cacheAccess = { await lifecycle.suggestionCacheAccess() }
        } else {
            searchEvidence = nil
            cacheAccess = nil
        }
        update(
            sections: sections, timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
            coordinates: coordinates, smartSearch: smartSearch, snapshot: smartSearch?.snapshot,
            indexedAssetCount: { await lifecycle?.semanticIndexedAssetCount() ?? 0 },
            searchEvidence: searchEvidence, libraryIsSettled: libraryIsSettled,
            cacheAccess: cacheAccess)
    }

    func update(
        sections: [TimelineSection], timelineRevision: UInt64, favoriteUIDs: Set<PhotoUID>,
        coordinates: [PhotoCoordinate], smartSearch: MLSmartSearchController? = nil,
        snapshot: MLSmartSearchSnapshot?, indexedAssetCount: @escaping @Sendable () async -> Int,
        searchEvidence: (@Sendable () async throws -> MLSearchBatchResults)?, libraryIsSettled: Bool = true,
        cacheAccess: (@Sendable () async -> MLSearchSuggestionCacheAccess?)? = nil
    ) {
        if let input, input.controller !== smartSearch { reset() }
        let visualKey = Self.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot)
        let key =
            Self.revisionKey(
                timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs,
                coordinateCount: coordinates.count, smartSearch: smartSearch, snapshot: snapshot
            ) + "|librarySettled:\(libraryIsSettled)"
        guard input?.key != key else { return }
        let contentKey = Self.contentKey(
            timelineRevision: timelineRevision, favoriteUIDs: favoriteUIDs, coordinateCount: coordinates.count,
            smartSearch: smartSearch, snapshot: snapshot)
        // A replacement inventory must stop the superseded scan, not queue another full pass behind it.
        if input?.contentKey != contentKey || !libraryIsSettled { task?.cancel() }
        if input?.contentKey != contentKey || !libraryIsSettled {
            cacheGeneration &+= 1
            cacheTask?.cancel()
            cacheTask = nil
            preparedCacheKey = nil
            self.cacheAccess = nil
            contentFingerprint = nil
        }
        if !SmartSearchDiscoveryModel.visualConceptsAvailable(snapshot) || evidenceKey != visualKey {
            discardEvidence()
        }
        eligible = libraryIsSettled && Self.permitsRefresh(runtimeState.snapshot())
        input = Input(
            sections: sections, revision: timelineRevision, favorites: favoriteUIDs,
            coordinates: coordinates, controller: smartSearch, snapshot: snapshot, key: key,
            contentKey: contentKey, visualKey: visualKey, libraryIsSettled: libraryIsSettled,
            indexedAssetCount: indexedAssetCount, searchEvidence: searchEvidence, cacheAccess: cacheAccess)
        failedKey = nil
        retryCount = 0
        if observer == nil {
            let updates = runtimeState.updates()
            observer = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled, let self else { return }
                    self.conditionsChanged(snapshot)
                }
            }
        }
        prepareCacheIfNeeded()
        schedule(after: debounce)
    }

    /// Native indexing can remain pending after the semantic model has finished.
    /// Progress only rearms exhausted failures; healthy partial evidence stays cached until completion.
    private static func visualEvidenceKey(timelineRevision: UInt64, snapshot: MLSmartSearchSnapshot?) -> String {
        SmartSearchDiscoveryModel.visualEvidenceKey(
            timelineRevision: timelineRevision, snapshot: snapshot, indexingKey: coverageState(snapshot).stage)
    }

    private static func coverageState(_ snapshot: MLSmartSearchSnapshot?) -> (stage: String, progressBucket: Int) {
        let indexed: Int
        let total: Int
        let complete: Bool
        switch snapshot?.phase {
        case .ready(let coverage), .waiting(let coverage):
            indexed = coverage.indexed
            total = coverage.total
            complete = coverage.isComplete
        case .indexing(let progress):
            indexed = progress.indexed + progress.alreadyIndexed
            total = progress.totalAssets
            complete = indexed + progress.permanentFailure >= total && progress.transientFailure == 0
        default:
            return ("empty", 0)
        }
        let stage = indexed == 0 ? "empty" : (complete ? "complete" : "partial")
        return (stage, total > 0 ? min(10, Int(Double(indexed) / Double(total) * 10)) : 0)
    }

    /// Called by account/scope teardown before its controllers and stores are retired.
    public func reset() {
        generation &+= 1
        task?.cancel()
        observer?.cancel()
        cacheTask?.cancel()
        cacheTask = nil
        cacheGeneration &+= 1
        preparedCacheKey = nil
        cacheAccess = nil
        contentFingerprint = nil
        task = nil
        observer = nil
        input = nil
        completedKey = nil
        failedKey = nil
        evidenceKey = nil
        evidence = nil
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
        if snapshot.memoryPressure != .normal || snapshot.memoryHeadroom >= .constrained {
            discardEvidence()
            if cacheTask != nil {
                cacheGeneration &+= 1
                cacheTask?.cancel()
                cacheTask = nil
                preparedCacheKey = nil
            }
        } else {
            prepareCacheIfNeeded()
        }
        eligible = input?.libraryIsSettled == true && Self.permitsRefresh(snapshot)
        if !eligible {
            task?.cancel()
        } else if !wasEligible {
            failedKey = nil
            retryCount = 0
            prepareCacheIfNeeded()
            schedule(after: debounce)
        }
    }

    private func discardEvidence() {
        evidence = nil
        evidenceKey = nil
    }

    private static func persistedModelKey(_ input: Input) -> String {
        "\(input.snapshot?.isEnabled == true)|\(input.snapshot?.isVisualSearchEnabled == true)|"
            + SmartSearchDiscoveryModel.visualEvidenceKey(
                timelineRevision: 0, snapshot: input.snapshot, indexingKey: "persisted")
    }

    private struct PreparedCache: Sendable {
        let fingerprint: Data
        let saved: SmartSearchDiscoveryPersistence?
        let snapshot: SmartSearchDiscoveryModel.PersistedSnapshot?
        let exact: Bool
    }

    /// Hydrate saved rows even while Search is active. This performs no inference or geocoding.
    private func prepareCacheIfNeeded() {
        guard cacheTask == nil, let input, input.libraryIsSettled, preparedCacheKey != input.contentKey else { return }
        guard let load = input.cacheAccess, input.sections.contains(where: { !$0.items.isEmpty }) else {
            preparedCacheKey = input.contentKey
            return
        }
        let runtime = runtimeState.snapshot()
        guard runtime.memoryPressure == .normal, runtime.memoryHeadroom < .constrained else { return }
        let owner = cacheGeneration
        let modelKey = Self.persistedModelKey(input)
        cacheTask = Task(priority: .utility) { [weak self] in
            let access = await load()
            let prepared = await SmartSearchDiscoveryModel.background {
                Result { () throws -> PreparedCache in
                    try Task.checkCancellation()
                    let fingerprint = try SmartSearchDiscoveryPersistence.fingerprint(
                        sections: input.sections, favorites: input.favorites, coordinates: input.coordinates)
                    var saved: SmartSearchDiscoveryPersistence?
                    if let data = access?.data {
                        do {
                            let decoded = try PropertyListDecoder().decode(
                                SmartSearchDiscoveryPersistence.self, from: data)
                            if decoded.version == SmartSearchDiscoveryPersistence.version, decoded.modelKey == modelKey,
                                decoded.hasCompleteEvidence
                            {
                                saved = decoded
                            }
                        } catch {
                            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotDecodeFailed")
                        }
                    }
                    try Task.checkCancellation()
                    let exact = saved?.fingerprint == fingerprint
                    return PreparedCache(
                        fingerprint: fingerprint, saved: saved,
                        snapshot: exact ? saved?.snapshot : nil, exact: exact)
                }
            }
            guard let self, owner == self.cacheGeneration, !Task.isCancelled,
                self.input?.contentKey == input.contentKey
            else { return }
            self.cacheTask = nil
            self.preparedCacheKey = input.contentKey
            // Do not retain a second copy of the serialized payload alongside the decoded rows.
            self.cacheAccess = access.map { MLSearchSuggestionCacheAccess(data: nil, save: $0.save) }
            switch prepared {
            case .success(let prepared):
                self.contentFingerprint = prepared.fingerprint
                if let saved = prepared.saved {
                    self.discovery.restorePlaceNames(from: saved.snapshot)
                    if let snapshot = prepared.snapshot {
                        self.discovery.restore(
                            snapshot,
                            content: SmartSearchContentIdentity(
                                timelineRevision: input.revision, favoriteUIDs: input.favorites),
                            isExactContent: prepared.exact)
                    }
                    let runtime = self.runtimeState.snapshot()
                    if runtime.memoryPressure == .normal, runtime.memoryHeadroom < .constrained {
                        self.evidence = saved.evidence
                        self.evidenceKey = saved.evidence == nil ? nil : input.visualKey
                    }
                    if prepared.exact { self.completedKey = input.contentKey }
                    PhotoDiagnostics.shared.increment("ml.suggestions.snapshotRestored")
                }
            case .failure(let error):
                if !(error is CancellationError) {
                    PhotoDiagnostics.shared.increment("ml.suggestions.snapshotPreparationFailed")
                }
            }
            self.schedule(after: self.debounce)
        }
    }

    private func persistCompletedSuggestions(_ input: Input) async {
        guard let access = cacheAccess, let fingerprint = contentFingerprint,
            let snapshot = discovery.persistedSnapshot(), !Task.isCancelled,
            self.input?.contentKey == input.contentKey
        else { return }
        let saved = SmartSearchDiscoveryPersistence(
            version: SmartSearchDiscoveryPersistence.version, modelKey: Self.persistedModelKey(input),
            fingerprint: fingerprint, snapshot: snapshot,
            evidence: evidenceKey == input.visualKey ? evidence : nil)
        let encoded = await SmartSearchDiscoveryModel.background { Result { try saved.encoded() } }
        guard !Task.isCancelled, self.input?.contentKey == input.contentKey else { return }
        do {
            try await access.save(encoded.get())
        } catch is CancellationError {
            return
        } catch MLSmartSearchQueryError.staleEpoch {
            // The lifecycle or index changed. A later valid refresh obtains a fresh write lease.
            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotWriteSuperseded")
        } catch {
            PhotoDiagnostics.shared.increment("ml.suggestions.snapshotWriteFailed")
        }
    }

    private func schedule(after delay: Duration) {
        guard task == nil, eligible, let input, completedKey != input.contentKey, failedKey != input.key else { return }
        guard input.cacheAccess == nil || preparedCacheKey == input.contentKey else { return }
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
            guard current.contentKey == self.input?.contentKey else {
                self.schedule(after: self.debounce)
                return
            }
            if succeeded {
                self.completedKey = current.contentKey
            } else if current.key != self.input?.key {
                self.schedule(after: self.debounce)
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
        model.reusePlaceNames(from: previous)
        let covered = await input.indexedAssetCount()
        guard !Task.isCancelled else { return false }
        // Publish local metadata first. Place-name requests must not delay the evidence gate and previews.
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: nil, includeVisualConcepts: false,
            metadataOnly: SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot)
        )
        guard !Task.isCancelled else { return false }
        guard SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot), covered > 0,
            let searchEvidence = input.searchEvidence
        else {
            if !SmartSearchDiscoveryModel.visualConceptsAvailable(input.snapshot)
                || !previous.forYou.contains(where: { $0.kind == .concept })
            {
                discovery = model
                await persistCompletedSuggestions(input)
            }
            return true
        }
        if evidenceKey != input.visualKey {
            do {
                let fresh = try await searchEvidence()
                guard !Task.isCancelled, self.input?.visualKey == input.visualKey,
                    SmartSearchDiscoveryModel.visualConceptsAvailable(self.input?.snapshot),
                    Self.permitsRefresh(runtimeState.snapshot()), self.input?.libraryIsSettled == true
                else { return false }
                evidence = fresh
                evidenceKey = input.visualKey
            } catch is CancellationError {
                return false
            } catch {
                PhotoDiagnostics.shared.increment("ml.suggestions.evidenceBatchFailed")
                return false
            }
        }
        guard let evidence else { return false }
        let matchesByPrompt = Dictionary(
            uniqueKeysWithValues: evidence.results.map { ($0.queryText, $0.results.map(\.uid)) })
        let replacesEmptyPreviews = !previous.forYou.contains {
            !$0.representativeUIDs.isEmpty || $0.kind == .concept
        }
        await model.refresh(
            sections: input.sections, timelineRevision: input.revision, favoriteUIDs: input.favorites,
            coordinates: input.coordinates, snapshot: input.snapshot, indexedAssetCount: { covered },
            search: { prompt, limit in
                guard let matches = matchesByPrompt[prompt] else { throw MLSmartSearchQueryError.unavailable }
                return Array(matches.prefix(max(0, limit)))
            },
            allowsRepresentative: { evidence.scannedUIDs.contains($0) },
            previewsDidPublish: {
                // First usable metadata or concept previews need not wait for geocoding. Preserve an already useful publication.
                guard replacesEmptyPreviews, !Task.isCancelled, self.input?.contentKey == input.contentKey,
                    Self.permitsRefresh(self.runtimeState.snapshot()),
                    model.forYou.contains(where: { !$0.representativeUIDs.isEmpty })
                else { return }
                self.discovery = model
            }
        )
        guard !Task.isCancelled, model.lastRefreshCompleted else { return false }
        discovery = model
        await persistCompletedSuggestions(input)
        return true
    }

    deinit {
        task?.cancel()
        observer?.cancel()
        cacheTask?.cancel()
    }
}
