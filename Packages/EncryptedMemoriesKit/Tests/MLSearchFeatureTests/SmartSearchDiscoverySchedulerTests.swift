import Foundation
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchCore
@testable import MLSearchFeature

@MainActor @Suite struct SmartSearchDiscoverySchedulerTests {
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
        func apply(_ scheduler: SmartSearchDiscoveryScheduler, revision: UInt64) {
            scheduler.update(
                sections: sections, timelineRevision: revision, favoriteUIDs: favorites, coordinates: [],
                snapshot: visualSnapshot(settled: itemCount, ready: true), indexedAssetCount: { itemCount },
                searchEvidence: { await probe.query(sensitive: items[0].uid, scanned: Set(items.map(\.uid))) },
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
        apply(relaunched, revision: 1)
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
        func access() -> MLSearchSuggestionCacheAccess {
            MLSearchSuggestionCacheAccess(data: data) { data in await self.save(data) }
        }
        func save(_ data: Data) { self.data = data }
    }

    @Test(arguments: ["unsettled", "favorites", "missingGate"])
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
                searchEvidence: { await probe.query(sensitive: items[0].uid) }, libraryIsSettled: settled,
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
        apply(next, favorites: favorites, settled: change != "unsettled")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!next.discovery.hasComputed, "unsettled or different content must not become a current saved snapshot")
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

    @Test func unindexedFavoriteCannotBecomeAPartialIndexPreview() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let items = (0..<8).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date().addingTimeInterval(Double($0)),
                mediaType: "image/jpeg")
        }
        let scanned = Set(items.prefix(2).map(\.uid))
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
            timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
            snapshot: visualSnapshot(settled: 2, ready: false), indexedAssetCount: { 2 },
            searchEvidence: {
                EvidenceProbe.evidence(sensitive: [], scanned: scanned)
            })
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        let previews = Set(scheduler.discovery.forYou.flatMap(\.representativeUIDs))
        #expect(!previews.isEmpty)
        #expect(previews.isSubset(of: scanned))
        #expect(
            scheduler.discovery.forYou.first(where: { $0.kind == .favorites })?.matchingUIDs?.contains(items[7].uid)
                == true)
    }

    @Test func semanticCompletionRefreshesWhileNativeIndexStillWaits() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        func update(complete: Bool) {
            let snapshot = MLSmartSearchSnapshot(
                isEnabled: true, isVisualSearchEnabled: true, selectedModelID: nil,
                phase: complete
                    ? .ready(MLIndexCoverage(total: 100, indexed: 100, permanentlyUnindexable: 0))
                    : .waiting(MLIndexCoverage(total: 100, indexed: 40, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true,
                indexingState: .waiting(
                    MLSmartSearchAggregateProgress(
                        totalWorkUnits: 200, settledWorkUnits: 140, permanentlyUnavailableAssets: 0)))
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: snapshot, indexedAssetCount: { complete ? 100 : 40 },
                searchEvidence: { await probe.query(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive")) })
        }
        update(complete: false)
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted { try await Task.sleep(for: .milliseconds(5)) }
        update(complete: true)
        for _ in 0..<200 where await probe.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 2)
    }

    @Test func indexProgressRearmsAnExhaustedFailureWithoutPolling() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        await probe.failNext(4)
        func update(settled: Int) {
            scheduler.update(
                sections: [], timelineRevision: 1, favoriteUIDs: [], coordinates: [],
                snapshot: visualSnapshot(settled: settled, ready: false), indexedAssetCount: { settled },
                searchEvidence: {
                    try await probe.retryableQuery(sensitive: PhotoUID(volumeID: "v", nodeID: "sensitive"))
                })
        }
        update(settled: 10)
        for _ in 0..<1_800 where await probe.calls < 4 || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.calls == 4)
        update(settled: 20)
        for _ in 0..<200 where await probe.calls < 5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.calls == 5)
        for _ in 0..<200 where scheduler.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(scheduler.discovery.lastRefreshCompleted)
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

    @Test func partialIndexPublishesSafePreviewsWithoutWaitingForEveryPipeline() async throws {
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
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
        let previews = scheduler.discovery.forYou.flatMap(\.representativeUIDs)
        #expect(!previews.isEmpty)
        #expect(!previews.contains(sensitive))
        #expect(scheduler.discovery.lastRefreshCompleted)
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
            for _ in 0..<200 where !scheduler.discovery.hasComputed || scheduler.isRefreshing {
                try await Task.sleep(for: .milliseconds(5))
            }
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

    @Test func firstSearchableCoverageRefreshesEvenWhenAggregateStateWasAlreadyReady() async throws {
        let scheduler = SmartSearchDiscoveryScheduler(runtimeState: LibraryRuntimeState(), debounce: .zero) { _, _ in
            nil
        }
        defer { scheduler.reset() }
        let probe = EvidenceProbe()
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        let sensitive = items[0].uid
        func update(covered: Int) {
            scheduler.update(
                sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)],
                timelineRevision: 1, favoriteUIDs: Set(items.map(\.uid)), coordinates: [],
                snapshot: visualSnapshot(settled: covered, ready: true), indexedAssetCount: { covered },
                searchEvidence: { await probe.query(sensitive: sensitive) })
        }
        update(covered: 0)
        for _ in 0..<200 where !scheduler.discovery.hasComputed || scheduler.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 0)
        update(covered: 8)
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 1)
        #expect(!scheduler.discovery.forYou.flatMap(\.representativeUIDs).isEmpty)
    }

    @Test func partialCoverageProgressReusesEvidenceUntilIndexCompletion() async throws {
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
        for _ in 0..<200 where !scheduler.discovery.lastRefreshCompleted {
            try await Task.sleep(for: .milliseconds(5))
        }
        update(settled: 55, ready: false, revision: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.calls == 1)
        update(settled: 100, ready: true, revision: 1)
        for _ in 0..<200 where await probe.calls < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls == 2)
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
        update(scheduler, revision: 1)
        for _ in 0..<200 where scheduler.discovery.settledContent == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = scheduler.discovery
        let rows = original.forYou
        let items = (0..<8).map {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        scheduler.update(
            sections: [TimelineSection(id: "all", date: Date(), title: "", items: items)], timelineRevision: 2,
            favoriteUIDs: [],
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
