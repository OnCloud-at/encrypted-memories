import Foundation
import PhotosCore
import ProtonAuth
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile
@testable import TimelineCore

/// The timeline model belongs to one account runtime. A retry ends that runtime but keeps its photos visible until the
/// next runtime shows its own library.
@MainActor @Suite struct MobileLibraryRuntimeTests {
    @Test(.timeLimit(.minutes(1)))
    func aRetryKeepsThePhotosVisibleWhileItRetiresTheRuntime() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let shown = model.items.map(\.uid)
        let observation = RetryObservation()
        let replacement = ProtonSession(
            uid: "replacement-runtime", accessToken: "fixture-access", refreshToken: "fixture-refresh",
            keyPassword: "fixture-key")
        model.backendRetirementForTesting = {
            observation.uids = model.items.map(\.uid)
            observation.loadState = model.loadState
            // A replacement account stops the retry before it opens a network backend.
            model.installIsolatedLibrary(
                session: replacement, store: SessionKeychainStore(), backend: fixture.backend,
                sections: fixture.sections, thumbnailFeed: fixture.feed)
        }

        await model.retry()
        model.backendRetirementForTesting = nil

        #expect(observation.uids == shown, "The photos stay visible while the retry retires the runtime")
        #expect(observation.loadState == .preparingInventory, "The loading cover shows over them")
        model.configure(session: nil, store: SessionKeychainStore())
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func replacingARetiredRuntimeReleasesItsTimelineModel() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        // Let the publication callback rearm its observation before retirement.
        await Task { @MainActor in }.value
        let observation = RetryObservation()
        observation.retiredTimeline = model.timeline
        #expect(observation.retiredTimeline != nil)
        let replacement = ProtonSession(
            uid: "replacement-runtime", accessToken: "fixture-access", refreshToken: "fixture-refresh",
            keyPassword: "fixture-key")
        model.backendRetirementForTesting = {
            model.installIsolatedLibrary(
                session: replacement, store: SessionKeychainStore(), backend: fixture.backend,
                sections: fixture.sections, thumbnailFeed: fixture.feed)
        }

        await model.retry()
        model.backendRetirementForTesting = nil

        #expect(await yieldUntil { observation.retiredTimeline == nil }, "A retired model has no observation cycle")
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRetryKeepsGridRevisionsAboveEarlierPendingPhotos() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let oldTimeline = try #require(model.timeline)
        var earlier = [model.gridRevision]
        oldTimeline.setPendingPresentation(pendingPresentation(fixture, revision: 1_000))
        #expect(model.showsPendingPhotos)
        #expect(model.gridItems.count == fixture.items.count + 1)
        earlier.append(model.gridRevision)
        #expect(earlier[1] % 4 == 2, "The earlier grid shows pending photos")
        let observation = RetryObservation()
        let replacement = ProtonSession(
            uid: "replacement-runtime", accessToken: "fixture-access", refreshToken: "fixture-refresh",
            keyPassword: "fixture-key")
        model.backendRetirementForTesting = {
            observation.gridRevision = model.gridRevision
            model.installIsolatedLibrary(
                session: replacement, store: SessionKeychainStore(), backend: fixture.backend,
                sections: fixture.sections, thumbnailFeed: fixture.feed)
            model.timeline?.setPendingPresentation(pendingPresentation(fixture, revision: 1))
        }

        await model.retry()
        model.backendRetirementForTesting = nil
        earlier.append(try #require(observation.gridRevision))

        #expect(model.timeline !== oldTimeline)
        #expect(model.showsPendingPhotos)
        #expect(model.gridRevision % 4 == 2)
        #expect(earlier.allSatisfy { model.gridRevision > $0 }, "The replacement never reuses an earlier grid revision")
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshAfterAFailedFirstLoadShowsTheLibrary() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let listing = FirstListingFails(sections: fixture.sections)
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails,
                timelineLoader: { try await listing.load() }),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
        let runtime = await installSourceRuntime(into: model, fixture: fixture, startingWith: .authoritative)
        let backend = try #require(model.backend)
        // An offline launch: the first listing fails.
        await model.loadIsolatedInitialTimelineForTesting(repository: backend)
        #expect(model.loadState.failure != nil)

        // The network returns and the change monitor refreshes.
        let outcome = await model.refreshIsolatedLibraryForTesting()

        #expect(outcome == .refreshed(token: "fixture"))
        #expect(model.loadState.failure == nil, "The library replaces the failure when the server returns")
        #expect(model.items.map(\.uid) == fixture.items.map(\.uid))
        await runtime.shutdown()
    }
}

/// A Proton listing that fails once, as when the device starts offline.
private actor FirstListingFails {
    let sections: [TimelineSection]
    private var failed = false
    init(sections: [TimelineSection]) { self.sections = sections }
    func load() throws -> TimelineLoadSnapshot {
        guard failed else {
            failed = true
            throw URLError(.notConnectedToInternet)
        }
        return TimelineLoadSnapshot(sections: sections, validationToken: "fixture")
    }
}

/// What the model showed when the retry retired its runtime.
@MainActor private final class RetryObservation {
    var uids: [PhotoUID]?
    var loadState: LibraryLoadState?
    var gridRevision: UInt64?
    weak var retiredTimeline: TimelineViewModel?
}

@MainActor private func pendingPresentation(
    _ fixture: MobileSignedInFixture, revision: UInt64
) -> PendingTimelinePresentation {
    let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "revision-pending-\(revision)")
    let local = PhotoItem(
        uid: key.localUID, captureTime: Date(timeIntervalSince1970: 1_800_000_000), mediaType: "image/jpeg")
    let pendingSection = TimelineSection(
        id: "pending-fixture", date: local.captureTime, title: "", items: [local])
    let sections = fixture.sections + [pendingSection]
    return PendingTimelinePresentation(
        revision: revision, membershipRevision: revision,
        snapshot: TimelineContentProjection(sections: sections).snapshot,
        localUIDs: [key.localUID], favoriteIntents: [:], uploadBadges: .empty, isCanonical: false)
}
