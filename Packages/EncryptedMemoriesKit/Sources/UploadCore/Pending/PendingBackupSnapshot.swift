import Foundation
import PhotosCore

/// The upload state a pending tile shows.
public enum PendingUploadBadge: Sendable, Equatable {
    /// Waiting, checking, retrying or paused: the empty circle.
    case waiting
    /// Bytes are moving: `step` of `BackupProgressStep.count`.
    case uploading(step: Int)
    /// A failure that needs the person; the reason stays in the Backup settings.
    case attention
    /// Backed up; the checkmark shows for a moment.
    case done
    /// Backed up, and the checkmark has shown: no badge.
    case backedUp
}

/// One local photo in the grid, the trash list or the excluded list.
public struct PendingTile: Sendable, Equatable {
    public let key: PendingSourceKey
    /// The grid item. Its UID is in the local namespace and its capture time is floored to whole seconds,
    /// as Proton stores it, so the remote photo sorts into the same second.
    public let item: PhotoItem
    public let revision: UploadBackupRevision?
    /// The Proton photo of this revision, once committed or found as a duplicate. An empty volume ID means
    /// the account's photos volume.
    public let handoff: PhotoUID?
    /// The source settled successfully; the grid may retire the tile once its Proton photo is listed.
    public let isSettled: Bool
    public let badge: PendingUploadBadge
    public let displayName: String

    public init(
        key: PendingSourceKey,
        item: PhotoItem,
        revision: UploadBackupRevision?,
        handoff: PhotoUID?,
        isSettled: Bool,
        badge: PendingUploadBadge,
        displayName: String
    ) {
        self.key = key
        self.item = item
        self.revision = revision
        self.handoff = handoff
        self.isSettled = isSettled
        self.badge = badge
        self.displayName = displayName
    }
}

/// What the pending coordinator publishes. Membership and progress change at different rates: hosts
/// rebuild the grid only when `membershipRevision` changes and redraw badges for `progress` otherwise.
public struct PendingBackupSnapshot: Sendable, Equatable {
    public let membershipRevision: UInt64
    public let progressRevision: UInt64
    /// Grid tiles in `TimelineOrder`.
    public let tiles: [PendingTile]
    /// Progress steps of the few sources whose bytes move right now, keyed by local UID.
    public let progress: [PhotoUID: Int]
    /// Deleted pending photos listed in "Zuletzt gelöscht", newest deletion first.
    public let trashTiles: [PendingTile]
    /// Every excluded, accessible photo for the Backup settings list, newest deletion first.
    public let excludedTiles: [PendingTile]
    /// Desired favorite states of pending photos, keyed by local UID.
    public let favoriteIntents: [PhotoUID: Bool]

    public init(
        membershipRevision: UInt64 = 0,
        progressRevision: UInt64 = 0,
        tiles: [PendingTile] = [],
        progress: [PhotoUID: Int] = [:],
        trashTiles: [PendingTile] = [],
        excludedTiles: [PendingTile] = [],
        favoriteIntents: [PhotoUID: Bool] = [:]
    ) {
        self.membershipRevision = membershipRevision
        self.progressRevision = progressRevision
        self.tiles = tiles
        self.progress = progress
        self.trashTiles = trashTiles
        self.excludedTiles = excludedTiles
        self.favoriteIntents = favoriteIntents
    }

    public static let empty = PendingBackupSnapshot()

    /// The badge for a local tile, including live progress.
    public func badge(for tile: PendingTile) -> PendingUploadBadge {
        if let step = progress[tile.item.uid] { return .uploading(step: step) }
        return tile.badge
    }
}

/// Metadata for pending tiles, supplied by the platform adapter (Photos catalog or file attributes).
public protocol PendingSourceMetadataProviding: Sendable {
    /// Metadata of the sources that are still accessible. A missing key means not accessible (deleted,
    /// or outside a limited Photos selection).
    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata]
}

/// Outcome of one remote effect.
public enum PendingEffectResult: Sendable, Equatable {
    case done
    /// Transport, 408, 429, 5xx or an unknown error.
    case retry
    /// A confirmed terminal condition, for example a deleted album.
    case permanentFailure
}

/// The side effects of pending-grid decisions. The account host implements them with the backup runner,
/// the Photos adapter and the Proton backend.
public protocol PendingBackupEffects: Sendable {
    /// Removes the sources from queued and in-flight backup work.
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool
    /// Enqueues the sources again after a restore.
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool
    /// The account's photos volume, used for link-only handoffs. Nil while unknown.
    func photosVolumeID() async -> String?
    func trashRemote(_ uids: [PhotoUID]) async -> PendingEffectResult
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingEffectResult
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult
}

/// The Proton side of pending decisions, implemented by the backend. Each call reports whether to retry.
public protocol PendingRemoteEffects: Sendable {
    func trash(_ uids: [PhotoUID]) async -> PendingEffectResult
    func restore(_ uids: [PhotoUID]) async -> PendingEffectResult
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult
}
