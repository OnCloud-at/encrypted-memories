import CryptoKit
import Foundation
import MediaByteCache
import PhotosCore
import Testing

@testable import MediaFeedCore
@testable import TimelineCore

#if DEBUG
    /// The whole-library thumbnail crawl that the shared timeline model starts: one start per model, new photos through
    /// the incremental update coordinator, no Proton request for an unchanged library and no second request for a photo
    /// whose thumbnail Proton refused. The fixture has no source analysis, so the feed has no source scope; the crawl
    /// restart of `ThumbnailFeedCore.reconcile` for a changed source scope is outside these tests.
    @Suite(.serialized) @MainActor struct WholeLibraryThumbnailCrawlTests {
        @Test(.timeLimit(.minutes(1)))
        func anUnchangedRefreshAsksProtonForNothing() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12)
            let before = await fixture.counts()

            await fixture.refresh()

            let after = await fixture.counts()
            #expect(after.requests == before.requests, "An unchanged library asks Proton for no thumbnail")
            #expect(after.workerStarts == before.workerStarts)
            #expect(after.diskProbes == before.diskProbes)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func anAddedPhotoDoesNotRestartTheWholeLibraryCrawl() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12)
            let before = await fixture.counts()
            let added = crawlItem("added")

            await fixture.library.add(added)
            await fixture.refresh()

            let after = await fixture.counts()
            #expect(after.diskProbes - before.diskProbes <= 1, "Only the new photo is checked on disk, not the library")
            #expect(await fixture.loader.requests(for: added.uid) == 1, "The new photo is requested once")
            #expect(after.requests == before.requests + 1)
            #expect(fixture.cache.hasUsableDiskData(added.uid))
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func theFirstPhotosOfAnEmptyLibraryStartTheWholeLibraryCrawl() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 0)
            let arriving = (0..<3).map { crawlItem("arriving-\($0)") }
            for item in arriving { await fixture.library.add(item) }

            // No hand-off to the update coordinator: only the whole-library crawl can load these thumbnails.
            _ = await fixture.timeline.refreshLibrary()
            try await fixture.waitUntilIdle(expecting: arriving.map(\.uid))

            #expect(
                arriving.allSatisfy { fixture.cache.hasUsableDiskData($0.uid) },
                "An empty start leaves the crawl unused")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aRefusedThumbnailIsNotRequestedAgainByARefresh() async throws {
            let refused = crawlItem("refused")
            let fixture = try await CrawlFixture.loaded(photoCount: 6, extra: [refused], refusing: [refused.uid])
            let refusedRequests = await fixture.loader.requests(for: refused.uid)
            #expect(refusedRequests >= 1)

            await fixture.library.add(crawlItem("added"))
            await fixture.refresh()

            #expect(
                await fixture.loader.requests(for: refused.uid) == refusedRequests,
                "A refresh never asks Proton again for a refused thumbnail")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aPhotoRestoredElsewhereGetsItsThumbnailOnce() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12)
            let restored = crawlItem("restored-elsewhere")

            // Another device restores a photo that this Mac never showed: the next refresh lists it.
            await fixture.library.add(restored)
            await fixture.refresh()

            #expect(fixture.cache.hasUsableDiskData(restored.uid))
            #expect(await fixture.loader.requests(for: restored.uid) == 1)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aPhotoRestoredFromRecentlyDeletedKeepsItsThumbnail() async throws {
            let trashed = crawlItem("trashed")
            let fixture = try await CrawlFixture.loaded(photoCount: 12, trash: [trashed])

            await fixture.timeline.select(.trash)
            try await fixture.waitUntilIdle(expecting: [trashed.uid])
            #expect(fixture.cache.hasUsableDiskData(trashed.uid), "Recently Deleted crawls its own photos")
            await fixture.timeline.commitRestore([trashed])
            await fixture.library.restore(trashed)
            await fixture.timeline.select(.all)
            try await fixture.waitUntilIdle(expecting: fixture.timeline.wholeLibraryUIDs)

            #expect(fixture.timeline.wholeLibraryUIDs.contains(trashed.uid))
            #expect(fixture.cache.hasUsableDiskData(trashed.uid))
            #expect(await fixture.loader.requests(for: trashed.uid) == 1, "The restored photo is not loaded again")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func returningFromARouteResumesTheWholeLibraryCrawl() async throws {
            let late = crawlItem("late")
            let trashed = crawlItem("trashed")
            // The first crawl cannot reach `late`: the loader holds it until the route crawl replaced the crawl.
            let fixture = try await CrawlFixture.loaded(
                photoCount: 4, extra: [late], trash: [trashed], holding: late.uid)

            await fixture.timeline.select(.trash)
            await fixture.loader.releaseHeld()
            try await fixture.waitUntilIdle(expecting: [trashed.uid])
            await fixture.timeline.select(.all)
            try await fixture.waitUntilIdle(expecting: [late.uid])

            #expect(fixture.cache.hasUsableDiskData(late.uid), "All Photos crawls again after another route crawled")
            await fixture.close()
        }

        /// Prints the work of one session: a cold load, an unchanged refresh, five refreshes that each add a photo,
        /// a local trash and restore, and one photo whose thumbnail Proton refuses. The package test log carries the
        /// numbers; the assertions above hold the rule. Without a source scope, these numbers leave out the feed's own
        /// restart for a changed scope.
        @Test(.timeLimit(.minutes(2)))
        func measureTheWorkOfOneSession() async throws {
            let refused = crawlItem("measure-refused")
            let fixture = try await CrawlFixture.loaded(photoCount: 200, extra: [refused], refusing: [refused.uid])
            var rows = ["cold load of 201 photos": await fixture.counts()]
            var previous = rows["cold load of 201 photos"]!

            await fixture.refresh()
            let unchanged = await fixture.counts()
            rows["refresh without change"] = unchanged - previous
            previous = unchanged

            for index in 0..<5 {
                await fixture.library.add(crawlItem("measure-added-\(index)"))
                await fixture.refresh()
            }
            let added = await fixture.counts()
            rows["5 refreshes, each adds a photo"] = added - previous
            previous = added

            let item = fixture.timeline.wholeLibraryItemsForViewer[3]
            await fixture.timeline.commitTrash([item])
            await fixture.timeline.commitRestore([item])
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)
            let trashAndRestore = await fixture.counts()
            rows["trash and restore one photo"] = trashAndRestore - previous

            rows["refused photo, requests in total"] = CrawlCounts(
                requests: await fixture.loader.requests(for: refused.uid))
            for (scenario, counts) in rows.sorted(by: { $0.key < $1.key }) {
                print("CRAWL-MEASURE \(scenario): \(counts)")
            }
            #expect(rows["refresh without change"]!.requests == 0)
            await fixture.close()
        }
    }

    private func crawlItem(_ id: String) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "crawl", nodeID: id), captureTime: Date(timeIntervalSince1970: 1_700_000_000),
            mediaType: "image/jpeg")
    }

    /// `workerStarts` counts every start of the feed workers, also for the update coordinator. A restart of the
    /// whole-library crawl shows in `diskProbes`: it checks every photo of the library on disk again.
    struct CrawlCounts: CustomStringConvertible, Sendable {
        var workerStarts = 0
        var diskProbes = 0
        var requests = 0
        var decodes = 0

        static func - (lhs: CrawlCounts, rhs: CrawlCounts) -> CrawlCounts {
            CrawlCounts(
                workerStarts: lhs.workerStarts - rhs.workerStarts, diskProbes: lhs.diskProbes - rhs.diskProbes,
                requests: lhs.requests - rhs.requests, decodes: lhs.decodes - rhs.decodes)
        }

        var description: String {
            "workerStarts=\(workerStarts) diskProbes=\(diskProbes) requests=\(requests) decodes=\(decodes)"
        }
    }

    /// One shared timeline model with a real feed and an encrypted cache. `refresh()` does what the Mac host does
    /// after a refresh: it hands the added photos to the incremental update coordinator.
    @MainActor private struct CrawlFixture {
        let directory: URL
        let library: CrawlLibrary
        let loader: CountingThumbnails
        let cache: ThumbnailCache
        let feed: ThumbnailFeedCore
        let timeline: TimelineViewModel
        let diagnostics: PhotoDiagnostics
        let probes: ProbeCounter
        let refused: Set<PhotoUID>
        let updates = LibraryThumbnailUpdateCoordinator(policy: .init(pollInterval: .milliseconds(10)))

        static func loaded(
            photoCount: Int, extra: [PhotoItem] = [], trash: [PhotoItem] = [], refusing: Set<PhotoUID> = [],
            holding: PhotoUID? = nil
        ) async throws -> CrawlFixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "whole-library-crawl-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let items = (0..<photoCount).map { crawlItem("photo-\($0)") } + extra
            let library = CrawlLibrary(items: items, trash: trash)
            let loader = CountingThumbnails(refusing: refusing, holding: holding)
            let cache = ThumbnailCache(rootDirectory: directory)
            cache.configure(accountUID: "crawl", key: SymmetricKey(size: .bits256))
            let diagnostics = PhotoDiagnostics()
            let feed = ThumbnailFeedCore(cache: cache, loader: loader, diagnostics: diagnostics)
            let probes = ProbeCounter()
            feed.setDiskProbeHookForTesting { probes.increment() }
            let timeline = TimelineViewModel(repository: library, feed: feed, library: library)
            let fixture = CrawlFixture(
                directory: directory, library: library, loader: loader, cache: cache, feed: feed,
                timeline: timeline, diagnostics: diagnostics, probes: probes, refused: refusing)
            await timeline.load()
            // A held photo blocks its crawl batch, so that test goes on while the first crawl still runs.
            if holding == nil {
                try await fixture.waitUntilIdle(expecting: items.map(\.uid).filter { !refusing.contains($0) })
            }
            return fixture
        }

        func refresh() async {
            let result = await timeline.refreshLibrary()
            updates.reconcile(
                currentUIDs: timeline.wholeLibraryUIDs, addedUIDs: result.addedUIDs,
                resolver: { [feed] uids, enqueueMissing in
                    await feed.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
                })
            try? await waitUntilIdle(expecting: expectedOnDisk)
        }

        /// Every photo of the whole library whose thumbnail Proton does not refuse.
        var expectedOnDisk: [PhotoUID] { timeline.wholeLibraryUIDs.filter { !refused.contains($0) } }

        /// Waits until the expected thumbnails are on disk and the feed, the coordinator and the counters have been
        /// quiet for a quarter second. A crawl start runs after a detached sort, so an empty queue alone proves nothing.
        func waitUntilIdle(expecting expected: [PhotoUID] = []) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            var quietChecks = 0
            var last = (probes: -1, requests: -1)
            while ContinuousClock.now < deadline, quietChecks < 5 {
                let now = (probes: probes.value, requests: await loader.totalRequests)
                let busy = await feed.hasPendingThumbnailWork() || updates.state.isActive
                let stored = expected.allSatisfy { cache.hasUsableDiskData($0) }
                quietChecks = stored && !busy && now == last ? quietChecks + 1 : 0
                last = now
                try await Task.sleep(for: .milliseconds(50))
            }
            try await feed.waitForPrefetchToFinish()
        }

        func counts() async -> CrawlCounts {
            CrawlCounts(
                workerStarts: await feed.workerStartCountForTesting(), diskProbes: probes.value,
                requests: await loader.totalRequests,
                decodes: diagnostics.counter("thumb.ramDecodeStarted"))
        }

        func close() async {
            await feed.stopPrefetchAndWait()
            updates.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// The whole library and Recently Deleted of one account, with no saved timeline.
    private actor CrawlLibrary: PhotosRepository, PhotoLibraryProvider {
        private var items: [PhotoItem]
        private var trash: [PhotoItem]

        init(items: [PhotoItem], trash: [PhotoItem]) {
            self.items = items
            self.trash = trash
        }

        func add(_ item: PhotoItem) { items.append(item) }

        func restore(_ item: PhotoItem) {
            trash.removeAll { $0.uid == item.uid }
            items.append(item)
        }

        func loadTimeline() async throws -> [TimelineSection] { Self.sections(items) }

        func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
            TimelineLoadSnapshot(sections: Self.sections(items), validationToken: "token-\(items.count)")
        }

        func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
            filter == .trash ? Self.sections(trash) : []
        }

        private static func sections(_ items: [PhotoItem]) -> [TimelineSection] {
            items.isEmpty ? [] : [TimelineSection(id: "crawl", date: items[0].captureTime, title: "", items: items)]
        }
    }

    /// Counts every thumbnail request per photo. Refused photos get an item error; a held photo waits for release.
    private actor CountingThumbnails: ThumbnailBatchLoader {
        private let refusing: Set<PhotoUID>
        private var holding: PhotoUID?
        private var held: [CheckedContinuation<Void, Never>] = []
        private var perPhoto: [PhotoUID: Int] = [:]
        private(set) var totalRequests = 0

        init(refusing: Set<PhotoUID>, holding: PhotoUID?) {
            self.refusing = refusing
            self.holding = holding
        }

        func requests(for uid: PhotoUID) -> Int { perPhoto[uid, default: 0] }

        func releaseHeld() {
            holding = nil
            held.forEach { $0.resume() }
            held.removeAll()
        }

        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            var errors: [PhotoUID: String] = [:]
            for uid in uids {
                if uid == holding { await withCheckedContinuation { held.append($0) } }
                perPhoto[uid, default: 0] += 1
                totalRequests += 1
                if refusing.contains(uid) {
                    errors[uid] = "no thumbnail"
                } else {
                    onLoaded(uid, Data("thumbnail-\(uid.nodeID)".utf8))
                }
            }
            return ThumbnailBatchLoadResult(itemErrors: errors)
        }
    }
#endif
