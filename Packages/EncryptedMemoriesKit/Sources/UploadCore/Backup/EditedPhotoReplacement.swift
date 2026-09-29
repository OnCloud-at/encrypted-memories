import Foundation
import PhotosCore

/// Remote reads and writes that replace an earlier upload with the edited photo. The backend implements it.
public protocol EditReplacementRemote: Sendable {
    /// The account's own photos volume.
    func ownPhotosVolumeID() async throws -> String
    /// The subset of `uids` that are active photos now: not trashed, not deleted, not drafts.
    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID>
    /// The subset of `uids` that carry Proton's favorite tag now.
    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID>
    /// Adds Proton's favorite tag to the photos. Fails when any photo does not confirm the tag.
    func markFavorite(_ uids: [PhotoUID]) async throws
    /// Moves the photos to the Proton trash, where the person can restore them.
    func trash(_ uids: [PhotoUID]) async throws
}

/// Replaces the earlier upload of an edited photo, so the library shows the photo once.
///
/// The backup calls it after the edited photo and all its secondaries are uploaded. The original is one of these
/// secondaries, so it stays in the backup as a related photo of the edited photo. The earlier photo passes its
/// favorite tag and its albums of the own library to the edited photo, then moves to the trash with its related
/// photos. Every step reads the server state again, so a retry after a failure repeats no write twice.
public struct EditedPhotoReplacement: Sendable {
    let remote: any EditReplacementRemote
    let albums: any SeriesAlbumCarryOver
    let relations: any UploadDuplicateChecking
    let journal: any EditReplacementJournaling

    public init(
        remote: any EditReplacementRemote,
        albums: any SeriesAlbumCarryOver,
        relations: any UploadDuplicateChecking,
        journal: any EditReplacementJournaling
    ) {
        self.remote = remote
        self.albums = albums
        self.relations = relations
        self.journal = journal
    }

    /// True while an edit of `source` waits to replace its earlier upload. Its secondaries must then upload under
    /// the edited photo, because their earlier copies move to the trash with the earlier photo.
    public func isReplacing(_ source: UploadSourceIdentity) -> Bool {
        !journal.entry(for: source).superseded.isEmpty
    }

    /// Keeps the earlier uploads of `source`. A series keeps today's behavior until its own edit model exists.
    public func keepSuperseded(of source: UploadSourceIdentity) throws {
        let superseded = journal.entry(for: source).superseded
        guard !superseded.isEmpty else { return }
        try journal.settle(Set(superseded.map(\.nodeID)), related: [], trashed: false, for: source)
    }

    /// Returns true when photos moved to the trash, so cached duplicate rows that still show them active are stale.
    @discardableResult
    public func replaceSuperseded(of source: UploadSourceIdentity, with primary: PhotoUID) async throws -> Bool {
        let superseded = journal.entry(for: source).superseded
        guard !superseded.isEmpty else { return false }
        let volumeID = try await remote.ownPhotosVolumeID()
        func resolved(_ uid: PhotoUID) -> PhotoUID {
            uid.volumeID.isEmpty ? PhotoUID(volumeID: volumeID, nodeID: uid.nodeID) : uid
        }
        let replacement = resolved(primary)
        // The edit was undone and the earlier photo is the current one again.
        var kept = Set(superseded.map(\.nodeID).filter { $0 == replacement.nodeID })
        let targets = superseded.map(resolved).filter { $0.nodeID != replacement.nodeID }
        let active = try await remote.activeUIDs(among: targets)
        var trashable: [PhotoUID] = []
        var related: Set<String> = []
        for target in targets where active.contains(target) {
            try Task.checkCancellation()
            let linked = try await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
            // The trash takes related photos along. A photo that carries the edited photo stays.
            guard !linked.contains(replacement.nodeID) else {
                kept.insert(target.nodeID)
                continue
            }
            trashable.append(target)
            related.formUnion(linked)
        }
        try await carryOver(from: trashable, to: replacement, ownVolumeID: volumeID)
        if !trashable.isEmpty {
            try await remote.trash(trashable)
        }
        let retired = Set(targets.map(\.nodeID)).subtracting(kept)
        try journal.settle(retired, related: related, trashed: true, for: source)
        try journal.settle(kept, related: [], trashed: false, for: source)
        return !trashable.isEmpty
    }

    private func carryOver(from earlier: [PhotoUID], to replacement: PhotoUID, ownVolumeID: String) async throws {
        guard !earlier.isEmpty else { return }
        let favorites = try await remote.favoriteUIDs(among: earlier + [replacement])
        if !favorites.contains(replacement), earlier.contains(where: favorites.contains) {
            try await remote.markFavorite([replacement])
        }
        var albumIDs: [String] = []
        for uid in earlier {
            for album in try await albums.albums(containing: uid)
            where album.volumeID == ownVolumeID && !albumIDs.contains(album.albumID) {
                albumIDs.append(album.albumID)
            }
        }
        for albumID in albumIDs {
            try Task.checkCancellation()
            // An existing membership counts as success, so a retry adds nothing twice.
            try await albums.addPhotos([replacement], toOwnAlbum: albumID)
        }
    }
}
