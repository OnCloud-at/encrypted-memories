import Foundation
import PhotosCore

/// Remote reads and writes that replace an earlier upload with the edited photo. The backend implements it.
public protocol EditReplacementRemote: PhotoCarryOverRemote {
    /// Moves the photos to the Proton trash, where the person can restore them.
    func trash(_ uids: [PhotoUID]) async throws
}

/// Replaces the earlier upload of an edited photo, so the library shows the photo once.
///
/// The backup calls it after the edited photo and all its secondaries are uploaded. The original is one of these
/// secondaries, so it stays in the backup as a related photo of the edited photo. The earlier photo passes its
/// favorite tag and its albums of the own library to the edited photo, then moves to the trash with its related
/// photos. Every step reads the server state again, so a retry after a failure repeats no write twice.
///
/// An earlier photo stays when the new compound does not hold the original, when another local source still
/// needs it or one of its related photos, or when it carries the new photo.
public struct EditedPhotoReplacement: Sendable {
    let remote: any EditReplacementRemote
    let albums: any SeriesAlbumCarryOver
    let relations: any UploadDuplicateChecking
    let identities: any UploadIdentityStore
    let journal: any EditReplacementJournaling

    public init(
        remote: any EditReplacementRemote,
        albums: any SeriesAlbumCarryOver,
        relations: any UploadDuplicateChecking,
        identities: any UploadIdentityStore,
        journal: any EditReplacementJournaling
    ) {
        self.remote = remote
        self.albums = albums
        self.relations = relations
        self.identities = identities
        self.journal = journal
    }

    /// True when the new compound keeps the original in the backup: an unedited primary is the original itself,
    /// an edited one carries it as an original secondary. Only then may the earlier photo leave.
    public static func holdsOriginal(
        editRevision: UploadBackupEditRevision,
        secondaries: [UploadSourceIdentity.Resource]
    ) -> Bool {
        if case .revision = editRevision { return true }
        let originals = ["originalPhoto", "originalVideo"].map { "photoKit.\($0)." }
        return secondaries.contains { resource in originals.contains { resource.rawValue.hasPrefix($0) } }
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
    public func replaceSuperseded(
        of source: UploadSourceIdentity,
        with primary: PhotoUID,
        holdsOriginal: Bool
    ) async throws -> Bool {
        let superseded = journal.entry(for: source).superseded
        guard !superseded.isEmpty else { return false }
        guard holdsOriginal else {
            try keepSuperseded(of: source)
            return false
        }
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
            // The trash takes related photos along. A photo that carries the edited photo stays, and so does a
            // photo that another local source, such as a duplicate in Photos, still counts as its backup.
            guard !linked.contains(replacement.nodeID),
                !isNeededElsewhere(linked.union([target.nodeID]), by: source)
            else {
                kept.insert(target.nodeID)
                continue
            }
            trashable.append(target)
            related.formUnion(linked)
        }
        try await carryOver(from: trashable, to: replacement, ownVolumeID: volumeID)
        if !trashable.isEmpty {
            // Durable before the trash: a retry after a crash finds the related photos trashed and could no longer
            // list them, and an undo must not take their trashed copies for a deletion by the person.
            try journal.settle([], related: related, trashed: true, for: source)
            try await remote.trash(trashable)
        }
        let retired = Set(targets.map(\.nodeID)).subtracting(kept)
        try journal.settle(retired, related: related, trashed: true, for: source)
        try journal.settle(kept, related: [], trashed: false, for: source)
        return !trashable.isEmpty
    }

    private func isNeededElsewhere(_ linkIDs: Set<String>, by source: UploadSourceIdentity) -> Bool {
        linkIDs.contains { linkID in
            guard let sources = identities.sources(withRemoteLinkID: linkID) else { return true }
            return sources.contains { $0.kind != source.kind || $0.identifier != source.identifier }
        }
    }

    private func carryOver(from earlier: [PhotoUID], to replacement: PhotoUID, ownVolumeID: String) async throws {
        guard !earlier.isEmpty else { return }
        let favorites = try await remote.favoriteUIDs(among: earlier + [replacement])
        if !favorites.contains(replacement), earlier.contains(where: favorites.contains) {
            try await remote.markFavorite([replacement])
        }
        for albumID in try await albums.ownAlbumIDs(containing: earlier, ownVolumeID: ownVolumeID) {
            try Task.checkCancellation()
            // An existing membership counts as success, so a retry adds nothing twice.
            try await albums.addPhotos([replacement], toOwnAlbum: albumID)
        }
    }
}
