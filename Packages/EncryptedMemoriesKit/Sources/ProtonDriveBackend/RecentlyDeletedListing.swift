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

/// The last Recently Deleted listing of one account, AES-GCM sealed next to `library-v1.sqlite`.
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

    /// The stored listing, or nil when there is none or it cannot be opened (another key, corruption).
    func load() -> [PhotoItem]? {
        guard let blob = try? Data(contentsOf: url),
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(box, using: key),
            let records = try? JSONDecoder().decode([Record].self, from: plaintext)
        else { return nil }
        return records.map {
            RecentlyDeletedItem.make(
                volumeID: $0.volumeID,
                nodeID: $0.nodeID,
                captureTime: Date(timeIntervalSince1970: $0.captureTime),
                isVideo: $0.isVideo)
        }
    }

    /// Best effort: a failed write only means that the next offline launch shows an older listing.
    func save(_ items: [PhotoItem]) {
        let records = items.map {
            Record(
                volumeID: $0.uid.volumeID,
                nodeID: $0.uid.nodeID,
                captureTime: $0.captureTime.timeIntervalSince1970,
                isVideo: $0.isVideo)
        }
        guard let plaintext = try? JSONEncoder().encode(records),
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
/// A listing is the authority, but it can lag behind a change made here: photos trashed here must keep their
/// thumbnails before the next listing shows them, and restored photos must keep theirs until the library lists
/// them again. Both stay registered for the session; the stored listing alone seeds the next launch.
struct RecentlyDeletedIdentities: Sendable, Equatable {
    private(set) var listing: [PhotoItem]?
    private var trashedHere: [PhotoUID] = []
    private var restoredHere: [PhotoUID] = []

    init(listing: [PhotoItem]?) {
        self.listing = listing
    }

    /// Registered identities: photos trashed here first, then the listing newest first, then restored photos.
    var ordered: [PhotoUID] {
        var seen = Set<PhotoUID>()
        let listed = (listing ?? []).sorted(by: TimelineOrder.areInIncreasingOrder).reversed().map(\.uid)
        return (trashedHere.reversed() + listed + restoredHere).filter { seen.insert($0).inserted }
    }

    mutating func received(_ listing: [PhotoItem]) {
        self.listing = listing
        let listed = Set(listing.map(\.uid))
        trashedHere.removeAll { listed.contains($0) }
    }

    mutating func trashed(_ uids: [PhotoUID]) {
        let moved = Set(uids)
        restoredHere.removeAll { moved.contains($0) }
        trashedHere.removeAll { moved.contains($0) }
        trashedHere.append(contentsOf: uids)
    }

    mutating func restored(_ uids: [PhotoUID]) {
        let moved = Set(uids)
        trashedHere.removeAll { moved.contains($0) }
        restoredHere.removeAll { moved.contains($0) }
        restoredHere.append(contentsOf: uids)
    }

    /// The trash is empty now; restored photos keep their thumbnails until the library lists them again.
    mutating func emptied() {
        listing = []
        trashedHere = []
    }
}
