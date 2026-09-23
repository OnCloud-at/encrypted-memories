import Foundation
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchCore
@testable import MLSearchFeature

@MainActor @Suite struct SmartSearchDiscoverySchedulerTests {
    @Test(arguments: [
        "selection", "missingModel", "download", "modelFailure", "nativeFailure", "nativePartialFailure",
        "nativeOnlyFailure",
    ])
    func blockedIndexPublishesOnlyMetadataAndRecovers(state: String) async throws {
        let failure = MLSmartSearchFailure(kind: .storage, isRetryable: true, debugDescription: "fixture")
        let complete = visualSnapshot(settled: 8, ready: true)
        let phase: MLSmartSearchPhase
        switch state {
        case "selection": phase = .selectingModel
        case "missingModel": phase = .notInstalled(downloadable: false)
        case "download": phase = .downloading(MLModelTransferProgress(bytesReceived: 0, totalBytes: 100))
        case "modelFailure": phase = .failed(failure)
        case "nativePartialFailure":
            phase = .indexing(
                MLIndexProgress(
                    phase: .indexing, descriptor: .init(identifier: "fixture", version: 1, embeddingDimension: 3),
                    totalAssets: 8, indexed: 4))
        case "nativeOnlyFailure": phase = .disabled
        default: phase = complete.phase
        }
        let blocked = MLSmartSearchSnapshot(
            isEnabled: true, isVisualSearchEnabled: state != "nativeOnlyFailure", selectedModelID: nil, phase: phase,
            installedModelBytes: 0, availableModels: [], isSearchAvailable: false,
            indexingState: state.hasPrefix("native") ? .failed(failure) : .idle)
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { scheduler.reset() }
        func apply(_ snapshot: MLSmartSearchSnapshot, librarySettled: Bool = true) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)),
                coordinates: items.map {
                    PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
                }, snapshot: snapshot, indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) },
                libraryIsSettled: librarySettled, cacheAccess: { await cache.access() })
        }
        apply(blocked, librarySettled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed, "thumbnail and initial library work retain priority")
        apply(blocked)
        for _ in 0..<200 where !scheduler.discovery.hasComputed || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!scheduler.discovery.forYou.isEmpty, "a blocked model must not hide local metadata forever")
        #expect(scheduler.discovery.forYou.allSatisfy { $0.kind != .concept })
        if blocked.isVisualSearchEnabled {
            #expect(scheduler.discovery.forYou.allSatisfy { $0.representativeUIDs.isEmpty })
        }
        #expect(await probe.calls == 0, "metadata fallback must not scan embeddings")
        #expect(await probe.placeCalls == 0, "metadata fallback must not start geocoding")
        #expect(await cache.saves == 0, "partial metadata must not replace the completed encrypted collection")
        apply(complete)
        for _ in 0..<200 where await cache.saves == 0 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1, "recovery must run full curation even when coverage was already complete")
        #expect(await cache.saves == 1)
        #expect(!scheduler.discovery.forYou.flatMap(\.representativeUIDs).isEmpty)
    }

    @Test func missingModelStillYieldsToActiveNativeIndexing() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: [item])],
            timelineRevision: 1, favoriteUIDs: [item.uid], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil,
                phase: .notInstalled(downloadable: false), installedModelBytes: 0, availableModels: [],
                isSearchAvailable: false,
                indexingState: .indexing(
                    MLSmartSearchAggregateProgress(
                        totalWorkUnits: 100, settledWorkUnits: 1, permanentlyUnavailableAssets: 0))),
            indexedAssetCount: { 0 }, searchEvidence: nil)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed)
    }

    @Test func unknownContentCannotGenerateWithoutACacheProvider() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: [item])],
            timelineRevision: 1, favoriteUIDs: [], coordinates: [], snapshot: .disabled,
            indexedAssetCount: { 0 }, searchEvidence: nil, cacheContentIsSettled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!scheduler.discovery.hasComputed, "unknown favorites are not an authoritative empty set")
    }

    @Test func unknownContentCancelsAnInFlightEvidenceScan() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = CancellationProbe()
        func apply(settled: Bool) {
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { try await probe.wait() }, cacheContentIsSettled: settled)
        }
        apply(settled: true)
        for _ in 0..<200 where !(await probe.started) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await probe.started)
        apply(settled: false)
        for _ in 0..<200 where !(await probe.cancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.cancelled, "losing content authority must stop work before publication or persistence")
    }

    @Test(arguments: [false, true]) func unknownFavoritesPreserveTheSavedCollectionUntilRecovery(
        knownEmpty: Bool
    ) async throws {
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let favorites: Set<PhotoUID> = knownEmpty ? [] : Set(items.map(\.uid))
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, known: Bool) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: known ? favorites : [], coordinates: [], snapshot: .disabled,
                indexedAssetCount: { 0 }, searchEvidence: nil, cacheContentIsSettled: known,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, known: true)
        for _ in 0..<200 where await cache.saves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(await cache.data)
        let expected = first.discovery.forYou
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, known: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!second.discovery.hasComputed)
        #expect(await cache.data == original)
        #expect(await cache.saves == 1)
        apply(second, known: true)
        for _ in 0..<200 where !second.discovery.hasComputed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(second.discovery.hasComputed, "a successful empty favorite response is still authoritative")
        #expect(second.discovery.forYou == expected)
        #expect(await cache.data == original)
        #expect(await cache.saves == 1, "recovery must restore, not replace, the saved collection")
    }

    @Test(arguments: [false, true]) func invalidRowsDisappearEvenWhenRefreshIsBlocked(policyChange: Bool) async throws {
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let runtime = LibraryRuntimeState()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: policyChange ? .disabled : visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!scheduler.discovery.forYou.isEmpty)
        runtime.update { $0.activeSearchCount = 1 }
        let remaining = policyChange ? items : []
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: remaining)],
            timelineRevision: policyChange ? 1 : 2, favoriteUIDs: Set(remaining.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 }, searchEvidence: nil,
            libraryIsSettled: false)
        #expect(
            scheduler.discovery.forYou.isEmpty,
            "deletions and a newly enabled sensitive policy invalidate old rows before background work")
        #expect(scheduler.discovery.chips.isEmpty)
    }

    @Test func emptyLibraryRemovesPreviouslyPublishedConcepts() async throws {
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: items[0].uid, conceptUIDs: items.map(\.uid)) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(scheduler.discovery.forYou.contains { $0.kind == .concept })
        scheduler.update(
            sections: [], timelineRevision: 2, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 0, ready: true), indexedAssetCount: { 0 }, searchEvidence: nil)
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.forYou.isEmpty)
        #expect(scheduler.discovery.chips.isEmpty)
    }

    @Test func changedInventoryCannotReuseEvidenceFromAnotherSuggestionScope() async throws {
        let cache = SnapshotCache()
        let probe = EvidenceProbe()
        let items = (0..<9).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, count: Int) {
            let current = Array(items.prefix(count))
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: current)],
                timelineRevision: 1, favoriteUIDs: Set(current.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: 9, ready: true), indexedAssetCount: { 9 },
                searchEvidence: { await probe.query(sensitive: items[0].uid, scanned: Set(current.map(\.uid))) },
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, count: 8)
        for _ in 0..<200 where await cache.saves < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.saves == 1)
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, count: 9)
        for _ in 0..<200 where await cache.saves < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(
            await probe.calls == 2,
            "a changed library scope needs fresh evidence even when the model index is unchanged")
    }

    @Test func sameCountLocationReplacementUpdatesSuggestions() async throws {
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) {
            latitude, _ in
            latitude > 45 ? "Vienna" : "Rome"
        }
        defer { scheduler.reset() }
        func apply(latitude: Double, coordinateRevision: Int) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: [],
                coordinates: items.map {
                    PhotoCoordinate(uid: $0.uid, latitude: latitude, longitude: 16, date: $0.captureTime)
                }, snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                coordinateRevision: coordinateRevision)
        }
        apply(latitude: 48, coordinateRevision: 1)
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(scheduler.discovery.forYou.contains { $0.title == "Vienna" })
        apply(latitude: 42, coordinateRevision: 2)
        for _ in 0..<200 where !scheduler.discovery.forYou.contains(where: { $0.title == "Rome" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.forYou.contains { $0.title == "Rome" })
        #expect(!scheduler.discovery.forYou.contains { $0.title == "Vienna" })
    }

    @Test func metadataSuggestionsSurviveRelaunchWithoutVisualEvidence() async throws {
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, reversed: Bool) {
            scheduler.update(
                sections: [
                    TimelineSection(id: "all", date: Date(), title: "", items: reversed ? items.reversed() : items)
                ],
                timelineRevision: reversed ? 1 : 50, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, reversed: false)
        for _ in 0..<200 where await cache.data == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.data != nil)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let second = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second, reversed: true)
        for _ in 0..<200 where !second.discovery.hasComputed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(second.discovery.forYou == expected)
        #expect(await cache.saves == 1, "restoration must not regenerate the collection")
    }

    @Test func retiredCacheReadCannotPublishAndReacquiresAuthority() async throws {
        let cache = SnapshotCache()
        let item = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(), mediaType: "image/jpeg")
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: [item])]
        func apply(_ scheduler: SmartSearchDiscoveryScheduler) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: [item.uid], coordinates: [],
                snapshot: .disabled, indexedAssetCount: { 0 }, searchEvidence: nil,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first)
        for _ in 0..<200 where await cache.saves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.saves == 1)
        first.reset()
        await cache.retireNextRead()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let second = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { second.reset() }
        apply(second)
        for _ in 0..<200 where await cache.reads < 3 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await cache.reads == 3, "retired authority must be reacquired")
        #expect(!second.discovery.hasComputed, "retired bytes must never become visible")
        runtime.update { $0.activeSearchCount = 0 }
        for _ in 0..<200 where await cache.saves < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cache.saves == 2, "the current lease must still permit a fresh completed snapshot")
        #expect(second.discovery.hasComputed)
    }

    @Test func contentFingerprintIgnoresTimelineOrderingButDetectsDeletion() throws {
        let now = Date()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: now, mediaType: "image/jpeg")
        }
        func fingerprint(_ items: [PhotoItem]) throws -> Data {
            try SmartSearchDiscoveryPersistence.fingerprint(
                sections: [TimelineSection(id: "all", date: now, title: "", items: items)],
                favorites: [], coordinates: [], now: now)
        }
        #expect(try fingerprint(items) == fingerprint(items.reversed()))
        #expect(try fingerprint(items) != fingerprint(Array(items.dropLast())))
    }

    @Test func learnedVideoDurationDoesNotInvalidateSavedSuggestions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = PhotoItem(uid: .init(volumeID: "v", nodeID: "video"), captureTime: now, mediaType: "video/mp4")
        #expect(store.save([item]).succeeded)
        #expect(store.updateDurations([item.uid: 42.75]).succeeded)
        #expect(store.save([item]).succeeded)
        let restored = store.load()
        #expect(restored.first?.durationSeconds == 42.75)
        func fingerprint(_ items: [PhotoItem]) throws -> Data {
            try SmartSearchDiscoveryPersistence.fingerprint(
                sections: [TimelineSection(id: "all", date: now, title: "", items: items)], favorites: [],
                coordinates: [], now: now)
        }
        #expect(
            try fingerprint(restored) == fingerprint([item]),
            "learned playback duration is absent from server rows and irrelevant to suggestions")
    }

    @Test(arguments: [0, 55]) func waitingWithCompletedWorkCanGenerateSuggestions(deferred: Int) async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let coverage = MLIndexCoverage(total: 100, indexed: 100, permanentlyUnindexable: 0)
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: 200, settledWorkUnits: 200 - deferred, permanentlyUnavailableAssets: 0,
            deferredWorkUnits: deferred)
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil, phase: .waiting(coverage),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true, indexingState: .waiting(progress)),
            indexedAssetCount: { 100 },
            searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        for _ in 0..<200 where await probe.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 1, "waiting is not active indexing and must not indefinitely suppress suggestions")
        // A retry quantum must not discard completed evidence or regenerate the same collection.
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil, phase: .waiting(coverage),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true, indexingState: .indexing(progress)
            ),
            indexedAssetCount: { 100 },
            searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 1)
    }

    @Test(arguments: [8, 50_000], [false, true]) func relaunchRestoresSuggestionsWhileSearchIsAlreadyActive(
        itemCount: Int, recoveringMemoryPressure: Bool
    ) async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<itemCount).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: String(format: "%064d", $0)), captureTime: Date(),
                mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let favorites = Set(items.map(\.uid))
        func apply(
            _ scheduler: SmartSearchDiscoveryScheduler, revision: UInt64,
            libraryIsSettled: Bool = true
        ) {
            scheduler.update(
                sections: sections, timelineRevision: revision, favoriteUIDs: favorites, coordinates: [],
                snapshot: visualSnapshot(settled: itemCount, ready: true), indexedAssetCount: { itemCount },
                searchEvidence: { await probe.query(sensitive: items[0].uid, scanned: Set(items.map(\.uid))) },
                libraryIsSettled: libraryIsSettled, cacheContentIsSettled: true,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, revision: 50)
        for _ in 0..<6_000 where !first.discovery.lastRefreshCompleted || first.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(first.discovery.lastRefreshCompleted)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        if recoveringMemoryPressure { runtime.update { $0.memoryPressure = .critical } }
        let relaunched = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { relaunched.reset() }
        let restoreStarted = ContinuousClock.now
        apply(relaunched, revision: 1, libraryIsSettled: false)
        if recoveringMemoryPressure {
            try await Task.sleep(for: .milliseconds(25))
            #expect(!relaunched.discovery.hasComputed)
            runtime.update { $0.memoryPressure = .normal }
        }
        for _ in 0..<6_000 where !relaunched.discovery.hasComputed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            relaunched.discovery.forYou == expected, "relaunch must preserve completed suggestions without inference")
        #expect(relaunched.discovery.computedContent?.timelineRevision == 1)
        #expect(await probe.calls == 1, "opening Search must not require another full index scan")
        #expect(!relaunched.isRefreshing)
        let bytes = await cache.data?.count ?? 0
        #expect(bytes < 64 * 1_024 * 1_024)
        if itemCount == 50_000 {
            print("Suggestion cache fixture: assets=50000 bytes=\(bytes) restore=\(restoreStarted.duration(to: .now))")
        }
    }

    private actor SnapshotCache {
        var data: Data?
        var failuresRemaining = 0
        var saves = 0
        var reads = 0
        var retiresNextRead = false
        func retireNextRead() { retiresNextRead = true }
        func failNextSave(count: Int = 1) { failuresRemaining = count }
        func access() -> MLSearchSuggestionCacheAccess {
            reads += 1
            let current = !retiresNextRead
            retiresNextRead = false
            return MLSearchSuggestionCacheAccess(
                data: data, isCurrent: { current },
                save: { data in
                    await self.noteSave()
                    if await self.takeFailure() { throw CocoaError(.fileWriteUnknown) }
                    await self.save(data)
                })
        }
        private func noteSave() { saves += 1 }
        private func takeFailure() -> Bool {
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        func save(_ data: Data) { self.data = data }
    }

    @Test func indexProgressDoesNotRearmAnExhaustedPersistenceWrite() async throws {
        let cache = SnapshotCache()
        await cache.failNextSave(count: 100)
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        func apply(settled: Int) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: settled, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { await cache.access() })
        }
        apply(settled: 8)
        for _ in 0..<2_000 where await cache.saves < 4 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await cache.saves == 4)
        apply(settled: 20)
        try await Task.sleep(for: .milliseconds(50))
        apply(settled: 40)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cache.saves == 4, "index progress must not renew an exhausted disk-write budget")
        #expect(await probe.calls == 1)
        #expect(scheduler.discovery.hasComputed, "failed persistence must retain usable rows")
    }

    @Test func transientSaveFailureRetriesOnlyPersistenceAndSurvivesRelaunch() async throws {
        let cache = SnapshotCache()
        await cache.failNextSave()
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let coordinates = items.map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: coordinates,
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        apply(first)
        for _ in 0..<200 where await cache.saves == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let publishedModel = first.discovery
        for _ in 0..<500 where await cache.data == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.data != nil, "a transient disk failure must not finalize an unsaved presentation")
        #expect(await cache.saves == 2)
        #expect(first.discovery === publishedModel, "a persistence retry must not rebuild suggestion rows")
        let expected = first.discovery.forYou
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { next.reset() }
        apply(next)
        for _ in 0..<200 where !next.discovery.hasComputed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.forYou == expected)
        #expect(await probe.calls == 1)
        #expect(await probe.placeCalls == 1)
        #expect(!next.discovery.showsVisualSuggestionsPendingNote(visualSnapshot(settled: 0, ready: false)))
    }

    @Test func relaunchRetriesCacheWhenModelStartupFinishesBeforeCoverageRestores() async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let ready = visualSnapshot(settled: 8, ready: true)
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, phase: MLSmartSearchPhase, cacheReady: Bool) {
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: ready.isEnabled, isVisualSearchEnabled: ready.isVisualSearchEnabled,
                selectedModelID: ready.selectedModelID, phase: phase,
                installedModelBytes: ready.installedModelBytes, availableModels: ready.availableModels,
                isSearchAvailable: false, indexingState: cacheReady ? ready.indexingState : .idle)
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: snapshot, indexedAssetCount: { cacheReady ? 8 : 0 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheAccess: { cacheReady ? await cache.access() : nil })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, phase: ready.phase, cacheReady: true)
        for _ in 0..<200 where await cache.data == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await cache.data != nil)
        let expected = first.discovery.forYou
        try #require(expected.contains { !$0.representativeUIDs.isEmpty })
        first.reset()

        let runtime = LibraryRuntimeState()
        let search = runtime.beginActivity(.search)
        defer { search.end() }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { next.reset() }
        apply(next, phase: .preparingModel, cacheReady: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!next.discovery.hasComputed)
        apply(next, phase: .waiting(.init(total: 0, indexed: 0, permanentlyUnindexable: 0)), cacheReady: true)
        for _ in 0..<200 where !next.discovery.hasComputed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.forYou == expected, "saved suggestions must not wait for a new coverage pass")
        #expect(await probe.calls == 1, "restoring completed rows must not rerun their evidence scan")
    }

    @Test(arguments: ["unstableContent", "favorites", "missingGate"])
    func relaunchDoesNotPresentProvisionalOrChangedContentAsCurrent(
        change: String
    ) async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, favorites: Set<PhotoUID>, settled: Bool) {
            scheduler.update(
                sections: sections, timelineRevision: 1, favoriteUIDs: favorites, coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) },
                cacheContentIsSettled: settled,
                cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in nil }
        apply(first, favorites: Set(items.map(\.uid)), settled: true)
        for _ in 0..<200 where !first.discovery.lastRefreshCompleted || first.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(first.discovery.lastRefreshCompleted)
        first.reset()
        let runtime = LibraryRuntimeState()
        runtime.update { $0.activeSearchCount = 1 }
        let next = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { next.reset() }
        let favorites = Set((change == "favorites" ? Array(items.dropFirst()) : items).map(\.uid))
        if change == "missingGate" {
            let data = try #require(await cache.data)
            let saved = try PropertyListDecoder().decode(SmartSearchDiscoveryPersistence.self, from: data)
            let evidence = try #require(saved.evidence)
            let invalid = SmartSearchDiscoveryPersistence(
                version: saved.version, modelKey: saved.modelKey, fingerprint: saved.fingerprint,
                snapshot: saved.snapshot,
                evidence: MLSearchBatchResults(
                    results: Array(evidence.results.dropFirst()), scannedUIDs: evidence.scannedUIDs))
            await cache.save(try invalid.encoded())
        }
        apply(next, favorites: favorites, settled: change != "unstableContent")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!next.discovery.hasComputed, "unstable or different content must not become a current saved snapshot")
        runtime.update { $0.activeSearchCount = 0 }
        apply(next, favorites: favorites, settled: true)
        for _ in 0..<200 where !next.discovery.lastRefreshCompleted || next.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.discovery.lastRefreshCompleted)
        #expect(next.discovery.computedContent?.favoriteCount == favorites.count)
        #expect(await probe.calls == (change == "missingGate" ? 2 : 1))
    }

    @Test func metadataChangeAfterRelaunchReusesVisualEvidenceAndResolvedPlaces() async throws {
        let probe = EvidenceProbe()
        let cache = SnapshotCache()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sections = [TimelineSection(id: "all", date: Date(), title: "", items: items)]
        let coordinates = items.map {
            PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
        }
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, favorites: Set<PhotoUID>, revision: UInt64) {
            scheduler.update(
                sections: sections, timelineRevision: revision, favoriteUIDs: favorites, coordinates: coordinates,
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) }, cacheAccess: { await cache.access() })
        }
        let first = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        apply(first, favorites: Set(items.map(\.uid)), revision: 20)
        for _ in 0..<200 where !first.discovery.lastRefreshCompleted || first.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(first.discovery.lastRefreshCompleted)
        try #require(await probe.placeCalls == 1)
        first.reset()
        let second = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            await probe.placeName()
        }
        defer { second.reset() }
        apply(second, favorites: Set(items.dropFirst().map(\.uid)), revision: 1)
        for _ in 0..<200 where !second.discovery.lastRefreshCompleted || second.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(second.discovery.computedContent?.favoriteCount == 7)
        #expect(await probe.calls == 1, "metadata changes must reuse saved evidence")
        #expect(await probe.placeCalls == 1, "unchanged place cells must not request their names again after relaunch")
    }

    private actor EvidenceProbe {
        var calls = 0
        var placeCalls = 0
        func placeName() -> String {
            placeCalls += 1
            return "Vienna"
        }
        var failuresRemaining = 0
        func failNext(_ count: Int) { failuresRemaining = count }
        func retryableQuery(sensitive: PhotoUID) throws -> MLSearchBatchResults {
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                calls += 1
                throw MLSmartSearchQueryError.unavailable
            }
            return query(sensitive: sensitive)
        }
        nonisolated static func evidence(
            sensitive: [PhotoUID], scanned: Set<PhotoUID>, conceptUIDs: [PhotoUID] = []
        ) -> MLSearchBatchResults {
            let descriptor = MLModelDescriptor(identifier: "fixture", version: 1, embeddingDimension: 3)
            let prompts =
                MLSearchConceptCatalog.sensitivePrompts.map { ($0, sensitive) }
                + MLSearchConceptCatalog.curated.map { ($0.prompt, conceptUIDs) }
            return MLSearchBatchResults(
                results: prompts.map { prompt, uids in
                    MLSearchResults(
                        descriptor: descriptor, queryText: prompt,
                        results: uids.map { MLSearchResult(uid: $0, score: 1) })
                }, scannedUIDs: MLScannedUIDMembership(scanned))
        }
        func query(
            sensitive: PhotoUID, conceptUIDs: [PhotoUID] = [], scanned: Set<PhotoUID>? = nil
        ) -> MLSearchBatchResults {
            calls += 1
            return Self.evidence(
                sensitive: [sensitive],
                scanned: scanned ?? Set((0..<8).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }),
                conceptUIDs: conceptUIDs)
        }
    }

    @Test(arguments: [false, true]) func evidenceIsReleasedOnMemoryPressureOrVisualDisablement(
        disableVisual: Bool
    ) async throws {
        let runtime = LibraryRuntimeState()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        func apply(visual: Bool, favorites: Set<PhotoUID>) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: favorites, coordinates: [],
                snapshot: visual ? visualSnapshot(settled: 8, ready: true) : nil,
                indexedAssetCount: { visual ? 8 : 0 },
                searchEvidence: { await probe.query(sensitive: items[0].uid) })
        }
        let favorites = Set(items.map(\.uid))
        apply(visual: true, favorites: favorites)
        for _ in 0..<200 where scheduler.cachedEvidenceAssetCount == 0 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheduler.cachedEvidenceAssetCount == 8)
        let originalRows = scheduler.discovery.forYou
        if disableVisual {
            apply(visual: false, favorites: favorites)
        } else {
            runtime.update { $0.memoryPressure = .critical }
        }
        for _ in 0..<200 where scheduler.cachedEvidenceAssetCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.cachedEvidenceAssetCount == 0)
        if !disableVisual { #expect(scheduler.discovery.forYou == originalRows) }
        runtime.update { $0.memoryPressure = .normal }
        apply(visual: true, favorites: Set(items.dropFirst().map(\.uid)))
        for _ in 0..<200 where await probe.calls < 2 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 2, "a later content refresh must rebuild evicted evidence")
        #expect(!scheduler.discovery.forYou.flatMap(\.representativeUIDs).contains(items[0].uid))
    }

    @Test func startupRevisionsWaitForLibraryWorkAndCoalesceBeforeEvidence() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        func apply(revision: UInt64, settled: Bool) {
            scheduler.update(
                sections: [], timelineRevision: revision, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "0")) },
                libraryIsSettled: settled)
        }
        apply(revision: 1, settled: false)
        try await Task.sleep(for: .milliseconds(25))
        apply(revision: 2, settled: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0, "startup must retain its CPU, model and cache budget")
        #expect(!scheduler.isRefreshing)
        apply(revision: 2, settled: true)
        for _ in 0..<200 where await probe.calls == 0 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }

    @Test func replacedRevisionCancelsItsAutomaticEvidenceBeforeCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = CancellationProbe()
        scheduler.update(
            sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { try await probe.wait() })
        for _ in 0..<200 where !(await probe.started) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await probe.started)
        scheduler.update(
            sections: [], timelineRevision: 2, favoriteUIDs: [], coordinates: [],
            snapshot: nil, indexedAssetCount: { 0 }, searchEvidence: nil)
        for _ in 0..<200 where !(await probe.cancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.cancelled, "a superseded scan must stop rather than run to completion")
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }

    private actor CancellationProbe {
        var started = false
        var cancelled = false
        func wait() async throws -> MLSearchBatchResults {
            started = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = true
                throw error
            }
            return MLSearchBatchResults(results: [], scannedUIDs: [])
        }
    }

    @Test func semanticCompletionWaitsForNativeIndexCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        func update(semanticComplete: Bool, aggregateReady: Bool) {
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil,
                phase: semanticComplete
                    ? .ready(MLIndexCoverage(total: 100, indexed: 100, permanentlyUnindexable: 0))
                    : .waiting(MLIndexCoverage(total: 100, indexed: 40, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: aggregateReady
                    ? .ready(
                        MLSmartSearchAggregateProgress(
                            totalWorkUnits: 200, settledWorkUnits: 200, permanentlyUnavailableAssets: 0))
                    : .waiting(
                        MLSmartSearchAggregateProgress(
                            totalWorkUnits: 200, settledWorkUnits: 140, permanentlyUnavailableAssets: 0)))
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: snapshot, indexedAssetCount: { semanticComplete ? 100 : 40 },
                searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        }
        update(semanticComplete: false, aggregateReady: false)
        try await Task.sleep(for: .milliseconds(25))
        update(semanticComplete: true, aggregateReady: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0, "semantic completion must not compete with native indexing")
        #expect(!scheduler.discovery.hasComputed)
        update(semanticComplete: true, aggregateReady: true)
        for _ in 0..<200 where await probe.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 1)
    }

    private func visualSnapshot(settled: Int, ready: Bool) -> MLSmartSearchSnapshot {
        let total = ready ? settled : 100
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: total, settledWorkUnits: settled, permanentlyUnavailableAssets: 0)
        let coverage = MLIndexCoverage(total: total, indexed: settled, permanentlyUnindexable: 0)
        return MLSmartSearchSnapshot(
            isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil,
            phase: ready ? .ready(coverage) : .waiting(coverage),
            installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
            indexingState: ready ? .ready(progress) : .waiting(progress))
    }

    @Test func partialIndexWaitsForEveryEnabledPipeline() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 8, ready: false), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive) })
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0)
        #expect(!scheduler.discovery.hasComputed)
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 100, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive) })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
    }

    @Test(arguments: [false, true], [false, true]) func slowPlaceNamesDoNotDelaySafeMetadataPreviews(
        startsWithoutCoverage: Bool, hasMetadataRows: Bool
    ) async throws {
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            didEnter.yield()
            for await _ in release { break }
            return "Vienna"
        }
        defer {
            doRelease.finish()
            didEnter.finish()
            scheduler.reset()
        }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        if startsWithoutCoverage {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: hasMetadataRows ? Set(items.map(\.uid)) : [], coordinates: [],
                snapshot: visualSnapshot(settled: 0, ready: false), indexedAssetCount: { 0 },
                searchEvidence: { await probe.query(sensitive: sensitive, conceptUIDs: items.map(\.uid)) })
            try await Task.sleep(for: .milliseconds(25))
            #expect(await probe.calls == 0)
            #expect(!scheduler.discovery.hasComputed)
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: hasMetadataRows ? Set(items.map(\.uid)) : [],
            coordinates: items.map {
                PhotoCoordinate(uid: $0.uid, latitude: 48.2, longitude: 16.3, date: $0.captureTime)
            },
            snapshot: visualSnapshot(settled: 100, ready: true), indexedAssetCount: { 8 },
            searchEvidence: { await probe.query(sensitive: sensitive, conceptUIDs: items.map(\.uid)) })
        for await _ in entered { break }
        #expect(await probe.calls == 1)
        let previews = scheduler.discovery.forYou.flatMap(\.representativeUIDs)
        #expect(!previews.isEmpty)
        #expect(!previews.contains(sensitive))
    }

    @Test func partialCoverageDoesNotStartEvidenceUntilIndexCompletion() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        func update(settled: Int, ready: Bool, revision: UInt64) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: revision, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: settled, ready: ready), indexedAssetCount: { 8 },
                searchEvidence: { await probe.query(sensitive: sensitive) })
        }
        update(settled: 8, ready: false, revision: 1)
        try await Task.sleep(for: .milliseconds(25))
        update(settled: 55, ready: false, revision: 1)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await probe.calls == 0)
        #expect(!scheduler.discovery.hasComputed)
        update(settled: 100, ready: true, revision: 1)
        for _ in 0..<200 where await probe.calls < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
    }

    private func update(_ scheduler: SmartSearchDiscoveryScheduler, revision: UInt64) {
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: revision, favoriteUIDs: Set(items.map(\.uid)), coordinates: [], smartSearch: nil
        )
    }

    @Test func activeSearchDefersAndCoalescesUpdatesUntilTheUserLeaves() async throws {
        let runtime = LibraryRuntimeState()
        let search = runtime.beginActivity(.search)
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        update(scheduler, revision: 1)
        update(scheduler, revision: 1)
        update(scheduler, revision: 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        #expect(!scheduler.isRefreshing)

        search.end()
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
        #expect(scheduler.discovery.settledGeneration == 1)
        #expect(!scheduler.discovery.forYou.isEmpty)
        update(scheduler, revision: 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(scheduler.discovery.settledGeneration == 1)
    }

    @Test func backgroundAndLowPowerWorkWaitForARealEligibilityChange() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(isLowPowerMode: true))
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in nil }
        defer { scheduler.reset() }
        update(scheduler, revision: 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        runtime.update {
            $0.isLowPowerMode = false
            $0.executionOpportunity = .backgroundPermitted
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!scheduler.discovery.hasComputed)
        runtime.update { $0.executionOpportunity = .foregroundActive }
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.hasComputed)
        scheduler.reset()
        #expect(!scheduler.discovery.hasComputed)
        #expect(scheduler.discovery.forYou.isEmpty)
    }

    @Test func enteringSearchDuringRefreshKeepsTheLastPublishedSuggestionsUsable() async throws {
        let runtime = LibraryRuntimeState()
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: runtime, debounce: .zero) { _, _ in
            didEnter.yield()
            for await _ in release { break }
            return "Vienna"
        }
        defer { scheduler.reset() }
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)], timelineRevision: 1,
            favoriteUIDs: Set(items.map(\.uid)), coordinates: [], smartSearch: nil)
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = scheduler.discovery
        let rows = original.forYou
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)], timelineRevision: 2,
            favoriteUIDs: Set(items.map(\.uid)),
            coordinates: items.map {
                PhotoCoordinate(uid: $0.uid, latitude: 48.2082, longitude: 16.3738, date: $0.captureTime)
            }, smartSearch: nil
        )
        for await _ in entered { break }
        let search = runtime.beginActivity(.search)
        for _ in 0..<200 where scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery === original)
        #expect(scheduler.discovery.computedContent?.timelineRevision == 1)
        #expect(scheduler.discovery.forYou == rows)
        doRelease.yield()
        search.end()
        for _ in 0..<200 where scheduler.discovery.computedContent?.timelineRevision != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.discovery.computedContent?.timelineRevision == 2)
    }
}
