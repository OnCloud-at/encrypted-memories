import Foundation
import MLSearchCore
import PhotosCore
import Testing
import TimelineCore

@testable import MLSearchFeature

@MainActor @Suite struct SmartSearchDiscoverySchedulerTests {
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
