import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Recently Deleted listing")
struct RecentlyDeletedListingTests {
    private static func item(_ node: String, at seconds: TimeInterval, video: Bool = false) -> PhotoItem {
        RecentlyDeletedItem.make(
            volumeID: "volume", nodeID: node, captureTime: Date(timeIntervalSince1970: seconds), isVideo: video)
    }

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recently-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theLastListingOpensAfterALaunch() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listing = [Self.item("photo", at: 1), Self.item("video", at: 2, video: true)]
        RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
            .save(.init(listing: listing))

        let reopened = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")

        #expect(reopened.load() == .init(listing: listing))
        let blob = try Data(contentsOf: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        #expect(blob.range(of: Data("photo".utf8)) == nil, "the listing is encrypted at rest")
    }

    @Test func anotherAccountOrKeyCannotOpenTheListing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
            .save(.init(listing: [Self.item("photo", at: 1)]))

        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "other").load()
                == nil)
        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "other", keyPassword: "secret").load()
                == nil)
    }

    @Test func withoutAStoredListingThereIsNothingToShow() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret").load()
                == nil)
    }

    @Test func theListingRegistersItsPhotosNewestFirst() {
        let older = Self.item("older", at: 1)
        let newer = Self.item("newer", at: 2)
        let identities = RecentlyDeletedIdentities(listing: [older, newer])

        #expect(identities.ordered == [newer.uid, older.uid])
    }

    @Test func photosTrashedHereJoinTheStoredListingUntilAListingShowsThem() {
        let listed = Self.item("listed", at: 1)
        let trashedHere = Self.item("trashed-here", at: 5)
        let unknownToTheLibrary = PhotoUID(volumeID: "volume", nodeID: "not-in-library")
        var identities = RecentlyDeletedIdentities(listing: [listed])

        // A listing that started before the trash request cannot know the new photos and changes nothing.
        let early = identities.beginListing()
        identities.trashed([trashedHere.uid, unknownToTheLibrary], items: [trashedHere])
        #expect(identities.ordered == [unknownToTheLibrary, trashedHere.uid, listed.uid])
        #expect(identities.listing == [listed, trashedHere], "a relaunch must keep the photo trashed here")
        let earlyOutcome = identities.received([listed], ticket: early)
        #expect(earlyOutcome == .overtakenByChange)
        #expect(identities.needsListing, "an overtaken listing asks for another one")
        #expect(identities.listing == [listed, trashedHere])

        // The next listing shows the known photo; the other one waits for one more listing.
        receive([listed, trashedHere], into: &identities)
        #expect(identities.ordered == [unknownToTheLibrary, trashedHere.uid, listed.uid])
        #expect(identities.listing == [listed, trashedHere])
        #expect(identities.needsListing)
    }

    @Test func aListingThatLagsBehindTheTrashRequestKeepsThePhotoForOneMoreListing() {
        let listed = Self.item("listed", at: 1)
        let trashedHere = Self.item("trashed-here", at: 5)
        var identities = RecentlyDeletedIdentities(listing: [listed])
        identities.trashed([trashedHere.uid], items: [trashedHere])

        receive([listed], into: &identities)
        #expect(identities.ordered == [trashedHere.uid, listed.uid], "one lagging listing must not release it")
        #expect(identities.needsListing, "another listing must follow")

        receive([listed, trashedHere], into: &identities)
        #expect(identities.listing == [listed, trashedHere])
        #expect(!identities.needsListing)
    }

    @Test func aPhotoTrashedHereAndRestoredElsewhereLeavesWithTheSecondListingThatLacksIt() {
        let listed = Self.item("listed", at: 1)
        let restoredElsewhere = Self.item("restored-elsewhere", at: 5)
        var identities = RecentlyDeletedIdentities(listing: [listed])
        identities.trashed([restoredElsewhere.uid], items: [restoredElsewhere])

        receive([listed], into: &identities)
        receive([listed], into: &identities)

        #expect(identities.ordered == [listed.uid])
        #expect(identities.listing == [listed], "Recently Deleted must not show a photo that is back in the library")
        #expect(!identities.needsListing)
    }

    @Test func aPhotoTrashedHereKeepsItsWaitAcrossARelaunch() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        let listed = Self.item("listed", at: 1)
        let trashedHere = Self.item("trashed-here", at: 5)
        var beforeRelaunch = RecentlyDeletedIdentities(listing: [listed])
        beforeRelaunch.trashed([trashedHere.uid], items: [trashedHere])
        store.save(beforeRelaunch.persisted)

        var afterRelaunch = RecentlyDeletedIdentities(persisted: try #require(store.load()))
        #expect(afterRelaunch.ordered == [trashedHere.uid, listed.uid])
        #expect(afterRelaunch.listing == [listed, trashedHere], "offline, the photo trashed here still shows")

        // One lagging listing after the relaunch must not release it.
        receive([listed], into: &afterRelaunch)
        #expect(afterRelaunch.ordered == [trashedHere.uid, listed.uid])
        #expect(afterRelaunch.needsListing)
    }

    @Test func aRelaunchKeepsMissedListingsAndPhotosWithoutLibraryData() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        let known = Self.item("known", at: 5)
        let unknown = PhotoUID(volumeID: "volume", nodeID: "unknown-to-the-library")
        var beforeRelaunch = RecentlyDeletedIdentities(listing: [])
        beforeRelaunch.trashed([known.uid, unknown], items: [known])
        receive([], into: &beforeRelaunch)
        store.save(beforeRelaunch.persisted)

        let loaded = try #require(store.load())
        #expect(loaded == beforeRelaunch.persisted, "misses and photos without library data must survive")
        #expect(loaded.trashedHere.map(\.misses) == [1, 1])

        // The second listing that lacks them, now after the relaunch, releases both.
        var afterRelaunch = RecentlyDeletedIdentities(persisted: loaded)
        receive([], into: &afterRelaunch)
        #expect(afterRelaunch.ordered.isEmpty)
    }

    @Test func trashingHereAsksForAListingEvenAfterOneApplied() {
        var identities = RecentlyDeletedIdentities(listing: nil)
        receive([], into: &identities)
        #expect(!identities.needsListing)

        identities.trashed([PhotoUID(volumeID: "volume", nodeID: "new")], items: [])

        #expect(identities.needsListing, "a listing must confirm or release the photo trashed here")
    }

    @Test func aFailedListingAsksForAnotherOne() {
        var identities = RecentlyDeletedIdentities(listing: nil)
        #expect(identities.needsListing, "every session lists once")
        receive([], into: &identities)
        #expect(!identities.needsListing)

        identities.listingFailed()

        #expect(identities.needsListing)
    }

    @Test func restoredPhotosStayRegisteredUntilOneRefreshAfterTheLibraryListsThemAgain() {
        let restored = Self.item("restored", at: 1)
        var identities = RecentlyDeletedIdentities(listing: [restored])

        identities.restored([restored.uid])
        #expect(identities.listing == [], "a restored photo leaves the stored listing at once")
        receive([], into: &identities)
        #expect(identities.ordered == [restored.uid])

        // A refresh that does not list it yet keeps it; the refresh that lists it only marks it, because the
        // caller publishes that library afterwards; the next refresh releases it.
        let notListedYet = identities.libraryRefreshed(lists: { _ in false })
        #expect(!notListedYet)
        let listedNow = identities.libraryRefreshed(lists: { $0 == restored.uid })
        #expect(!listedNow)
        #expect(identities.ordered == [restored.uid])
        let listedBefore = identities.libraryRefreshed(lists: { $0 == restored.uid })
        #expect(listedBefore)
        #expect(identities.ordered.isEmpty)
        #expect(!identities.hasRestoredPhotos)
    }

    @Test func aListingThatATrashChangeOvertookChangesNothing() {
        let listed = Self.item("listed", at: 1)
        var identities = RecentlyDeletedIdentities(listing: [listed])

        let ticket = identities.beginListing()
        identities.emptied()
        let outcome = identities.received([listed], ticket: ticket)

        #expect(outcome == .overtakenByChange, "emptied photos must not come back")
        #expect(identities.listing == [])
        #expect(identities.ordered.isEmpty)
    }

    @Test func aListingThatStartedEarlierButFinishedLaterChangesNothing() {
        let trashedElsewhere = Self.item("trashed-elsewhere", at: 2)
        var identities = RecentlyDeletedIdentities(listing: [])

        let slow = identities.beginListing()
        let fast = identities.beginListing()
        let fastOutcome = identities.received([trashedElsewhere], ticket: fast)
        let slowOutcome = identities.received([], ticket: slow)

        #expect(fastOutcome == .applied)
        #expect(slowOutcome == .superseded, "an older listing must not release a photo that a newer one registered")
        #expect(identities.ordered == [trashedElsewhere.uid])
        #expect(!identities.needsListing, "a superseded listing needs no other one")
    }

    private func receive(_ listing: [PhotoItem], into identities: inout RecentlyDeletedIdentities) {
        let ticket = identities.beginListing()
        let outcome = identities.received(listing, ticket: ticket)
        #expect(outcome == .applied)
    }

    @Test func emptyingTheTrashReleasesEveryTrashedPhoto() {
        let listed = Self.item("listed", at: 1)
        let trashedHere = Self.item("trashed-here", at: 2)
        let restored = Self.item("restored", at: 3)
        var identities = RecentlyDeletedIdentities(listing: [listed, restored])
        identities.trashed([trashedHere.uid], items: [trashedHere])
        identities.restored([restored.uid])

        identities.emptied()

        #expect(identities.ordered == [restored.uid])
        #expect(identities.listing == [])
    }
}
