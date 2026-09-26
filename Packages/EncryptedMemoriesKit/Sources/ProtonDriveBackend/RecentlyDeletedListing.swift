import CryptoKit
import Foundation
import PhotosCore

/// One photo of the Recently Deleted listing. The listing proves only identity, capture time, and whether the
/// photo is a video, so every trash item is built here, from a fresh listing and from the stored one alike.
enum RecentlyDeletedItem {
    static func make(volumeID: String, nodeID: String, captureTime: Date, isVideo: Bool) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: nodeID),
            captureTime: captureTime,
            mediaType: isVideo ? "video/quicktime" : "image/jpeg",
            tags: isVideo ? [.videos] : [])
    }
}

/// The last Recently Deleted listing of one account and the photos trashed here that no listing settled yet,
/// AES-GCM sealed next to `library-v1.sqlite`.
///
/// A trashed photo left every inventory, and only a listing proves that the user may read it. Without the
/// stored listing, Recently Deleted could not open offline, and the first cache sweep after a launch removed
/// the thumbnails of every trashed photo. The sign-out purge removes the account directory and with it this file.
struct RecentlyDeletedListingStore: Sendable {
    static let fileName = "recently-deleted-v1.enc"

    private struct Record: Codable {
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

        var item: PhotoItem {
            RecentlyDeletedItem.make(
                volumeID: volumeID, nodeID: nodeID, captureTime: Date(timeIntervalSince1970: captureTime),
                isVideo: isVideo)
        }
    }

    private struct TrashedHereRecord: Codable {
        let volumeID: String
        let nodeID: String
        let item: Record?
        let misses: Int
    }

    private struct Contents: Codable {
        let listing: [Record]?
        let trashedHere: [TrashedHereRecord]
    }

    private let url: URL
    private let key: SymmetricKey

    init(directory: URL, accountUID: String, keyPassword: String) {
        url = directory.appendingPathComponent(Self.fileName)
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("EncryptedMemories.recently-deleted.v1.\(accountUID)".utf8)
        let info = Data("recently-deleted-listing".utf8)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }

    /// The stored state, or nil when there is none or it cannot be opened (another key, corruption).
    func load() -> RecentlyDeletedIdentities.Persisted? {
        guard let blob = try? Data(contentsOf: url),
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(box, using: key),
            let contents = try? JSONDecoder().decode(Contents.self, from: plaintext)
        else { return nil }
        return RecentlyDeletedIdentities.Persisted(
            listing: contents.listing?.map(\.item),
            trashedHere: contents.trashedHere.map {
                .init(
                    uid: PhotoUID(volumeID: $0.volumeID, nodeID: $0.nodeID), item: $0.item?.item,
                    misses: $0.misses)
            })
    }

    /// Best effort: a failed write only means that the next offline launch shows an older listing.
    func save(_ persisted: RecentlyDeletedIdentities.Persisted) {
        let contents = Contents(
            listing: persisted.listing?.map(Record.init),
            trashedHere: persisted.trashedHere.map {
                TrashedHereRecord(
                    volumeID: $0.uid.volumeID, nodeID: $0.uid.nodeID, item: $0.item.map(Record.init),
                    misses: $0.misses)
            })
        guard let plaintext = try? JSONEncoder().encode(contents),
            let sealed = try? AES.GCM.seal(plaintext, using: key).combined
        else { return }
        do {
            try sealed.write(to: url, options: .atomic)
        } catch {
            PhotoDiagnostics.shared.increment("recentlyDeleted.cacheWriteFailed")
        }
    }
}

/// The photos whose thumbnails Recently Deleted may read and keep, newest first.
///
/// A listing is the authority, but it can lag behind a change made here. Photos trashed here join the stored
/// listing at once, so their thumbnails survive a relaunch before a listing shows them. A photo that two listings
/// after the trash request both lack was restored or deleted elsewhere and leaves. Restored photos stay registered
/// until the library lists them again, so their thumbnails never lose their place.
struct RecentlyDeletedIdentities: Sendable, Equatable {
    /// Taken when a listing starts. A listing is stale when a trash change here finished while it ran, or when a
    /// listing that started later was already applied; a stale listing changes nothing.
    struct ListingTicket: Sendable, Equatable {
        fileprivate let start: UInt64
        fileprivate let changes: UInt64
    }

    enum ListingOutcome: Sendable, Equatable {
        case applied
        /// A trash, restore, or Empty Trash request here finished while the listing ran; another listing is needed.
        case overtakenByChange
        /// A listing that started later was already applied.
        case superseded
    }

    /// The last trash listing that the server returned.
    private var receivedListing: [PhotoItem]?
    /// Photos trashed here that no listing has shown yet, oldest request first, with the items the library knew.
    private var trashedHere: [PhotoUID] = []
    private var trashedHereItems: [PhotoUID: PhotoItem] = [:]
    /// Listings since the trash request that lacked the photo. The second one proves that it moved on elsewhere.
    private var trashedHereMisses: [PhotoUID: Int] = [:]
    /// Photos restored here. A library refresh that lists one marks it; the next refresh releases it, because by
    /// then the library that lists it was published.
    private var restoredHere: [PhotoUID] = []
    private var restoredListedByLibrary: Set<PhotoUID> = []
    private var listingStarts: UInt64 = 0
    private var appliedListingStart: UInt64 = 0
    private var changesHere: UInt64 = 0
    /// True until a listing applies: once per session, again after a failed or overtaken listing, and while a
    /// photo trashed here still waits for a listing that shows it.
    private(set) var needsListing = true

    /// What survives a relaunch: the last listing and the photos trashed here that no second listing settled.
    struct Persisted: Sendable, Equatable {
        struct TrashedHere: Sendable, Equatable {
            let uid: PhotoUID
            let item: PhotoItem?
            let misses: Int
        }

        var listing: [PhotoItem]?
        var trashedHere: [TrashedHere] = []
    }

    init(listing: [PhotoItem]?) {
        self.init(persisted: Persisted(listing: listing))
    }

    init(persisted: Persisted) {
        receivedListing = persisted.listing
        for entry in persisted.trashedHere where !trashedHere.contains(entry.uid) {
            trashedHere.append(entry.uid)
            if let item = entry.item { trashedHereItems[entry.uid] = item }
            if entry.misses > 0 { trashedHereMisses[entry.uid] = entry.misses }
        }
    }

    var persisted: Persisted {
        Persisted(
            listing: receivedListing,
            trashedHere: trashedHere.map {
                .init(uid: $0, item: trashedHereItems[$0], misses: trashedHereMisses[$0] ?? 0)
            })
    }

    /// What Recently Deleted shows and stores: the last listing and the photos trashed here that it lacks.
    var listing: [PhotoItem]? {
        let pending = trashedHere.compactMap { trashedHereItems[$0] }
        guard receivedListing != nil || !pending.isEmpty else { return nil }
        var seen = Set<PhotoUID>()
        return ((receivedListing ?? []) + pending)
            .filter { seen.insert($0.uid).inserted }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
    }

    /// Registered identities: photos trashed here first, then the listing newest first, then restored photos.
    var ordered: [PhotoUID] {
        var seen = Set<PhotoUID>()
        let listed = (listing ?? []).reversed().map(\.uid)
        return (trashedHere.reversed() + listed + restoredHere).filter { seen.insert($0).inserted }
    }

    var hasRestoredPhotos: Bool { !restoredHere.isEmpty }

    mutating func beginListing() -> ListingTicket {
        listingStarts &+= 1
        return ListingTicket(start: listingStarts, changes: changesHere)
    }

    /// Applies a listing unless it is stale.
    mutating func received(_ listing: [PhotoItem], ticket: ListingTicket) -> ListingOutcome {
        guard ticket.changes == changesHere else {
            needsListing = true
            return .overtakenByChange
        }
        guard ticket.start > appliedListingStart else { return .superseded }
        appliedListingStart = ticket.start
        receivedListing = listing
        let listed = Set(listing.map(\.uid))
        var kept = Set<PhotoUID>()
        for uid in trashedHere where !listed.contains(uid) {
            let misses = (trashedHereMisses[uid] ?? 0) + 1
            if misses < 2 {
                trashedHereMisses[uid] = misses
                kept.insert(uid)
            }
        }
        trashedHere.removeAll { !kept.contains($0) }
        trashedHereItems = trashedHereItems.filter { kept.contains($0.key) }
        trashedHereMisses = trashedHereMisses.filter { kept.contains($0.key) }
        needsListing = !trashedHere.isEmpty
        return .applied
    }

    mutating func listingFailed() {
        needsListing = true
    }

    /// `items` holds what the library knew about the moved photos; a photo without one is registered only.
    mutating func trashed(_ uids: [PhotoUID], items: [PhotoItem]) {
        changesHere &+= 1
        needsListing = true
        let moved = Set(uids)
        restoredHere.removeAll { moved.contains($0) }
        restoredListedByLibrary.subtract(moved)
        trashedHere.removeAll { moved.contains($0) }
        trashedHere.append(contentsOf: uids)
        trashedHereMisses = trashedHereMisses.filter { !moved.contains($0.key) }
        for item in items where moved.contains(item.uid) { trashedHereItems[item.uid] = item }
    }

    mutating func restored(_ uids: [PhotoUID]) {
        changesHere &+= 1
        let moved = Set(uids)
        receivedListing?.removeAll { moved.contains($0.uid) }
        trashedHere.removeAll { moved.contains($0) }
        trashedHereItems = trashedHereItems.filter { !moved.contains($0.key) }
        trashedHereMisses = trashedHereMisses.filter { !moved.contains($0.key) }
        restoredHere.removeAll { moved.contains($0) }
        restoredListedByLibrary.subtract(moved)
        restoredHere.append(contentsOf: uids)
    }

    /// The trash is empty now; restored photos keep their thumbnails until the library lists them again.
    mutating func emptied() {
        changesHere &+= 1
        receivedListing = []
        trashedHere = []
        trashedHereItems = [:]
        trashedHereMisses = [:]
    }

    /// Called after each library refresh. Releases restored photos that the previous refresh already listed and
    /// marks the ones this refresh lists. Returns whether a photo was released.
    mutating func libraryRefreshed(lists isListed: (PhotoUID) -> Bool) -> Bool {
        let released = restoredHere.filter { restoredListedByLibrary.contains($0) }
        restoredHere.removeAll { restoredListedByLibrary.contains($0) }
        restoredListedByLibrary = Set(restoredHere.filter(isListed))
        return !released.isEmpty
    }
}
