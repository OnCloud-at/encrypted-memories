import CryptoKit
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

        #expect(reopened.seeding() == .found(.init(listing: listing)))
        let blob = try Data(contentsOf: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        #expect(blob.range(of: Data("photo".utf8)) == nil, "the listing is encrypted at rest")
    }

    @Test func anotherAccountOrKeyCannotOpenTheListing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
            .save(.init(listing: [Self.item("photo", at: 1)]))

        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "other")
                .seeding() == .unknown)
        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "other", keyPassword: "secret")
                .seeding() == .unknown)
    }

    @Test func withoutAStoredListingThereIsNothingToShow() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(
            RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
                .seeding() == .absent)
    }

    // MARK: - Library listings that lag behind a trash

    private static let trashTime = Date(timeIntervalSince1970: 1_000)

    private static func read(
        _ listed: [PhotoUID], restoredElsewhere: [PhotoUID] = [], after seconds: TimeInterval
    ) -> LibraryListingRead {
        LibraryListingRead(
            listed: Set(listed), restoredElsewhere: Set(restoredElsewhere),
            readAt: trashTime.addingTimeInterval(seconds))
    }

    @Test func supportCountTracksPhotosAwaitingAnAcceptedLibraryListing() {
        let uid = Self.item("private-photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        #expect(identities.photosTrashedHereAwaitingLibraryCount == 0)
        identities.trashed([uid, uid], items: [], at: Self.trashTime)
        #expect(identities.photosTrashedHereAwaitingLibraryCount == 1)
        let lagging = Self.read([uid], after: 40)
        _ = identities.libraryAccepted(lagging, now: lagging.readAt)
        #expect(identities.photosTrashedHereAwaitingLibraryCount == 1)
        let caughtUp = Self.read([], after: 90)
        _ = identities.libraryAccepted(caughtUp, now: caughtUp.readAt)
        #expect(identities.photosTrashedHereAwaitingLibraryCount == 0)
    }

    @Test func aLibraryListingThatLagsBehindATrashHereLeavesThePhotoOut() {
        let trashed = Self.item("trashed", at: 1).uid
        let kept = Self.item("kept", at: 2).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([trashed], items: [], at: Self.trashTime)

        let lagging = Self.read([trashed, kept], after: 40)
        #expect(identities.lagging(in: lagging, now: lagging.readAt) == [trashed])
        let released = identities.libraryAccepted(lagging, now: lagging.readAt)
        #expect(!released)

        let caughtUp = Self.read([kept], after: 90)
        #expect(identities.lagging(in: caughtUp, now: caughtUp.readAt).isEmpty)
        let caughtUpReleased = identities.libraryAccepted(caughtUp, now: caughtUp.readAt)
        #expect(caughtUpReleased)
        #expect(!identities.hasPhotosAwaitingLibrary)
        // Restored elsewhere later: the library lists it again and nothing hides it.
        let restored = Self.read([trashed, kept], after: 300)
        #expect(identities.lagging(in: restored, now: restored.readAt).isEmpty)
    }

    @Test func onlyAnAcceptedListingEndsTheWait() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        // A refresh whose events left the photo out reads it before that filter; its listing still returns it.
        let filteredByEvents = Self.read([photo], after: 20)
        let released = identities.libraryAccepted(filteredByEvents, now: filteredByEvents.readAt)
        #expect(!released)
        // A refresh that is discarded after reading a listing without the photo ends nothing.
        let discarded = Self.read([], after: 30)
        #expect(identities.lagging(in: discarded, now: discarded.readAt).isEmpty)

        let next = Self.read([photo], after: 50)
        #expect(identities.lagging(in: next, now: next.readAt) == [photo])
    }

    @Test func aPhotoTrashedAfterTheListingWasReadKeepsWaiting() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        let readBeforeTheTrash = Self.read([], after: -5)
        identities.trashed([photo], items: [], at: Self.trashTime)

        let released = identities.libraryAccepted(readBeforeTheTrash, now: Self.trashTime.addingTimeInterval(1))
        #expect(!released)
        let next = Self.read([photo], after: 10)
        #expect(identities.lagging(in: next, now: next.readAt) == [photo])
    }

    @Test func aPhotoRestoredElsewhereShowsAtOnce() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        let restored = Self.read([photo], restoredElsewhere: [photo], after: 60)
        #expect(identities.lagging(in: restored, now: restored.readAt).isEmpty)
        let released = identities.libraryAccepted(restored, now: restored.readAt)
        #expect(released)
        #expect(!identities.hasPhotosAwaitingLibrary)
    }

    @Test func aPhotoRestoredHereIsNoLongerLeftOut() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        identities.restored([photo])

        #expect(!identities.hasPhotosAwaitingLibrary)
        let listed = Self.read([photo], after: 0)
        #expect(identities.lagging(in: listed, now: listed.readAt).isEmpty)
    }

    @Test func aPhotoThatTheListingKeepsReturningShowsAfterTheLagLimit() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        let later = Self.read([photo], after: RecentlyDeletedIdentities.libraryLagLimit)
        #expect(identities.lagging(in: later, now: later.readAt).isEmpty, "it was restored elsewhere")
        let released = identities.libraryAccepted(later, now: later.readAt)
        #expect(released)
    }

    @Test func aClockThatMovedBackBehindTheTrashEndsTheWait() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        let earlier = Self.read([photo], after: -3_600)
        #expect(identities.lagging(in: earlier, now: earlier.readAt).isEmpty)
        let released = identities.libraryAccepted(earlier, now: earlier.readAt)
        #expect(released)
    }

    @Test func thePhotosAwaitingTheLibraryKeepTheirWaitAcrossARelaunch() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        store.save(identities.persisted)

        let seeded = store.seeding()
        guard case .found(let loaded) = seeded else {
            Issue.record("a saved wait must answer found, not \(seeded)")
            return
        }
        #expect(loaded == identities.persisted)
        let relaunched = RecentlyDeletedIdentities(persisted: loaded)
        let listed = Self.read([photo], after: 30)
        #expect(relaunched.lagging(in: listed, now: listed.readAt) == [photo])
    }

    @Test func aLaggingPhotoLeavesTheSectionsAndTheBurstEntries() {
        let entries = ["trashed", "kept"].map {
            PhotosListEntry(linkID: $0, captureTime: 0, tags: [], relatedPhotos: [])
        }
        let sections = DriveSDKBridge.group(entries, volumeID: "volume")
        let trashed = PhotoUID(volumeID: "volume", nodeID: "trashed")

        let kept = DriveSDKBridge.removing([trashed], from: sections, burstEntries: entries)

        #expect(kept.sections.flatMap(\.items).map(\.uid.nodeID) == ["kept"])
        #expect(kept.burstEntries?.map(\.linkID) == ["kept"])
        #expect(DriveSDKBridge.removing([trashed], from: sections, burstEntries: nil).burstEntries == nil)
    }

    @Test func aLaggingBurstMemberLeavesTheRelatedPhotosOfItsBurst() {
        let burst = PhotoTag.bursts.rawValue
        let entries = [
            PhotosListEntry(
                linkID: "root", captureTime: 0, tags: [burst],
                relatedPhotos: ["member", "trashed"].map(PhotosListEntry.Related.init(linkID:))),
            PhotosListEntry(linkID: "trashed", captureTime: 0, tags: [burst], relatedPhotos: []),
        ]
        let trashed = PhotoUID(volumeID: "volume", nodeID: "trashed")

        let kept = DriveSDKBridge.removing([trashed], from: [], burstEntries: entries)

        #expect(kept.burstEntries?.map(\.linkID) == ["root"])
        #expect(kept.burstEntries?.first?.relatedPhotos.map(\.linkID) == ["member"])
    }

    @Test func aTagOrAlbumListingLeavesOutAPhotoWithoutEndingItsWait() {
        let photo = Self.item("photo", at: 1).uid
        var identities = RecentlyDeletedIdentities(listing: nil)
        identities.trashed([photo], items: [], at: Self.trashTime)

        // A favorites listing that lacks the photo is no proof; only the library listing ends the wait.
        let favorites = Self.read([], after: 30)
        #expect(identities.lagging(in: favorites, now: favorites.readAt).isEmpty)
        let library = Self.read([photo], after: 40)
        #expect(identities.lagging(in: library, now: library.readAt) == [photo])
    }

    // MARK: - Library listings that lag behind a removal that an event showed

    @Test func aRemovalThatAnEarlierRefreshReadKeepsALaterLaggingListingFromShowingThePhoto() {
        let photo = PhotoUID(volumeID: "volume", nodeID: "removed-elsewhere")
        var identities = RecentlyDeletedIdentities(listing: nil)

        // The first refresh reads the removal and commits; its cursor moves past the event.
        _ = identities.eventsRead(.init(removed: ["removed-elsewhere"]), volumeID: "volume", at: Self.trashTime)
        let first = Self.read([photo], after: 0)
        let firstChanged = identities.libraryAccepted(first, now: first.readAt)
        #expect(!firstChanged, "the wait was saved when the events were read")
        #expect(identities.hasPhotosAwaitingLibrary, "the lagging listing still returns it")
        // A second event starts a refresh whose events no longer contain the removal; its listing still lags.
        _ = identities.eventsRead(.init(), volumeID: "volume", at: Self.trashTime.addingTimeInterval(40))
        let second = Self.read([photo], after: 40)
        #expect(identities.lagging(in: second, now: second.readAt) == [photo])
        _ = identities.libraryAccepted(second, now: second.readAt)

        let caughtUp = Self.read([], after: 90)
        #expect(identities.lagging(in: caughtUp, now: caughtUp.readAt).isEmpty)
        _ = identities.libraryAccepted(caughtUp, now: caughtUp.readAt)
        #expect(!identities.hasPhotosAwaitingLibrary)
        #expect(identities.photosTrashedHereAwaitingLibraryCount == 0, "it was not trashed here")
        #expect(identities.persisted == RecentlyDeletedIdentities(listing: nil).persisted, "the ended wait leaves")
    }

    @Test func aRemovalKeepsItsWaitAcrossARelaunch() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = PhotoUID(volumeID: "volume", nodeID: "removed-elsewhere")
        var identities = RecentlyDeletedIdentities(listing: nil)
        let read = identities.eventsRead(.init(removed: ["removed-elsewhere"]), volumeID: "volume", at: Self.trashTime)
        #expect(read, "a new wait must be saved before the cursor moves")
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        store.save(identities.persisted)

        let seeded = store.seeding()
        guard case .found(let saved) = seeded else {
            Issue.record("a saved removal wait must answer found, not \(seeded)")
            return
        }
        var relaunched = RecentlyDeletedIdentities(persisted: saved)
        _ = relaunched.eventsRead(.init(), volumeID: "volume", at: Self.trashTime.addingTimeInterval(60))
        let lagging = Self.read([photo], after: 60)
        #expect(relaunched.lagging(in: lagging, now: lagging.readAt) == [photo])
        let relaunchChanged = relaunched.libraryAccepted(lagging, now: lagging.readAt)
        #expect(!relaunchChanged, "nothing changed since the save")
    }

    @Test func lostEventsEndTheWaitOfARemovalSoARestoreElsewhereShows() {
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        var identities = RecentlyDeletedIdentities(listing: nil)
        _ = identities.eventsRead(.init(removed: ["photo"]), volumeID: "volume", at: Self.trashTime)

        let lost = identities.eventsLost()

        #expect(lost, "the cleared wait must be saved")
        #expect(!identities.hasPhotosAwaitingLibrary)
        let lostAgain = identities.eventsLost()
        #expect(!lostAgain)
        let listed = Self.read([photo], after: 30)
        #expect(identities.lagging(in: listed, now: listed.readAt).isEmpty)
    }

    @Test func anEventThatShowsTheRemovedFileActiveAgainEndsTheWaitAtOnce() {
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        var identities = RecentlyDeletedIdentities(listing: nil)
        _ = identities.eventsRead(.init(removed: ["photo"]), volumeID: "volume", at: Self.trashTime)

        // A refresh that reads the restore and is discarded later must not hide the photo on the next try.
        let restoredRead = identities.eventsRead(
            .init(active: ["photo"]), volumeID: "volume", at: Self.trashTime.addingTimeInterval(30))
        #expect(restoredRead, "the ended wait must be saved")

        #expect(!identities.hasPhotosAwaitingLibrary)
        let listed = Self.read([photo], after: 40)
        #expect(identities.lagging(in: listed, now: listed.readAt).isEmpty)
    }

    @Test func aRemovedFileRestoredHereIsNoLongerLeftOut() {
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        var identities = RecentlyDeletedIdentities(listing: nil)
        _ = identities.eventsRead(.init(removed: ["photo"]), volumeID: "volume", at: Self.trashTime)

        identities.restored([photo])

        #expect(!identities.hasPhotosAwaitingLibrary)
        let listed = Self.read([photo], after: 10)
        #expect(identities.lagging(in: listed, now: listed.readAt).isEmpty)
    }

    @Test func aRemovalReadAgainByARetriedRefreshWaitsFromItsFirstRead() {
        let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
        var identities = RecentlyDeletedIdentities(listing: nil)
        _ = identities.eventsRead(.init(removed: ["photo"]), volumeID: "volume", at: Self.trashTime)
        // A discarded refresh keeps the cursor, so the retry reads the same removal again.
        let retry = Self.trashTime.addingTimeInterval(500)
        _ = identities.eventsRead(.init(removed: ["photo"]), volumeID: "volume", at: retry)

        let later = Self.read([photo], after: RecentlyDeletedIdentities.libraryLagLimit)
        #expect(identities.lagging(in: later, now: later.readAt).isEmpty, "the age counts from the first read")
        _ = identities.libraryAccepted(later, now: later.readAt)
        #expect(!identities.hasPhotosAwaitingLibrary)
    }

    @Test func aSeedingReadAnswersUnknownForAFileItCannotOpenAndKeepsThatFileFromASave() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A real saved listing first, so the unreadable blob below holds state that a save must not lose.
        let listed = Self.item("listed", at: 1)
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        store.save(.init(listing: [listed]))
        // Bytes that no key can open: the seeding read must answer unknown, never absent.
        try Data("not a listing".utf8)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))

        let seeded = store.seeding()

        #expect(seeded == .unknown, "a file that cannot be opened proves nothing about the stored listing")
        // Unknown proves nothing, so no save may replace the file that the store could not open.
        store.save(RecentlyDeletedIdentities.Persisted())
        #expect(
            store.seeding() == .unknown,
            "the failed save kept the unreadable file: a later seeding read answers unknown again")
    }

    private static func corruptFileURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("recently-deleted-v1.corrupt")
    }

    /// The key opens the seal and the plaintext does not decode: the file proves its own corruption,
    /// so the repair moves it aside and the store answers absent, as an empty store does (#1578).
    @Test func aSeedingReadRepairsAFileThatOpensWithTheKeyButDoesNotDecode() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Plaintext that this build cannot decode, sealed with the right key.
        try #require(try AES.GCM.seal(Data("{\"listing\": 3}".utf8), using: Self.listingKey).combined)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")

        let seeded = store.seeding()

        #expect(seeded == .absent, "a file that no key can rescue proves its own corruption: the store starts fresh")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    RecentlyDeletedListingStore.fileName
                ).path),
            "the repair moved the corrupt file away from the normal name")
        let kept = try Data(contentsOf: Self.corruptFileURL(directory))
        #expect(
            try AES.GCM.open(AES.GCM.SealedBox(combined: kept), using: Self.listingKey)
                == Data("{\"listing\": 3}".utf8),
            "the kept copy holds the corrupt bytes for inspection")

        // The fresh state holds nothing from the corrupt file, and saves go through again.
        store.save(RecentlyDeletedIdentities.Persisted())
        let seededAfterSave = store.seeding()
        guard case .found(let fresh) = seededAfterSave else {
            Issue.record("after the repair a save must answer found, not \(seededAfterSave)")
            return
        }
        #expect(fresh == RecentlyDeletedIdentities.Persisted(), "the fresh state holds nothing from the corrupt file")
        // The fresh state settles a listing normally.
        var identities = RecentlyDeletedIdentities(persisted: fresh)
        let listed = Self.item("listed", at: 1)
        let outcome = identities.received([listed], ticket: identities.beginListing())
        #expect(outcome == .applied, "a fresh listing settles the repaired store normally")
        #expect(identities.listing == [listed], "the settled listing holds only the new listing")
    }

    /// A move aside that fails leaves the store untouched: unknown answer, save block, original bytes, and the
    /// earlier kept copy. Only the move fails here: a non-empty directory at the kept-copy name denies the
    /// rename, while the original, the account directory, and a probe save all stay writable. A probe save that
    /// would wrongly succeed proves a missing save block, and the surviving original bytes prove that it did
    /// not run (#1578).
    @Test func aRepairThatCannotMoveTheFileAsideChangesNothing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent(RecentlyDeletedListingStore.fileName)
        try #require(try AES.GCM.seal(Data("{\"listing\": 3}".utf8), using: Self.listingKey).combined)
            .write(to: originalURL)
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        // A non-empty directory at the kept-copy name denies only the rename: rename(2) refuses to replace a
        // directory with a file (EISDIR), so nothing else is denied.
        let kept = Self.corruptFileURL(directory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: false)
        try Data("inner".utf8).write(to: kept.appendingPathComponent("inner.txt"))

        let seeded = store.seeding()

        #expect(seeded == .unknown, "when the move aside fails the store still proves nothing about the file")
        // The probe save must be able to write (everything but the rename is writable), so a fresh write over
        // the original name would succeed if the save block were missing.
        store.save(RecentlyDeletedIdentities.Persisted())
        #expect(
            store.seeding() == .unknown,
            "the failed repair keeps the save block: no fresh write over the original name")
        let original = try Data(contentsOf: originalURL)
        #expect(
            try AES.GCM.open(AES.GCM.SealedBox(combined: original), using: Self.listingKey)
                == Data("{\"listing\": 3}".utf8),
            "the original file keeps its bytes")
        #expect(
            FileManager.default.fileExists(atPath: kept.appendingPathComponent("inner.txt").path),
            "the non-empty directory stays: the rename did not replace it")
    }

    /// A rename that fails leaves the earlier kept copy whole: the original cannot be renamed away (here it is
    /// immutable, EPERM), so the kept bytes stay at their name. An implementation that removes the kept copy
    /// before a move that fails destroys it in the gap between removal and move (#1578).
    @Test func theMoveAsideFailureKeepsTheEarlierKeptCopyWhole() throws {
        let directory = try Self.directory()
        let originalURL = directory.appendingPathComponent(RecentlyDeletedListingStore.fileName)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: originalURL.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try #require(try AES.GCM.seal(Data("{\"listing\": 3}".utf8), using: Self.listingKey).combined)
            .write(to: originalURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: originalURL.path)
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        try Data("kept bytes of an earlier repair".utf8).write(to: Self.corruptFileURL(directory))

        let seeded = store.seeding()

        #expect(seeded == .unknown, "when the move aside fails the store still proves nothing about the file")
        #expect(
            try Data(contentsOf: Self.corruptFileURL(directory)) == Data("kept bytes of an earlier repair".utf8),
            "the earlier kept copy survives the failed move: no gap destroys it")
    }

    /// Reads and saves never interleave: one critical section covers the seeding read with its classification
    /// and move aside, and another covers the save block check with its write. Without it, a save that lands
    /// between a read and its repair is moved aside as if it were the corrupt file: the kept copy would hold
    /// fresh valid bytes and the store would answer absent with the saved state lost (#1578).
    @Test func concurrentReadsAndSavesNeverMoveFreshStateAside() throws {
        // A large undecodable plaintext widens the classification window, so the racy interleaving of the old
        // shape is likely to fire within the iterations instead of relying on luck.
        let corruptPlaintext = Data(count: 512 * 1024)
        let corruptBlob = try AES.GCM.seal(corruptPlaintext, using: Self.listingKey).combined!
        let valid = RecentlyDeletedIdentities.Persisted(listing: [Self.item("listed", at: 1)])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recently-deleted-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 0..<400 {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try corruptBlob.write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
            let store = RecentlyDeletedListingStore(
                directory: directory, accountUID: "account", keyPassword: "secret")
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0, 1: _ = store.seeding()
                default: store.save(valid)
                }
            }
            // The invariant: only corrupt bytes ever sit at the kept-copy name. A save that slipped between a
            // read and its repair moved fresh valid bytes aside instead of the corrupt file.
            let kept = Self.corruptFileURL(directory)
            if FileManager.default.fileExists(atPath: kept.path) {
                #expect(
                    (try? Data(contentsOf: kept)) == corruptBlob,
                    "the kept copy must hold the corrupt bytes, never a fresh saved state")
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Only a corrupt file replaces the kept copy; a normal save never touches it.
    @Test func aNormalSaveNeverTouchesTheKeptCopyOfACorruptFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(try AES.GCM.seal(Data("{\"listing\": 3}".utf8), using: Self.listingKey).combined)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        _ = store.seeding()
        let keptAfterRepair = try Data(contentsOf: Self.corruptFileURL(directory))

        let listed = Self.item("listed", at: 1)
        store.save(RecentlyDeletedIdentities.Persisted(listing: [listed]))

        let keptAfterSave = try Data(contentsOf: Self.corruptFileURL(directory))
        #expect(keptAfterSave == keptAfterRepair, "a save of the fresh state keeps the corrupt bytes aside")
        // The repair of another corrupt file replaces the kept copy, because only corrupt bytes may replace it.
        try #require(try AES.GCM.seal(Data("{\"other\": true}".utf8), using: Self.listingKey).combined)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let reopened = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        _ = reopened.seeding()
        let keptAfterSecondRepair = try Data(contentsOf: Self.corruptFileURL(directory))
        #expect(
            try AES.GCM.open(AES.GCM.SealedBox(combined: keptAfterSecondRepair), using: Self.listingKey)
                == Data("{\"other\": true}".utf8),
            "a later corrupt file replaces the kept copy")
    }

    /// The kept copy lives in the account directory, so the real sign-out purge removes it with the account.
    /// The account directory carries the backup exclusion, so everything in it, the kept copy included, stays
    /// out of backups; the kept copy itself needs no own flag.
    @Test func theSignOutPurgeRemovesTheKeptCopyWithTheAccountDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recently-deleted-purge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = LibraryDatabaseLocation.prepareAccountDirectory(uid: "account", in: base)
        try #require(try AES.GCM.seal(Data("{\"listing\": 3}".utf8), using: Self.listingKey).combined)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        _ = store.seeding()
        let kept = Self.corruptFileURL(directory)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(kept.deletingLastPathComponent() == directory, "the kept copy lives in the account directory")
        #expect(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
            "the account directory is excluded from backups, so the kept copy inherits the exclusion")

        #expect(LibraryDatabaseLocation.purgeAccountData(uid: "account", in: base))

        #expect(!FileManager.default.fileExists(atPath: kept.path))
    }

    /// A regular file that exists but whose bytes cannot be read (here: permission bits) proves nothing about
    /// the stored state: unknown, never absent, and the save block holds (#1578, trap of the journal fixtures:
    /// the unreadable fixture must stay a regular file).
    @Test func anUnreadableRegularFileBlocksSavesLikeAnUnopenableFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("bytes no account can read now".utf8)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName).path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName).path)
        }
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")

        let seeded = store.seeding()

        #expect(seeded == .unknown, "an existing file that cannot be read proves nothing: unknown, never absent")
        store.save(RecentlyDeletedIdentities.Persisted())
        #expect(
            store.seeding() == .unknown,
            "the unreadable file keeps the save block: no save replaces the bytes that may still open")
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName).path),
            "the unreadable file keeps its place")
    }

    /// A path at the store name that points nowhere proves nothing about the stored state: the open fails with
    /// the same ENOENT as a missing path, so absence is proven only when the path itself is missing too.
    /// A dangling symlink answers unknown, never absent, and the save block holds (#1578).
    @Test func aDanglingSymlinkBlocksSavesLikeAnUnreadableFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RecentlyDeletedListingStore.fileName)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: directory.appendingPathComponent("no-such-target"))
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")

        let seeded = store.seeding()

        #expect(seeded == .unknown, "a path that points nowhere proves nothing: unknown, never absent")
        store.save(RecentlyDeletedIdentities.Persisted())
        #expect(
            store.seeding() == .unknown,
            "the dangling path keeps the save block: no save replaces what may still resolve")
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil,
            "the store never wrote over the dangling path")
    }

    /// A well-formed sealed box of another key and a box with a flipped bit both fail to open: they stay
    /// unknown with the save block, and the bytes stay untouched. The key distinction guards the repair.
    @Test func aFileOfAnotherKeyOrWithFlippedBitsNeverEntersTheRepair() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A valid seal of a different key.
        let otherKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data("secret".utf8)),
            salt: Data("EncryptedMemories.recently-deleted.v1.other-account".utf8),
            info: Data("recently-deleted-listing".utf8), outputByteCount: 32)
        let wrongKeyBlob = try AES.GCM.seal(Data("{\"listing\": []}".utf8), using: otherKey).combined!
        try wrongKeyBlob.write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        #expect(store.seeding() == .unknown, "another key proves nothing: unknown, no repair")
        let writtenWrongKey = try Data(
            contentsOf: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        #expect(wrongKeyBlob == writtenWrongKey, "another key's bytes stay untouched")

        // A valid seal of the held key with one flipped bit in the ciphertext body.
        let own = try AES.GCM.seal(
            Data("{\"listing\": [], \"trashedHere\": []}".utf8), using: Self.listingKey
        ).combined!
        var corrupted = [UInt8](own)
        corrupted[corrupted.count / 2] ^= 0xFF
        try Data(corrupted).write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        #expect(store.seeding() == .unknown, "flipped bits prove nothing: unknown, no repair")
        let writtenFlipped = try Data(
            contentsOf: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        #expect(Data(corrupted) == writtenFlipped, "the flipped bytes stay untouched")
        store.save(RecentlyDeletedIdentities.Persisted())
        #expect(
            store.seeding() == .unknown,
            "the flipped bytes keep the save block: no save replaces what may still open elsewhere")
    }

    @Test func aSeedingReadAnswersAbsentWhenThereIsNoFileAndFoundForAReadableOne() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")

        #expect(store.seeding() == .absent, "no file yet proves that no state is stored")

        let listed = Self.item("listed", at: 1)
        store.save(RecentlyDeletedIdentities.Persisted(listing: [listed]))
        let seeded = store.seeding()
        guard case .found(let persisted) = seeded else {
            Issue.record("a readable file answers found, not \(seeded)")
            return
        }
        #expect(persisted.listing == [listed], "the found answer carries the stored state")
    }

    @Test func aFileOfAnEarlierBuildOpensWithoutPhotosAwaitingTheLibrary() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // v1.0.5 RecentlyDeletedListing.swift:26-56 has no awaitingLibrary field.
        let listed = Self.item("listed", at: 1)
        let moved = Self.item("moved", at: 2, video: true)
        let contents = V105Contents(
            listing: [V105Record(listed)],
            trashedHere: [
                V105TrashedHere(volumeID: "volume", nodeID: "moved", item: V105Record(moved), misses: 1),
                V105TrashedHere(volumeID: "volume", nodeID: "unknown", item: nil, misses: 0),
            ])
        let plaintext = try JSONEncoder().encode(contents)
        try #require(try AES.GCM.seal(plaintext, using: Self.listingKey).combined)
            .write(to: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))

        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        let seeded = store.seeding()
        guard case .found(let loaded) = seeded else {
            Issue.record("a file of an earlier build must answer found, not \(seeded)")
            return
        }

        #expect(loaded.listing == [listed])
        #expect(loaded.trashedHere.map(\.uid.nodeID) == ["moved", "unknown"])
        #expect(loaded.trashedHere.map(\.misses) == [1, 0])
        #expect(loaded.trashedHere.first?.item == moved)
        #expect(loaded.trashedHere.last?.item == nil)
        #expect(loaded.trashedAwaitingLibrary.isEmpty)
    }

    @Test func aV105ReaderIgnoresAwaitingLibraryInAFileOfTheNewBuild() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listed = Self.item("listed", at: 1)
        let moved = Self.item("moved", at: 2, video: true)
        let state = RecentlyDeletedIdentities.Persisted(
            listing: [listed], trashedHere: [.init(uid: moved.uid, item: moved, misses: 1)],
            trashedAwaitingLibrary: [moved.uid: Self.trashTime])
        let store = RecentlyDeletedListingStore(directory: directory, accountUID: "account", keyPassword: "secret")
        store.save(state)
        #expect(
            store.seeding() == .found(state), "The file must contain a nonempty wait before the old reader opens it")
        let blob = try Data(contentsOf: directory.appendingPathComponent(RecentlyDeletedListingStore.fileName))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: Self.listingKey)

        // Decode the actual new writer's file with the v1.0.5 Contents shape, which has no wait field.
        let old = try JSONDecoder().decode(V105Contents.self, from: plaintext)

        #expect(old.listing == [V105Record(listed)])
        #expect(
            old.trashedHere == [
                V105TrashedHere(volumeID: "volume", nodeID: "moved", item: V105Record(moved), misses: 1)
            ])
    }

    // v1.0.5 RecentlyDeletedListing.swift:26-56 defines these stored records.
    private struct V105Record: Codable, Equatable {
        let volumeID: String
        let nodeID: String
        let captureTime: Double
        let isVideo: Bool

        init(_ item: PhotoItem) {
            volumeID = item.uid.volumeID
            nodeID = item.uid.nodeID
            captureTime = item.captureTime.timeIntervalSince1970
            isVideo = item.isVideo
        }
    }

    private struct V105TrashedHere: Codable, Equatable {
        let volumeID: String
        let nodeID: String
        let item: V105Record?
        let misses: Int
    }

    private struct V105Contents: Codable {
        let listing: [V105Record]?
        let trashedHere: [V105TrashedHere]
    }

    // v1.0.5 RecentlyDeletedListing.swift:61-66 derives the encryption key this way.
    private static var listingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data("secret".utf8)),
            salt: Data("EncryptedMemories.recently-deleted.v1.account".utf8),
            info: Data("recently-deleted-listing".utf8), outputByteCount: 32)
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

        let seeded = store.seeding()
        guard case .found(let saved) = seeded else {
            Issue.record("a saved trashed-here photo must answer found, not \(seeded)")
            return
        }
        var afterRelaunch = RecentlyDeletedIdentities(persisted: saved)
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

        let seeded = store.seeding()
        guard case .found(let loaded) = seeded else {
            Issue.record("saved misses must answer found, not \(seeded)")
            return
        }
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
