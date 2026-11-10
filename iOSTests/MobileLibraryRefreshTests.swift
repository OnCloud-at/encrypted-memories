import Foundation
import PhotosCore
import ProtonAuth
import Testing
import TimelineCore

@testable import EncryptedMemoriesMobile
@testable import ProtonDriveBackend

/// What a library refresh on iPhone and iPad publishes: nothing for an equal library, the changed photo for a
/// metadata change, nothing without an admitted source inventory, nothing after sign-out, and never a photo that
/// was moved to the trash while the refresh read the library.
@MainActor @Suite struct MobileLibraryRefreshTests {
    @Test(.timeLimit(.minutes(1)))
    func anEqualLibraryPublishesNothing() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let sections = fixture.sections
        install(fixture, into: model) { TimelineLoadSnapshot(sections: sections, validationToken: "a") }
        let runtime = await installSourceRuntime(into: model, fixture: fixture, startingWith: .authoritative)
        let timelineRevision = model.timelineRevision
        let gridRevision = model.gridRevision
        let items = model.gridItems

        let outcome = await model.refreshIsolatedLibraryForTesting()

        #expect(outcome == .refreshed(token: "a"))
        #expect(model.timelineRevision == timelineRevision, "An equal library keeps the shown grid and its position")
        #expect(model.gridRevision == gridRevision)
        #expect(model.gridItems == items)
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func aMetadataChangeReplacesTheShownPhoto() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let first = fixture.items[0]
        let corrected = PhotoItem(
            uid: first.uid, captureTime: first.captureTime, mediaType: "video/quicktime", tags: [.videos])
        let correctedSections = fixture.sections.map { section in
            TimelineSection(
                id: section.id, date: section.date, title: section.title,
                items: section.items.map { $0.uid == first.uid ? corrected : $0 })
        }
        install(fixture, into: model) { TimelineLoadSnapshot(sections: correctedSections, validationToken: "b") }
        let runtime = await installSourceRuntime(into: model, fixture: fixture, startingWith: .authoritative)
        let timelineRevision = model.timelineRevision
        let gridRevision = model.gridRevision

        let outcome = await model.refreshIsolatedLibraryForTesting()

        #expect(outcome == .refreshed(token: "b"))
        #expect(model.gridItems.map(\.uid) == fixture.items.map(\.uid), "The same photos keep their order")
        #expect(model.gridItems.first { $0.uid == first.uid } == corrected)
        #expect(model.timelineRevision != timelineRevision, "A metadata change publishes a new timeline")
        #expect(model.gridRevision != gridRevision, "The grid rebuilds the changed photo")
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func aLibraryWithoutAdmittedSourcesStaysSilent() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let arriving = PhotoItem(
            uid: PhotoUID(volumeID: "fixture-volume", nodeID: "arriving-without-sources"),
            captureTime: .distantPast, mediaType: "image/jpeg")
        let refreshed =
            fixture.sections + [TimelineSection(id: "arriving", date: .distantPast, title: "", items: [arriving])]
        // No source runtime: the source inventory cannot admit the refreshed photos.
        install(fixture, into: model) { TimelineLoadSnapshot(sections: refreshed, validationToken: "b") }
        let loadState = model.loadState
        let timelineRevision = model.timelineRevision

        let outcome = await model.refreshIsolatedLibraryForTesting()

        #expect(outcome == .retry, "The monitor tries again later")
        #expect(!model.items.contains { $0.uid == arriving.uid }, "An unadmitted inventory never reaches the grid")
        #expect(model.timelineRevision == timelineRevision)
        #expect(model.loadState == loadState, "A failed background refresh shows nothing")
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshThatEndsAfterSignOutPublishesNothing() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let read = HeldLibraryRead(snapshot: TimelineLoadSnapshot(sections: fixture.sections, validationToken: "b"))
        install(fixture, into: model) { await read.load() }
        let runtime = await installSourceRuntime(into: model, fixture: fixture, startingWith: .authoritative)
        let refresh = Task { await model.refreshIsolatedLibraryForTesting() }
        #expect(try await pollUntil(timeout: .seconds(5)) { await read.isHeld })

        model.configure(session: nil, store: SessionKeychainStore())
        #expect(model.items.isEmpty)
        let timelineRevision = model.timelineRevision
        await read.release()

        #expect(await refresh.value == .retry)
        #expect(model.items.isEmpty, "The signed-out account shows no photos of the earlier one")
        #expect(model.timelineRevision == timelineRevision)
        #expect(model.backend == nil)
        await runtime.shutdown()
        await fixture.feed.stopPrefetch()
    }

    @Test(.timeLimit(.minutes(1)))
    func aPhotoTrashedDuringARefreshStaysHidden() async throws {
        let fixture = try await MobileSignedInFixture(itemsPerSection: 1)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        let trashed = fixture.items[0].uid
        // The refresh read the library before the trash reached the server, so it still lists the photo.
        let read = HeldLibraryRead(snapshot: TimelineLoadSnapshot(sections: fixture.sections, validationToken: "b"))
        install(fixture, into: model) { await read.load() }
        let runtime = await installSourceRuntime(into: model, fixture: fixture, startingWith: .authoritative)
        let refresh = Task { await model.refreshIsolatedLibraryForTesting() }
        #expect(try await pollUntil(timeout: .seconds(5)) { await read.isHeld })

        try await model.trashItems([trashed])
        #expect(!model.items.contains { $0.uid == trashed })
        await read.release()
        _ = await refresh.value

        #expect(!model.items.contains { $0.uid == trashed }, "An older listing never brings a trashed photo back")
        #expect(model.items.count == fixture.items.count - 1)
        await runtime.shutdown()
    }

    private func install(
        _ fixture: MobileSignedInFixture, into model: MobileLibraryModel,
        timeline: @escaping @Sendable () async throws -> TimelineLoadSnapshot
    ) {
        fixture.install(
            into: model,
            backend: MobileFixtureBackend(
                sections: fixture.sections, thumbnails: fixture.backend.thumbnails, timelineLoader: timeline),
            sections: fixture.sections, thumbnailFeed: fixture.feed, thumbnailCache: fixture.cache)
    }
}

/// A library read that waits until the test releases it.
private actor HeldLibraryRead {
    let snapshot: TimelineLoadSnapshot
    private(set) var isHeld = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(snapshot: TimelineLoadSnapshot) { self.snapshot = snapshot }

    func load() async -> TimelineLoadSnapshot {
        if !released {
            isHeld = true
            await withCheckedContinuation { continuation = $0 }
            isHeld = false
        }
        return snapshot
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
