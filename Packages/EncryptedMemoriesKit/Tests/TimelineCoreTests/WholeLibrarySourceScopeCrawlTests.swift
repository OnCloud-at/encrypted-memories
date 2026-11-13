import Foundation
import MediaByteCache
import PhotosCore
import Testing

@testable import MediaFeedCore
@testable import TimelineCore

#if DEBUG
    /// The thumbnail crawl when the whole library also reaches the feed as a source scope, as in the Mac app with
    /// Smart Search. A scope that only grows keeps the crawl: only the new photo is checked and loaded, and a refused
    /// thumbnail is not asked for again. A scope that shrinks, or that turns from cached to authoritative, takes the
    /// full reconciliation path with a fresh crawl.
    @Suite(.serialized) @MainActor struct WholeLibrarySourceScopeCrawlTests {
        @Test(.timeLimit(.minutes(1)))
        func aGrowingSourceScopeChecksAndLoadsOnlyTheNewPhoto() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12, withSources: true)
            let before = await fixture.counts()
            let added = crawlItem("scope-added")

            await fixture.library.add(added)
            await fixture.refresh()

            let after = await fixture.counts()
            // The extended crawl and the host's new-photo update check both look at the new photo. When the update
            // check queues it while the crawl batch still checks the disk, both request it: a known race, so the new
            // photo costs one or two requests, never a crawl of the library.
            #expect(after.diskProbes - before.diskProbes <= 2, "Only the new photo is checked on disk, not the library")
            #expect(await fixture.loader.requests(for: added.uid) <= 2, "The new photo is requested at most twice")
            #expect(after.requests <= before.requests + 2)
            #expect(fixture.cache.hasUsableDiskData(added.uid))
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aGrowingSourceScopeNeverAsksAgainForARefusedThumbnail() async throws {
            let refused = crawlItem("scope-refused")
            let fixture = try await CrawlFixture.loaded(
                photoCount: 6, extra: [refused], refusing: [refused.uid], withSources: true)
            let refusedRequests = await fixture.loader.requests(for: refused.uid)
            #expect(refusedRequests >= 1)

            await fixture.library.add(crawlItem("scope-added"))
            await fixture.refresh()

            #expect(
                await fixture.loader.requests(for: refused.uid) == refusedRequests,
                "A growing scope never asks Proton again for a refused thumbnail")

            // The feed still knows the refusal: a later request for the photo, as from a visible tile, asks nobody.
            await fixture.feed.requestPriority(refused.uid)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)
            #expect(await fixture.loader.requests(for: refused.uid) == refusedRequests)
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aPhotoThatOnlyAnotherSourceAddsJoinsTheRunningCrawl() async throws {
            // No fixture sources and no refresh: the update coordinator never hears of the album photo, so only the
            // crawl can load it.
            let fixture = try await CrawlFixture.loaded(photoCount: 8)
            let graph = LibrarySourceGraph()
            let library = LibrarySource(id: SourceID("crawl-two-sources-library"), capabilities: .readThumbnail)
            let album = LibrarySource(id: SourceID("crawl-two-sources-album"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([library, album], using: graph.beginSourceSetRefresh())
            let bound = await fixture.feed.bindDerivedDataEpoch(graph.runtimeEpoch)
            #expect(bound)
            let first = crawlItem("album-first")
            let libraryItems = fixture.timeline.wholeLibraryItemsForViewer.map(LibrarySourceItem.complete)
            for (source, items) in [(library, libraryItems), (album, [LibrarySourceItem.complete(first)])] {
                let lease = try #require(graph.beginRefresh(source.id))
                let change = try #require(graph.commit(items, validationToken: nil, using: lease))
                _ = await fixture.feed.reconcile(
                    selected: change.selectedScope, analysis: change.analysisScope,
                    retention: change.thumbnailRetentionScope)
            }
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk + [first.uid])
            let before = await fixture.counts()

            let joined = crawlItem("album-joined")
            let lease = try #require(graph.beginRefresh(album.id))
            let change = try #require(
                graph.commit([.complete(first), .complete(joined)], validationToken: nil, using: lease))
            _ = await fixture.feed.reconcile(
                selected: change.selectedScope, analysis: change.analysisScope,
                retention: change.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: [joined.uid])

            let after = await fixture.counts()
            #expect(fixture.cache.hasUsableDiskData(joined.uid), "The crawl loads the photo that the album added")
            #expect(await fixture.loader.requests(for: joined.uid) == 1)
            #expect(after.requests == before.requests + 1)
            #expect(after.diskProbes - before.diskProbes <= 1, "Only the joined photo is checked on disk")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aPhotoBackFromRecentlyDeletedCountsAsALibraryPhotoAgain() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12, withSources: true)
            let sources = try #require(fixture.sources)
            let trashed = crawlItem("scope-trashed")
            // Recently Deleted lists the photo outside the library; the crawl loads its thumbnail last.
            let listing = try #require(sources.graph.setIdentitiesOutsideInventory([trashed.uid]))
            _ = await fixture.feed.reconcile(
                selected: listing.selectedScope, analysis: listing.analysisScope,
                retention: listing.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk + [trashed.uid])

            // The photo is restored: the library lists it again, and the crawl already holds it.
            await fixture.library.add(trashed)
            await fixture.refresh()

            let status = await fixture.feed.prefetchStatus()
            #expect(
                status.diskThumbnailTotal == fixture.timeline.wholeLibraryUIDs.count, "The library count includes it")
            #expect(status.diskFileCount == status.diskThumbnailTotal, "No thumbnail of the library is missing")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(2)))
        func aGrowingScopeThatFollowsAShrinkInOneReconciliationCrawlsAgain() async throws {
            // Enough photos that removing their thumbnails keeps the cache busy while the next scope arrives.
            let fixture = try await CrawlFixture.loaded(photoCount: 3_000)
            let graph = LibrarySourceGraph()
            let source = LibrarySource(id: SourceID("crawl-shrink-then-grow"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
            let bound = await fixture.feed.bindDerivedDataEpoch(graph.runtimeEpoch)
            #expect(bound)
            func commit(_ items: [PhotoItem]) throws -> LibrarySourceChange {
                let lease = try #require(graph.beginRefresh(source.id))
                return try #require(
                    graph.commit(items.map(LibrarySourceItem.complete), validationToken: nil, using: lease))
            }
            let library = fixture.timeline.wholeLibraryItemsForViewer
            let first = try commit(library)
            _ = await fixture.feed.reconcile(
                selected: first.selectedScope, analysis: first.analysisScope, retention: first.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)
            let smaller = try commit(Array(library.prefix(1)))
            let returning = library + [crawlItem("after-shrink")]
            let larger = try commit(returning)

            // The larger scope arrives while the cache removes the thumbnails that the smaller one dropped.
            let shrink = Task {
                await fixture.feed.reconcile(
                    selected: smaller.selectedScope, analysis: smaller.analysisScope,
                    retention: smaller.thumbnailRetentionScope)
            }
            try await Task.sleep(for: .milliseconds(20))
            _ = await fixture.feed.reconcile(
                selected: larger.selectedScope, analysis: larger.analysisScope,
                retention: larger.thumbnailRetentionScope)
            _ = await shrink.value
            try await fixture.waitUntilIdle(expecting: returning.map(\.uid))

            #expect(
                returning.allSatisfy { fixture.cache.hasUsableDiskData($0.uid) },
                "A crawl that the smaller scope stopped starts again for the larger one")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aShrinkAfterASupersededGrowthJoinsWorkersAndPrunesDecodedPhotos() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12, withSources: true)
            let feed = fixture.feed
            let cache = fixture.cache
            let loader = fixture.loader
            let gate = SourceCacheReturnGate()
            let stoppedWorkers = ProbeCounter()
            let cacheReturnsBeforeJoin = ProbeCounter()
            var growthTask: Task<MediaCacheReconciliationResult, Never>?
            var shrinkTask: Task<MediaCacheReconciliationResult, Never>?
            // Release a detached wait even when a requirement throws, then join all owned tasks below.
            defer {
                gate.release()
                feed.setSourceCacheReconciliationHookForTesting(nil)
                feed.setWorkersStoppedHookForTesting(nil)
            }
            func close() async {
                gate.release()
                await loader.releaseHeld()
                _ = await growthTask?.value
                _ = await shrinkTask?.value
                await fixture.close()
            }
            do {
                let sources = try #require(fixture.sources)
                let original = fixture.timeline.wholeLibraryItemsForViewer
                let joined = crawlItem("superseded-growth")
                func commit(_ items: [PhotoItem]) throws -> LibrarySourceChange {
                    let lease = try #require(sources.graph.beginRefresh(sources.source.id))
                    return try #require(
                        sources.graph.commit(items.map(LibrarySourceItem.complete), validationToken: nil, using: lease))
                }
                let growth = try commit(original + [joined])
                let shrink = try commit(original)
                feed.setSourceCacheReconciliationHookForTesting { revision, result in
                    if revision == growth.selectedScope.revision {
                        gate.pause(result: result)
                    } else if revision == shrink.selectedScope.revision, stoppedWorkers.value == 0 {
                        cacheReturnsBeforeJoin.increment()
                    }
                }
                feed.setWorkersStoppedHookForTesting { stoppedWorkers.increment() }

                // Keep a retained-photo loader running across the add-only cache commit.
                await cache.clear()
                let retained = try #require(original.first?.uid)
                let previousRequests = await loader.requests(for: retained)
                await loader.hold(retained)
                #expect(await feed.requestPriority(retained))
                try #require(await waitUntil { await loader.requests(for: retained) > previousRequests })
                growthTask = Task {
                    await feed.reconcile(
                        selected: growth.selectedScope, analysis: growth.analysisScope,
                        retention: growth.thumbnailRetentionScope)
                }
                try #require(await waitUntil { gate.entered })
                #expect(gate.result == .reconciled(removedEntries: 0))

                // The cache has committed A+B. Decode B so resident pruning and the authorization fence are visible.
                let png = try #require(
                    Data(
                        base64Encoded:
                            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aE3sAAAAASUVORK5CYII="
                    ))
                await cache.store(png, for: joined.uid)
                _ = try #require(await feed.cachedDecoded(for: joined.uid))
                #expect(await feed.prefetchStatus().ramDecodedCount == 1)
                let generation = cache.captureWriterGeneration()
                shrinkTask = Task {
                    await feed.reconcile(
                        selected: shrink.selectedScope, analysis: shrink.analysisScope,
                        retention: shrink.thumbnailRetentionScope)
                }
                // Admission applies authorization before queueing, without another suspension in between.
                try #require(await waitUntil { feed.memoryDecoded(for: joined.uid) == nil })
                #expect(!(await feed.requestPriority(joined.uid)))
                #expect(await feed.prefetchStatus().ramDecodedCount == 1)
                gate.release()
                try #require(
                    await waitUntil {
                        let counters = await feed.downloadCountersForTesting()
                        return !counters.workersRunning || !cache.isCurrentWriterGeneration(generation)
                    })
                #expect(
                    cache.isCurrentWriterGeneration(generation),
                    "Destructive shrink must wait for the held retained-photo worker")
                await loader.releaseHeld()
                #expect(await growthTask?.value == .staleScope)
                _ = await shrinkTask?.value
                #expect(stoppedWorkers.value > 0)
                #expect(cacheReturnsBeforeJoin.value == 0, "The cache shrink returns only after the worker joins")
                #expect(await feed.prefetchStatus().ramDecodedCount == 0, "The removed decoded photo is pruned")
                #expect(feed.memoryDecoded(for: joined.uid) == nil)
                #expect(!(await feed.requestPriority(joined.uid)))
                #expect(!cache.hasUsableDiskData(joined.uid))
                #expect(!gate.timedOut)
                await close()
            } catch {
                await close()
                throw error
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func theRetryOfAFailedCleanupTakesTheFullPath() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12)
            let graph = LibrarySourceGraph()
            let source = LibrarySource(id: SourceID("crawl-failed-cleanup"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
            let bound = await fixture.feed.bindDerivedDataEpoch(graph.runtimeEpoch)
            #expect(bound)
            let library = fixture.timeline.wholeLibraryItemsForViewer
            var lease = try #require(graph.beginRefresh(source.id))
            let first = try #require(
                graph.commit(library.map(LibrarySourceItem.complete), validationToken: nil, using: lease))
            _ = await fixture.feed.reconcile(
                selected: first.selectedScope, analysis: first.analysisScope, retention: first.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)
            let removed = library[0].uid
            lease = try #require(graph.beginRefresh(source.id))
            let smaller = try #require(
                graph.commit(library.dropFirst().map(LibrarySourceItem.complete), validationToken: nil, using: lease))

            // The cache cannot delete while its folders are read-only: the cleanup fails and commits nothing.
            let folders = try cacheFolderModes(in: fixture.directory)
            func restoreModes() {
                for (folder, mode) in folders {
                    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder)
                }
            }
            defer { restoreModes() }
            for (folder, _) in folders {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
            }
            let failed = await fixture.feed.reconcile(
                selected: smaller.selectedScope, analysis: smaller.analysisScope,
                retention: smaller.thumbnailRetentionScope)
            restoreModes()
            #expect(failed == .ioFailure)
            try await fixture.waitUntilIdle(expecting: Array(library.dropFirst().map(\.uid)))
            let before = await fixture.counts()

            // The source runtime retries the same change.
            let retried = await fixture.feed.reconcile(
                selected: smaller.selectedScope, analysis: smaller.analysisScope,
                retention: smaller.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: Array(library.dropFirst().map(\.uid)))

            let after = await fixture.counts()
            #expect(retried != .ioFailure)
            #expect(!fixture.cache.hasUsableDiskData(removed), "The retry removes the dropped thumbnail")
            #expect(
                after.diskProbes - before.diskProbes >= library.count - 1,
                "The retry takes the full path with a fresh crawl, not the growth path")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aPhotoThatJoinsAfterTheCrawlWasStoppedIsCrawled() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12, withSources: true)
            // A stop outside reconciliation empties the crawl list but keeps its position at the end of the library.
            await fixture.feed.stopPrefetch()
            // One photo older and one newer than the library: whatever the crawl order, one of them sorts before the
            // position at which the stopped crawl ended.
            let added = [1_600_000_000, 1_800_000_000].map { seconds in
                PhotoItem(
                    uid: PhotoUID(volumeID: "crawl", nodeID: "scope-after-stop-\(seconds)"),
                    captureTime: Date(timeIntervalSince1970: TimeInterval(seconds)), mediaType: "image/jpeg")
            }
            for item in added { await fixture.library.add(item) }
            let fullScans = await fixture.feed.coverageFullScanCountForTesting()

            // No hand-off to the update coordinator: only the crawl can load the new photos.
            _ = await fixture.timeline.refreshLibrary()
            await fixture.publishSources()
            try await fixture.waitUntilIdle(expecting: added.map(\.uid))

            for item in added {
                #expect(fixture.cache.hasUsableDiskData(item.uid))
                #expect(await fixture.loader.requests(for: item.uid) == 1)
            }
            // A list that started past its end would find the photo only through a full coverage scan of the disk.
            #expect(
                await fixture.feed.coverageFullScanCountForTesting() == fullScans,
                "The new crawl list starts at its first photo")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aShrinkingSourceScopeDropsTheRemovedThumbnail() async throws {
            let fixture = try await CrawlFixture.loaded(photoCount: 12, withSources: true)
            let removed = fixture.timeline.wholeLibraryUIDs[0]
            #expect(fixture.cache.hasUsableDiskData(removed))
            let before = await fixture.counts()

            await fixture.library.remove(removed)
            await fixture.refresh()

            let after = await fixture.counts()
            #expect(!fixture.timeline.wholeLibraryUIDs.contains(removed))
            #expect(!fixture.cache.hasUsableDiskData(removed), "An authoritative smaller scope removes the thumbnail")
            #expect(
                after.diskProbes - before.diskProbes >= fixture.timeline.wholeLibraryUIDs.count,
                "A smaller scope takes the full path with a fresh crawl")
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aCachedSourceScopeThatTurnsAuthoritativeCrawlsAgain() async throws {
            // No fixture sources: this test drives its own graph from a cached to an authoritative inventory.
            let fixture = try await CrawlFixture.loaded(photoCount: 12)
            let graph = LibrarySourceGraph()
            let source = LibrarySource(id: SourceID("crawl-cached-library"), capabilities: .readThumbnail)
            _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
            let bound = await fixture.feed.bindDerivedDataEpoch(graph.runtimeEpoch)
            #expect(bound)
            let items = fixture.timeline.wholeLibraryItemsForViewer.map(LibrarySourceItem.complete)
            let cached = try #require(graph.installCachedInventory(items, for: source.id))
            _ = await fixture.feed.reconcile(
                selected: cached.selectedScope, analysis: cached.analysisScope,
                retention: cached.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)
            let before = await fixture.counts()

            let lease = try #require(graph.beginRefresh(source.id))
            let authoritative = try #require(graph.commit(items, validationToken: nil, using: lease))
            _ = await fixture.feed.reconcile(
                selected: authoritative.selectedScope, analysis: authoritative.analysisScope,
                retention: authoritative.thumbnailRetentionScope)
            try await fixture.waitUntilIdle(expecting: fixture.expectedOnDisk)

            let after = await fixture.counts()
            #expect(
                after.diskProbes - before.diskProbes >= items.count,
                "An authority change takes the full path and checks the library again")
            #expect(after.requests == before.requests, "Thumbnails already on disk are not loaded again")
            await fixture.close()
        }

        /// The session of `WholeLibraryThumbnailCrawlTests.measureTheWorkOfOneSession` without its trash row, with the
        /// whole library also delivered to the feed as a source scope. The package test log carries the numbers.
        @Test(.timeLimit(.minutes(3)))
        func measureTheWorkOfOneSessionWithASourceScope() async throws {
            let refused = crawlItem("scope-measure-refused")
            let fixture = try await CrawlFixture.loaded(
                photoCount: 200, extra: [refused], refusing: [refused.uid], withSources: true)
            var rows = ["cold load of 201 photos": await fixture.counts()]
            var previous = rows["cold load of 201 photos"]!

            await fixture.refresh()
            let unchanged = await fixture.counts()
            rows["refresh without change"] = unchanged - previous
            previous = unchanged

            for index in 0..<5 {
                await fixture.library.add(crawlItem("scope-measure-added-\(index)"))
                await fixture.refresh()
            }
            let added = await fixture.counts()
            rows["5 refreshes, each adds a photo"] = added - previous

            // No trash row: the app keeps a trashed photo's thumbnail through the trash listing, which this fixture's
            // source scope does not model.
            rows["refused photo, requests in total"] = CrawlCounts(
                requests: await fixture.loader.requests(for: refused.uid))
            for (scenario, counts) in rows.sorted(by: { $0.key < $1.key }) {
                print("CRAWL-MEASURE-SCOPE \(scenario): \(counts)")
            }
            #expect(rows["refresh without change"]!.requests == 0)
            await fixture.close()
        }
    }

    /// Holds only the detached cache return, with a bounded wait and an idempotent release for every exit.
    private final class SourceCacheReturnGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false
        private var released = false
        private var timeout = false
        private var cacheResult: MediaCacheReconciliationResult?

        var entered: Bool { lock.withLock { didEnter } }
        var timedOut: Bool { lock.withLock { timeout } }
        var result: MediaCacheReconciliationResult? { lock.withLock { cacheResult } }

        func pause(result: MediaCacheReconciliationResult) {
            let shouldWait = lock.withLock {
                didEnter = true
                cacheResult = result
                return !released
            }
            if shouldWait, semaphore.wait(timeout: .now() + 10) == .timedOut {
                lock.withLock { timeout = true }
            }
        }

        func release() {
            let shouldSignal = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            if shouldSignal { semaphore.signal() }
        }
    }

    /// The folders below `root`, and `root` itself, with their current permissions, so a test can make the encrypted
    /// cache read-only and restore it.
    private func cacheFolderModes(in root: URL) throws -> [(String, Int)] {
        var folders = [root.path]
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = entries?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { folders.append(url.path) }
        }
        return try folders.map { folder in
            let attributes = try FileManager.default.attributesOfItem(atPath: folder)
            return (folder, (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755)
        }
    }
#endif
