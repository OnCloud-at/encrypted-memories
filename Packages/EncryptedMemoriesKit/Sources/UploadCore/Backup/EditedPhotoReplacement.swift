import Foundation
import PhotosCore

/// Remote reads and writes that replace an earlier upload with the edited photo. The backend implements it.
public protocol EditReplacementRemote: PhotoCarryOverRemote {
    /// Moves the photos that an edit replaced to the Proton trash, where the person can restore them. This is no
    /// deletion by the person.
    func trashReplaced(_ uids: [PhotoUID]) async throws
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
    public enum Outcome: Sendable, Equatable {
        case replaced(retiredAny: Bool)
        /// At least one earlier main still protects an original resource that the new compound lacks.
        case waiting
        case kept
        /// Earlier mains would wait, but the photo that replaces them left the library, for example because the
        /// person trashed it. Nothing replaces them, and the photo is not backed up.
        case replacementGone
    }

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
        !journal.entry(for: source).allSuperseded.isEmpty
    }

    /// Keeps the earlier uploads of `source`. A series keeps today's behavior until its own edit model exists.
    public func keepSuperseded(of source: UploadSourceIdentity) throws {
        let superseded = journal.entry(for: source).allSuperseded
        guard !superseded.isEmpty else { return }
        try journal.settle(Set(superseded.map(\.nodeID)), related: [], trashed: false, for: source)
    }

    /// Reports whether earlier photos left, still wait for original resources, or stay for good. Cached duplicate
    /// rows are stale after retirement. The backup calls this after each upload of a photo.
    @discardableResult
    public func replaceSuperseded(
        of source: UploadSourceIdentity,
        with primary: PhotoUID,
        edited: Bool,
        holdsOriginal: Bool,
        externalIdentifier: String? = nil,
        localEditTime: Date? = nil,
        localCreationDate: Date? = nil,
        externalIdentifierIsUnique: Bool = false,
        originalSHA1Hex: Set<String> = []
    ) async throws -> Outcome {
        let entry = journal.entry(for: source)
        var superseded = entry.allSuperseded
        // A retry can use the manifest fast path, so recheck remote-only targets here as well as during discovery.
        // Unknown index state keeps these mains and leaves locally proven targets on their existing guarded path.
        let remoteTargets = Set(entry.remoteSuperseded ?? [])
        var provenCompounds: [String: UploadRemoteCompound] = [:]
        if !remoteTargets.isEmpty { await relations.invalidateCachedRemoteState() }
        for linkID in remoteTargets.sorted() {
            do {
                guard externalIdentifierIsUnique, let identifier = externalIdentifier,
                    let creationDate = localCreationDate,
                    let target = try await relations.compound(ofMainLink: linkID),
                    target.externalIdentifier == identifier,
                    UploadRemoteReplacementSafety.isSameCaptureSecond(remote: target.captureDate, local: creationDate)
                else { continue }
                let lineage = try await relations.replacedLinkIDs(ofReplacingMain: linkID)
                let heads = try await relations.activeMainLinkIDs(forExternalIdentifier: identifier)
                let successors = try await relations.replacingMainLinkIDs(ofReplacedLink: linkID)
                let otherHeads = heads.links.union(successors.links).subtracting([primary.nodeID])
                guard lineage.complete, heads.complete, successors.complete, otherHeads == [linkID],
                    UploadRemoteReplacementSafety.isNewerVersion(
                        localDate: localEditTime, remoteDate: target.modificationDate)
                else { continue }
                provenCompounds[linkID] = target
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        let unknown = remoteTargets.subtracting(provenCompounds.keys)
        superseded.removeAll { unknown.contains($0.nodeID) }
        // Other bytes of a photo that is unedited now and was unedited before are no edit, so both photos stay.
        guard !superseded.isEmpty, edited || entry.lastUploadWasEdit else {
            try keepSuperseded(of: source)
            try recordUpload(of: source, edited: edited)
            return .kept
        }
        let volumeID = try await remote.ownPhotosVolumeID()
        func resolved(_ uid: PhotoUID) -> PhotoUID {
            uid.volumeID.isEmpty ? PhotoUID(volumeID: volumeID, nodeID: uid.nodeID) : uid
        }
        let replacement = resolved(primary)
        // The earlier photos may hold the only copy of the original. They wait for an upload that holds it.
        guard holdsOriginal else {
            return try await waitingOutcome(of: source, for: replacement, edited: edited)
        }
        // The edit was undone and the earlier photo is the current one again.
        var kept = Set(superseded.map(\.nodeID).filter { $0 == replacement.nodeID }).union(unknown)
        var waiting: Set<String> = []
        let targets = superseded.map(resolved).filter { $0.nodeID != replacement.nodeID }
        let active = try await remote.activeUIDs(among: targets)
        var trashable: [PhotoUID] = []
        var related = Set(
            targets.filter { !active.contains($0) }.flatMap { entry.retireIntent?[$0.nodeID] ?? [] })
        var intent: [String: [String]] = [:]
        for target in targets where active.contains(target) {
            try Task.checkCancellation()
            let linked: Set<String>
            if remoteTargets.contains(target.nodeID) {
                do {
                    guard let earlier = provenCompounds[target.nodeID],
                        let newer = try await relations.compound(ofMainLink: replacement.nodeID)
                    else {
                        kept.insert(target.nodeID)
                        continue
                    }
                    var originals: Set<String> = []
                    for sha1 in originalSHA1Hex {
                        originals.insert(try await relations.contentHash(forSHA1Hex: sha1))
                    }
                    guard
                        UploadRemoteReplacementSafety.preserves(
                            earlier, with: newer, originalHashes: originals, source: source, identities: identities)
                    else {
                        kept.insert(target.nodeID)
                        continue
                    }
                    linked = Set(earlier.related.map(\.linkID))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    kept.insert(target.nodeID)
                    continue
                }
            } else {
                linked = try await relations.relatedPhotoLinkIDs(ofMainLinkID: target.nodeID)
            }
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
            intent[target.nodeID] = linked.sorted()
        }
        try Task.checkCancellation()
        try journal.clearRetireIntent(Set(active.map(\.nodeID)), for: source)
        try await carryOver(from: trashable, to: replacement, ownVolumeID: volumeID)
        if !trashable.isEmpty {
            // A crash after the trash loses the server's related listing. The intent keeps those links without
            // retiring them until the main's trash is confirmed.
            try journal.prepareToRetire(intent, for: source)
            try await remote.trashReplaced(trashable)
        }
        let retired = Set(targets.map(\.nodeID)).subtracting(kept).subtracting(waiting)
        // A row that names a trashed photo no longer proves a backup. Related links from an earlier intent join
        // confirmed retired links, so a retry after a failed manifest write forgets them too.
        let trashedLinks = retired.union(related).union(journal.entry(for: source).retired)
        guard identities.forgetRemoteLinks(trashedLinks, of: source) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
        try journal.settle(retired, related: related, trashed: true, for: source)
        try journal.settle(kept, related: [], trashed: false, for: source)
        if !waiting.isEmpty { return try await waitingOutcome(of: source, for: replacement, edited: edited) }
        try recordUpload(of: source, edited: edited)
        return retired.isEmpty ? .kept : .replaced(retiredAny: true)
    }

    /// Earlier photos wait only for a photo that is in the library. When the photo that would replace them left it,
    /// for example because the person trashed it, nothing can replace them, and they stay.
    ///
    /// A waiting replacement is unsettled: the journal notes an uploaded edit, so a later undo still replaces it,
    /// but an undo that waits does not clear the note, or its own retry would keep the edit for good.
    private func waitingOutcome(
        of source: UploadSourceIdentity, for replacement: PhotoUID, edited: Bool
    ) async throws -> Outcome {
        if edited { try recordUpload(of: source, edited: true) }
        return try await remote.activeUIDs(among: [replacement]).contains(replacement) ? .waiting : .replacementGone
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

/// Conservative ordering for remote heads. Multiple heads need a later resolution flow.
enum UploadRemoteReplacementSafety {
    static func isNewerVersion(localDate: Date?, remoteDate: Date?) -> Bool {
        guard let localDate, let remoteDate else { return false }
        return localDate > remoteDate
    }

    /// The server stores the capture time in whole seconds, so a PhotoKit date matches by its second.
    static func isSameCaptureSecond(remote: Date?, local: Date) -> Bool {
        guard let remote else { return false }
        return remote.timeIntervalSince1970.rounded(.down) == local.timeIntervalSince1970.rounded(.down)
    }

    static func hasAnchor(_ compound: UploadRemoteCompound, originalHashes: Set<String>) -> Bool {
        ([compound.main] + compound.related).contains { originalHashes.contains($0.contentHash) }
    }

    static func preserves(
        _ target: UploadRemoteCompound, with replacement: UploadRemoteCompound, originalHashes: Set<String>,
        source: UploadSourceIdentity, identities: any UploadIdentityStore
    ) -> Bool {
        guard !target.tags.contains(7), hasAnchor(target, originalHashes: originalHashes) else { return false }
        let files = [replacement.main] + replacement.related
        let retainedOriginals = Set(files.map(\.contentHash)).intersection(originalHashes)
        let anchors = ([target.main] + target.related).filter { retainedOriginals.contains($0.contentHash) }
        guard !anchors.isEmpty else { return false }
        var used: Set<String> = []
        for file in target.related {
            let twins = files.filter { $0.contentHash == file.contentHash && !used.contains($0.linkID) }
            if let twin = twins.first {
                used.insert(twin.linkID)
                continue
            }
            guard !files.contains(where: { $0.contentHash == file.contentHash }) else { return false }
            let derived = replacement.related.filter { candidate in
                guard candidate.nameHash == file.nameHash, candidate.mimeType == file.mimeType,
                    let rows = identities.sources(withRemoteLinkID: candidate.linkID)
                else { return false }
                return rows.contains { row in
                    row.kind == source.kind && row.identifier == source.identifier && isEditRole(row.resource)
                }
            }
            guard derived.count == 1, let match = derived.first, !used.contains(match.linkID) else { return false }
            used.insert(match.linkID)
        }
        if files.contains(where: { $0.contentHash == target.main.contentHash && !used.contains($0.linkID) }) {
            return true
        }
        return target.related.contains { retainedOriginals.contains($0.contentHash) }
    }

    static func isEditRole(_ resource: UploadSourceIdentity.Resource) -> Bool {
        let roles = [
            "adjustmentData", "adjustmentBasePhoto", "adjustmentBaseVideo", "adjustmentBasePairedVideo",
            "fullSizePhoto", "fullSizeVideo", "fullSizePairedVideo",
        ]
        return roles.contains { resource.rawValue.hasPrefix("photoKit.\($0).") }
    }
}
