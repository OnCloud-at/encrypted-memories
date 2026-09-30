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
/// An earlier photo stays when the new compound does not hold the original, when an original resource of the photo
/// lives only under the earlier photo, when another local source still needs it or one of its related photos, or
/// when it carries the new photo. Other bytes replace the earlier photo only as an edit or as the undo of an edit.
public struct EditedPhotoReplacement: Sendable {
    let remote: any EditReplacementRemote
    let albums: any SeriesAlbumCarryOver
    let relations: any UploadDuplicateChecking
    let identities: any UploadIdentityStore
    public let journal: any EditReplacementJournaling

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

    /// Returns true when earlier photos left the library, so cached duplicate rows that still show them active are
    /// stale. `edited` tells whether the new primary is an edit; the backup calls this after each upload of a photo.
    @discardableResult
    public func replaceSuperseded(
        of source: UploadSourceIdentity,
        with primary: PhotoUID,
        edited: Bool,
        holdsOriginal: Bool
    ) async throws -> Bool {
        let entry = journal.entry(for: source)
        let superseded = entry.superseded
        // Other bytes of a photo that is unedited now and was unedited before are no edit, so both photos stay.
        guard !superseded.isEmpty, edited || entry.lastUploadWasEdit else {
            try keepSuperseded(of: source)
            try recordUpload(of: source, edited: edited)
            return false
        }
        // The earlier photos may hold the only copy of the original. They wait for an upload that holds it.
        guard holdsOriginal else {
            try recordUpload(of: source, edited: edited)
            return false
        }
        let volumeID = try await remote.ownPhotosVolumeID()
        func resolved(_ uid: PhotoUID) -> PhotoUID {
            uid.volumeID.isEmpty ? PhotoUID(volumeID: volumeID, nodeID: uid.nodeID) : uid
        }
        let replacement = resolved(primary)
        // The edit was undone and the earlier photo is the current one again.
        var kept = Set(superseded.map(\.nodeID).filter { $0 == replacement.nodeID })
        var waiting: Set<String> = []
        let targets = superseded.map(resolved).filter { $0.nodeID != replacement.nodeID }
        let active = try await remote.activeUIDs(among: targets)
        var trashable: [PhotoUID] = []
        var related: Set<String> = []
        for target in targets where active.contains(target) {
            try Task.checkCancellation()
            let linked = try await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
            let links = linked.union([target.nodeID])
            // The trash takes related photos along. A photo that carries the edited photo stays, and so does a
            // photo that another local source, such as a duplicate in Photos, still counts as its backup.
            guard !linked.contains(replacement.nodeID), !isNeededElsewhere(links, by: source) else {
                kept.insert(target.nodeID)
                continue
            }
            // An original resource of this photo lives only there. The photo waits for an upload that carries it.
            guard !leavesOriginalBehind(links, of: source, primaryIsOriginal: !edited) else {
                waiting.insert(target.nodeID)
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
        let retired = Set(targets.map(\.nodeID)).subtracting(kept).subtracting(waiting)
        // A row of this photo that names a trashed photo no longer proves a backup. The journal's retired links
        // include the related photos of an earlier attempt, so a retry after a failed write forgets them too.
        let trashedLinks = retired.union(related).union(journal.entry(for: source).retired)
        guard identities.forgetRemoteLinks(trashedLinks, of: source) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
        try journal.settle(retired, related: related, trashed: true, for: source)
        try journal.settle(kept, related: [], trashed: false, for: source)
        try recordUpload(of: source, edited: edited)
        return !retired.isEmpty
    }

    private func recordUpload(of source: UploadSourceIdentity, edited: Bool) throws {
        guard source.kind == .photoLibraryAsset else { return }
        try journal.recordUpload(edited: edited, for: source)
    }

    private func isNeededElsewhere(_ linkIDs: Set<String>, by source: UploadSourceIdentity) -> Bool {
        linkIDs.contains { linkID in
            guard let sources = identities.sources(withRemoteLinkID: linkID) else { return true }
            return sources.contains { $0.kind != source.kind || $0.identifier != source.identifier }
        }
    }

    /// True when a row of `source` with an original resource still names one of `linkIDs`: the new compound did not
    /// upload that resource again, because its rows moved to the new photos. An unedited primary is the original
    /// photo or video itself.
    private func leavesOriginalBehind(
        _ linkIDs: Set<String>, of source: UploadSourceIdentity, primaryIsOriginal: Bool
    ) -> Bool {
        linkIDs.contains { linkID in
            (identities.sources(withRemoteLinkID: linkID) ?? []).contains { row in
                row.kind == source.kind && row.identifier == source.identifier
                    && Self.isOriginal(row.resource, carriedByPrimary: primaryIsOriginal)
            }
        }
    }

    /// The resources that Photos keeps unchanged through an edit: the original photo or video, a RAW alternate,
    /// and the paired video of a Live Photo.
    static func isOriginal(_ resource: UploadSourceIdentity.Resource, carriedByPrimary: Bool) -> Bool {
        if resource == .livePairedVideo { return true }
        let roles = ["alternatePhoto", "pairedVideo"] + (carriedByPrimary ? [] : ["originalPhoto", "originalVideo"])
        return roles.contains { resource.rawValue.hasPrefix("photoKit.\($0).") }
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
