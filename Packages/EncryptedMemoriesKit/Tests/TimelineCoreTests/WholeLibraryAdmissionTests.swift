import Foundation
import MediaByteCache
import Observation
import PhotosCore
import Testing

@testable import MediaFeedCore
@testable import TimelineCore

/// A host that admits the source inventory before publication (iPhone and iPad) sees a whole-library listing only
/// after the admission accepted it. A refused or superseded listing shows nothing; only a refused first load fails it,
/// and a refresh stays silent.
@Suite @MainActor struct WholeLibraryAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func aRefusedFirstListingShowsNothingAndFailsTheFirstLoad() async throws {
        let fixture = try await AdmissionFixture(answers: [.rejected])
        await fixture.timeline.load()

        #expect(fixture.timeline.wholeLibraryUIDs.isEmpty, "A refused listing never reaches the grid")
        #expect(fixture.timeline.initialLibraryLoadState.failure != nil)
        #expect(fixture.admitter.authorities == [.authoritative])
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSupersededFirstListingShowsNothingAndReportsNoFailure() async throws {
        let fixture = try await AdmissionFixture(answers: [.superseded])
        await fixture.timeline.load()

        #expect(fixture.timeline.wholeLibraryUIDs.isEmpty)
        #expect(fixture.timeline.initialLibraryLoadState.failure == nil)
        #expect(fixture.timeline.initialLibraryChangeToken == "", "An unpublished listing cannot seed the monitor")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSavedListingIsAdmittedAsCachedBeforeTheCurrentOne() async throws {
        let fixture = try await AdmissionFixture(answers: [.accepted, .accepted], cached: true)
        await fixture.timeline.load()

        #expect(fixture.admitter.authorities == [.cached, .authoritative])
        #expect(fixture.timeline.wholeLibraryUIDs == fixture.library.uids)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [TimelineViewModel.WholeLibraryAdmission.rejected, .superseded])
    func aRefreshThatTheSourcesDoNotAdmitShowsNothingAndStaysSilent(
        answer: TimelineViewModel.WholeLibraryAdmission
    ) async throws {
        let fixture = try await AdmissionFixture(answers: [.accepted, answer])
        await fixture.timeline.load()
        let shown = fixture.timeline.wholeLibraryUIDs
        let loadState = fixture.timeline.initialLibraryLoadState
        await fixture.library.add(admissionItem("refresh-arriving"))

        let result = await fixture.timeline.refreshLibrary()

        #expect(result.failureReason == (answer == .rejected ? .other : .superseded))
        #expect(fixture.timeline.wholeLibraryUIDs == shown, "The listing that the sources did not admit stays hidden")
        #expect(fixture.timeline.initialLibraryLoadState == loadState, "A background refresh shows no failure")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [TimelineViewModel.WholeLibraryAdmission.rejected, .superseded])
    func theNextRefreshSettlesAFirstLoadThatShowedNothing(
        firstAnswer: TimelineViewModel.WholeLibraryAdmission
    ) async throws {
        let fixture = try await AdmissionFixture(answers: [firstAnswer, .accepted])
        await fixture.timeline.load()
        #expect(fixture.timeline.wholeLibraryUIDs.isEmpty)

        let result = await fixture.timeline.refreshLibrary()

        #expect(result.failureReason == nil)
        #expect(fixture.timeline.wholeLibraryUIDs == fixture.library.uids)
        #expect(fixture.timeline.initialLibraryLoadState.failure == nil, "A refused first load recovers")
        #expect(
            fixture.timeline.initialLibraryLoadState.knownCount == fixture.library.uids.count,
            "The library leaves the preparing state with the refreshed count")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func pendingPhotosShowAfterAFailedFirstLoadAndAnEmptyRefresh(withPendingPhotos: Bool) async throws {
        // macOS passes no admitter. The first listing fails; the next one is an authoritative empty library.
        let fixture = try await AdmissionFixture(
            answers: [], photoCount: 0, failsFirstListing: true, admits: false)
        await fixture.timeline.load()
        #expect(fixture.timeline.initialLibraryLoadState.failure != nil)
        let pending = admissionItem("pending-after-failure")
        if withPendingPhotos {
            fixture.timeline.setPendingPresentation(
                PendingTimelinePresentation(
                    revision: 1, membershipRevision: 1,
                    snapshot: TimelineContentProjection(sections: admissionSections([pending])).snapshot,
                    localUIDs: [pending.uid], favoriteIntents: [:], uploadBadges: .empty, isCanonical: false))
        }

        _ = await fixture.timeline.refreshLibrary()

        #expect(fixture.timeline.initialLibraryLoadState == .empty)
        #expect(fixture.timeline.showsPendingPhotos == withPendingPhotos)
        if withPendingPhotos {
            if case .loaded(let sections) = fixture.timeline.gridState {
                #expect(sections.map(\.id) == ["pending-presentation"])
                #expect(sections.flatMap(\.items) == [pending])
            } else {
                Issue.record("The pending photos replace the failed grid")
            }
        } else if case .empty = fixture.timeline.gridState {
            // The authoritative empty result replaces the failed grid without pending photos too.
        } else {
            Issue.record("The authoritative empty grid replaces the failed grid")
        }
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func unchangedNonEmptyContentRecoversAfterAContentFailure() async throws {
        let fixture = try await AdmissionFixture(answers: [], admits: false)
        await fixture.timeline.load()
        let shown = fixture.timeline.wholeLibraryTimeline
        #expect(!shown.items.isEmpty)
        fixture.timeline.reportInitialContentFailure()
        #expect(fixture.timeline.initialLibraryLoadState.failure != nil)
        if case .failed = fixture.timeline.gridState {
        } else {
            Issue.record("The content failure must reach the grid before the refresh")
        }

        let result = await fixture.timeline.refreshLibrary()

        #expect(result.failureReason == nil)
        #expect(fixture.timeline.initialLibraryLoadState.failure == nil)
        if case .loaded(let sections) = fixture.timeline.gridState {
            #expect(sections.flatMap(\.items) == shown.items)
        } else {
            Issue.record("The unchanged non-empty listing replaces the failed grid")
        }
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedSavedListingDoesNotPublishOrReadTheServer() async throws {
        let fixture = try await AdmissionFixture(answers: [.rejected], cached: true)
        await fixture.timeline.load()

        #expect(fixture.timeline.wholeLibraryUIDs.isEmpty)
        #expect(fixture.timeline.initialLibraryLoadState.failure != nil)
        #expect(fixture.admitter.authorities == [.cached], "A refused saved listing ends this first load")
        #expect(await fixture.library.fullLoads == 0)
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: AdmissionPhase.allCases)
    func anAdmissionOvertakenByANewerPublicationPublishesNothing(phase: AdmissionPhase) async throws {
        let fixture = try await AdmissionFixture(
            answers: [], cached: phase == .cached || phase == .validated, validatesCache: phase == .validated)
        if phase == .refresh { await fixture.timeline.load() }
        fixture.admitter.holdAdmission(after: phase == .validated ? 1 : 0)
        let older = Task {
            if phase == .refresh {
                return await fixture.timeline.refreshLibrary().failureReason
            }
            await fixture.timeline.load()
            return Optional<TimelineRefreshFailureReason>.none
        }
        let admitter = fixture.admitter
        guard await waitUntil(timeout: .seconds(5), { await admitter.isHolding }) else {
            Issue.record("The source admission did not reach its hold")
            fixture.admitter.release()
            _ = await older.value
            await fixture.close()
            return
        }
        let arriving = admissionItem("newer-publication")
        await fixture.library.add(arriving)
        let newer = await fixture.timeline.refreshLibrary()
        #expect(newer.failureReason == nil)
        let revision = fixture.timeline.wholeLibraryContentRevision
        let shown = fixture.timeline.wholeLibraryUIDs
        #expect(shown.contains(arriving.uid))

        fixture.admitter.release()
        let oldFailure = await older.value

        #expect(fixture.timeline.wholeLibraryUIDs == shown)
        #expect(
            fixture.timeline.wholeLibraryContentRevision == revision,
            "The older admission publishes no intermediate content")
        #expect(fixture.timeline.wholeLibraryInventoryAuthority == .authoritative)
        if phase == .refresh { #expect(oldFailure == .superseded) }
        await fixture.close()
    }

    #if DEBUG
        @Test(.timeLimit(.minutes(1)))
        func aTrashProjectionKeepsARouteEntryThatLoadedWhileItRan() async throws {
            let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 3)
            await fixture.timeline.load()
            fixture.timeline.markInitialContentReady()

            // While the trash projection is computing, a person opens another album, so that route's
            // sections enter the cache before the projection writes.
            let rival = PhotoFilter.album(id: "rival", title: "Rival")
            var gated = true
            fixture.timeline.afterProjectionComputedForTesting = {
                guard gated else { return }
                gated = false
                await fixture.timeline.select(rival)
            }

            let victim = try #require(fixture.timeline.wholeLibraryUIDs.first)
            await fixture.timeline.commitTrash(uids: [victim])

            // The projection may only replace the routes it projected; the album the person opened keeps
            // its cached entry.
            #expect(fixture.timeline.filterCacheForTesting.routes.contains(rival))
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aTrashProjectionKeepsARouteEntryThatARefreshStoredWhileItRan() async throws {
            let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 3)
            await fixture.timeline.load()
            fixture.timeline.markInitialContentReady()
            let album = PhotoFilter.album(id: "album", title: "Album")
            let member = admissionItem("album-member")
            await fixture.library.setItems([member], for: album)
            await fixture.timeline.select(album)
            #expect(fixture.timeline.filterCacheForTesting.snapshot(for: album)?.flatMap(\.items) == [member])

            // While the trash projection is computing, a photo arrives in the open album and a refresh reads it.
            let arriving = admissionItem("album-arrival")
            var gated = true
            fixture.timeline.afterProjectionComputedForTesting = {
                guard gated else { return }
                gated = false
                await fixture.library.setItems([member, arriving], for: album)
                await fixture.timeline.refreshLibrary()
            }

            let victim = try #require(fixture.timeline.wholeLibraryUIDs.first)
            await fixture.timeline.commitTrash(uids: [victim])

            // The projection removes the trashed photo from the refreshed entry instead of restoring the older one.
            let cached = fixture.timeline.filterCacheForTesting.snapshot(for: album)?.flatMap(\.items).map(\.uid)
            #expect(cached == [member.uid, arriving.uid])
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aRestoreProjectionKeepsATrashEntryThatARefreshStoredWhileItRan() async throws {
            let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 3)
            await fixture.timeline.load()
            fixture.timeline.markInitialContentReady()
            let restored = admissionItem("trashed-restored")
            let kept = admissionItem("trashed-kept")
            await fixture.library.setItems([restored, kept], for: .trash)
            await fixture.timeline.select(.trash)

            // While the restore projection is computing, another photo arrives in Recently Deleted and a refresh
            // reads it.
            let arriving = admissionItem("trashed-arrival")
            var gated = true
            fixture.timeline.afterProjectionComputedForTesting = {
                guard gated else { return }
                gated = false
                await fixture.library.setItems([restored, kept, arriving], for: .trash)
                await fixture.timeline.refreshLibrary()
            }

            await fixture.timeline.commitRestore([restored])

            // The projection removes the restored photo from the refreshed entry instead of restoring the older one.
            let cached = fixture.timeline.filterCacheForTesting.snapshot(for: .trash)?.flatMap(\.items).map(\.uid)
            #expect(cached.map(Set.init) == [kept.uid, arriving.uid])
            await fixture.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func aTrashProjectionKeepsATrashThatWasEmptiedWhileItRan() async throws {
            let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 3)
            await fixture.timeline.load()
            fixture.timeline.markInitialContentReady()
            let emptied = admissionItem("trashed-emptied")
            await fixture.library.setItems([emptied], for: .trash)
            await fixture.timeline.select(.trash)

            // While the trash projection is computing, the person empties Recently Deleted.
            var gated = true
            fixture.timeline.afterProjectionComputedForTesting = {
                guard gated else { return }
                gated = false
                fixture.timeline.commitEmptyTrash([emptied.uid])
            }

            let victim = try #require(fixture.timeline.wholeLibraryUIDs.first)
            await fixture.timeline.commitTrash(uids: [victim])

            // Recently Deleted holds only the newly trashed photo; the emptied one does not come back.
            let cached = fixture.timeline.filterCacheForTesting.snapshot(for: .trash)?.flatMap(\.items).map(\.uid)
            #expect(cached == [victim])
            await fixture.close()
        }
    #endif

    #if DEBUG
        @Test func cancellingTheRuntimeStopsACrawlStartThatHasNotReachedTheFeed() async throws {
            let fixture = try await AdmissionFixture(answers: [], enablesCrawl: true)
            let timeline = fixture.timeline
            // The first publication creates the crawl start in the same main-actor turn. The cancellation is queued at
            // that publication, so it runs before the crawl start resumes after sorting the photos.
            withObservationTracking {
                _ = timeline.wholeLibraryUIDs
            } onChange: {
                Task { @MainActor in timeline.cancelLoadAndCrawlStart() }
            }
            await timeline.load()
            await timeline.waitForWholeLibraryCrawlStart()

            #expect(timeline.wholeLibraryUIDs.count == 4, "The first listing was published")
            #expect(await fixture.feed.workerStartCountForTesting() == 0, "No crawl starts on a retired runtime's feed")
            await fixture.close()
        }
    #endif

    @Test(.timeLimit(.minutes(1)))
    func trashingTheLastPhotoEmptiesTheLoadState() async throws {
        let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 1)
        await fixture.timeline.load()
        fixture.timeline.markInitialContentReady()

        await fixture.timeline.commitTrash(uids: Set(fixture.timeline.wholeLibraryUIDs))

        #expect(fixture.timeline.wholeLibraryUIDs.isEmpty)
        #expect(fixture.timeline.initialLibraryLoadState == .empty, "An emptied library shows its empty state")
        await fixture.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingPhotosWaitWhileASavedEmptyLibraryIsChecked() async throws {
        let fixture = try await AdmissionFixture(answers: [.accepted], photoCount: 0, cached: true, holdsListing: true)
        let loading = Task { await fixture.timeline.load() }
        let library = fixture.library
        #expect(await waitUntil(timeout: .seconds(5)) { await library.isHoldingListing })
        let pending = admissionItem("pending-local")
        fixture.timeline.setPendingPresentation(
            PendingTimelinePresentation(
                revision: 1, membershipRevision: 1,
                snapshot: TimelineContentProjection(sections: admissionSections([pending])).snapshot,
                localUIDs: [pending.uid], favoriteIntents: [:], uploadBadges: .empty, isCanonical: false))

        #expect(!fixture.timeline.showsPendingPhotos, "Pending photos wait for the Proton library")
        await fixture.library.releaseListing()
        await loading.value
        await fixture.close()
    }
}

private func admissionItem(_ id: String) -> PhotoItem {
    PhotoItem(
        uid: PhotoUID(volumeID: "admission", nodeID: id), captureTime: Date(timeIntervalSince1970: 1_700_000_000),
        mediaType: "image/jpeg")
}

private func admissionSections(_ items: [PhotoItem]) -> [TimelineSection] {
    items.isEmpty ? [] : [TimelineSection(id: "admission", date: items[0].captureTime, title: "", items: items)]
}

enum AdmissionPhase: CaseIterable, Sendable, Equatable { case cached, validated, initial, refresh }

@MainActor private final class AdmissionAnswers {
    private var answers: [TimelineViewModel.WholeLibraryAdmission]
    private(set) var authorities: [SourceInventoryAuthority] = []

    init(_ answers: [TimelineViewModel.WholeLibraryAdmission]) { self.answers = answers }

    private var admissionsBeforeHold: Int?
    private var held: CheckedContinuation<Void, Never>?

    func holdAdmission(after count: Int) { admissionsBeforeHold = count }
    func release() {
        held?.resume()
        held = nil
    }
    var isHolding: Bool { held != nil }

    func admit(
        _ items: [PhotoItem], _ authority: SourceInventoryAuthority
    ) async -> TimelineViewModel.WholeLibraryAdmission {
        authorities.append(authority)
        if let count = admissionsBeforeHold {
            admissionsBeforeHold = count == 0 ? nil : count - 1
            if count == 0 { await withCheckedContinuation { held = $0 } }
        }
        return answers.isEmpty ? .accepted : answers.removeFirst()
    }
}

@MainActor private struct AdmissionFixture {
    let directory: URL
    let library: AdmissionLibrary
    let feed: ThumbnailFeedCore
    let admitter: AdmissionAnswers
    let timeline: TimelineViewModel

    init(
        answers: [TimelineViewModel.WholeLibraryAdmission], photoCount: Int = 4, cached: Bool = false,
        holdsListing: Bool = false, failsFirstListing: Bool = false, admits: Bool = true, enablesCrawl: Bool = false,
        validatesCache: Bool = false
    ) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = (0..<photoCount).map { admissionItem("photo-\($0)") }
        library = AdmissionLibrary(
            items: items, cached: cached, holdsListing: holdsListing, failsFirstListing: failsFirstListing,
            validatesCache: validatesCache)
        feed = ThumbnailFeedCore(cache: ThumbnailCache(rootDirectory: directory), loader: NoThumbnails())
        // Most tests check publication only; no thumbnail work runs there.
        if !enablesCrawl { await feed.setPrefetchEnabled(false) }
        let admitter = AdmissionAnswers(answers)
        self.admitter = admitter
        var admitWholeLibrary: TimelineViewModel.WholeLibraryAdmitter?
        if admits { admitWholeLibrary = { items, authority in await admitter.admit(items, authority) } }
        timeline = TimelineViewModel(
            repository: library, feed: feed, library: library, admitWholeLibrary: admitWholeLibrary)
    }

    func close() async {
        await feed.stopPrefetchAndWait()
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor AdmissionLibrary: PhotosRepository, PhotoLibraryProvider, LibraryChangeTokenProvider {
    private var items: [PhotoItem]
    private let cached: Bool
    private let validatesCache: Bool
    private(set) var fullLoads = 0
    private let holdsListing: Bool
    private var failsNextListing: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var isHeld = false

    nonisolated let initialUIDs: [PhotoUID]

    init(items: [PhotoItem], cached: Bool, holdsListing: Bool, failsFirstListing: Bool, validatesCache: Bool) {
        self.items = items
        self.cached = cached
        self.validatesCache = validatesCache
        self.holdsListing = holdsListing
        failsNextListing = failsFirstListing
        initialUIDs = items.map(\.uid)
    }

    nonisolated var uids: [PhotoUID] { initialUIDs }

    func add(_ item: PhotoItem) { items.append(item) }

    func loadTimeline() async throws -> [TimelineSection] { admissionSections(items) }

    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        fullLoads += 1
        if failsNextListing {
            failsNextListing = false
            throw URLError(.notConnectedToInternet)
        }
        if holdsListing, held == nil, !isHeld {
            isHeld = true
            await withCheckedContinuation { held = $0 }
        }
        return TimelineLoadSnapshot(sections: admissionSections(items), validationToken: "token-\(items.count)")
    }

    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        cached
            ? CachedTimelineSnapshot(
                sections: admissionSections(items), validationToken: validatesCache ? "validated" : nil)
            : nil
    }

    func libraryChangeToken() async throws -> String { "validated" }
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String { "validated" }
    func monitorBaseline(for token: String) async throws -> String { token }
    private var routeItems: [PhotoFilter: [PhotoItem]] = [:]
    func setItems(_ items: [PhotoItem], for route: PhotoFilter) { routeItems[route] = items }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { admissionSections(routeItems[filter] ?? []) }

    var isHoldingListing: Bool { held != nil }

    func releaseListing() {
        held?.resume()
        held = nil
    }
}
