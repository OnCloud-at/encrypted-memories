import Foundation
import PhotosCore

/// Universal pre-upload pipeline: manifest-backed hashing, Proton identity, batched duplicate lookup,
/// and `UploadDuplicateDecisionPolicy`. Platform adapters supply only `UploadResourceDescriptor`s.
/// Cached identities, coalesced lookups, and bounded batches avoid duplicate work.
public actor UploadDedupePipeline: UploadIdentityResolving {
    /// Maximum number of name hashes in one duplicate request.
    public static let protonDuplicateBatchSize = 150
    private static let primeLookupConcurrency = 3

    private let store: any UploadIdentityStore
    private let hasher: any UploadHashing
    private let checker: any UploadDuplicateChecking
    private let resourceCoordinator: LibraryResourceCoordinator
    private let currentClientUID: String?
    private let batchSize: Int
    private let replacementJournal: (any EditReplacementJournaling)?
    private let now: @Sendable () -> Date

    /// Per-batch remote view from each name hash to matching remote items.
    private var duplicateCache: [String: [RemotePhotoDuplicate]] = [:]
    /// In-flight lookups, one entry per name hash, so concurrent items never double-query.
    private var inFlight: [String: Task<[String: [RemotePhotoDuplicate]], any Error>] = [:]
    /// Bumped by `invalidateCachedRemoteState` so lookups that were already in flight when the
    /// view was invalidated cannot repopulate the cache with pre-invalidation data.
    private var cacheGeneration = 0

    /// Same-run content coalescing: one claim per (key epoch | content hash) while an `.upload`
    /// decision is outstanding. Identical bytes discovered concurrently (copied folders in one
    /// scan, duplicate files in one enqueue) wait here until the first upload settles, then
    /// re-check the manifest instead of uploading the same content in parallel.
    private struct PendingUpload {
        // Different revisions of one resource may resolve concurrently. Use the same fingerprint as
        // manifest reuse so settling an older revision cannot release the newer revision's claims.
        let owner: UploadIdentityRecord
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private var pendingContentUploads: [String: PendingUpload] = [:]
    /// The server draft is keyed by the encrypted/corrected name. Different photos can legally
    /// share a camera filename, but they must not upload under that name concurrently: otherwise
    /// one live upload can look exactly like a stale same-client draft to the other.
    private var pendingNameUploads: [String: PendingUpload] = [:]

    private static func contentKey(epoch: String, contentHash: String) -> String {
        "\(epoch)|\(contentHash)"
    }

    private static func nameKey(epoch: String, nameHash: String) -> String {
        "\(epoch)|\(nameHash)"
    }

    public init(
        store: any UploadIdentityStore,
        hasher: any UploadHashing = UploadFileHasher(),
        checker: any UploadDuplicateChecking,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        currentClientUID: String? = nil,
        batchSize: Int = UploadDedupePipeline.protonDuplicateBatchSize,
        replacementJournal: (any EditReplacementJournaling)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.hasher = hasher
        self.checker = checker
        self.resourceCoordinator = resourceCoordinator
        self.currentClientUID = currentClientUID
        self.batchSize = max(1, batchSize)
        self.replacementJournal = replacementJournal
        self.now = now
    }

    // MARK: - UploadIdentityResolving

    public func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        try await checker.findRemoteAssetProofs(for: identities)
    }

    public func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        try await checker.prepareRemoteIndex(progress: progress)
    }

    public func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await checker.remoteContentIndexHealth()
    }

    public func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
        let epoch = try await checker.hashKeyEpoch()
        let cached = store.record(for: descriptor.source)
        let hmacReusable =
            cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected } ?? false
        // Burst-member rule, see `UploadDuplicateDecisionPolicy.burstMemberCandidates`: the same bytes as an active
        // photo prove nothing. Only this member's own upload, or the server's related list, proves the relation.
        let isBurstMember = descriptor.source.resource.isBurstMember
        // A secondary of an edited photo that replaces an earlier upload: its earlier copy is a related photo of
        // the replaced photo and moves to the trash with it. Only a copy under the new main photo counts.
        let requiresRelatedMatch = descriptor.requiresRelatedMatch && !isBurstMember

        // Manifest fast path: this exact resource (same name/size/mtime/key epoch) is known to be
        // on the server - uploaded by us or confirmed as an active duplicate. No hash, no query.
        if let cached, hmacReusable, !requiresRelatedMatch,
            let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
            outcome == .uploaded || (outcome == .duplicateActive && !isBurstMember),
            let remoteLink = cached.remoteLinkID,
            let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex)
        {
            let identity = UploadIdentity(
                correctedName: cached.correctedName, nameHash: cached.nameHash,
                sha1Hex: cached.sha1Hex, sha1Digest: digest, contentHash: cached.contentHash
            )
            return UploadPreflightResult(
                identity: identity, decision: .skip(.knownFromManifest, remoteLinkID: remoteLink))
        }

        // Content identity - reuse the persisted SHA-1 only while name/size/mtime are unchanged;
        // when unsure, rehash (streamed, cancellable).
        let sha1Digest: Data
        if let cached, cached.isValid(for: descriptor),
            let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex)
        {
            sha1Digest = digest
        } else if let digest = descriptor.precomputedSHA1Digest {
            guard digest.count == 20 else {
                throw UploadError.backend("Invalid precomputed SHA-1 digest")
            }
            sha1Digest = digest
        } else {
            let hasher = self.hasher
            sha1Digest = try await resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .backupHashing,
                    intent: descriptor.workIntent,
                    memoryClass: .medium
                )
            ) { _ in
                try await hasher.sha1(of: descriptor)  // streamed and cancellable
            }
        }
        let sha1Hex = UploadContentSHA1.hexString(digest: sha1Digest)

        // Proton-keyed hashes - reused only when the key epoch also matches.
        let nameHash: String
        let contentHash: String
        if let cached, hmacReusable, cached.sha1Hex == sha1Hex {
            nameHash = cached.nameHash
            contentHash = cached.contentHash
        } else {
            nameHash = try await checker.nameHash(forCorrectedName: corrected)  // local HMAC
            contentHash = try await checker.contentHash(forSHA1Hex: sha1Hex)  // local HMAC
        }
        let identity = UploadIdentity(
            correctedName: corrected, nameHash: nameHash,
            sha1Hex: sha1Hex, sha1Digest: sha1Digest, contentHash: contentHash
        )
        let replacement = try await replacementScope(
            for: descriptor, cached: cached, sha1Hex: sha1Hex, nameHash: nameHash, contentHash: contentHash)
        func result(_ decision: UploadDuplicateDecision) -> UploadPreflightResult {
            UploadPreflightResult(identity: identity, decision: decision)
        }

        // Persist the identity before the remote check so a crash never re-pays the hashing.
        // An outcome from a still-valid prior row survives; anything stale is dropped.
        var record = UploadIdentityRecord(
            source: descriptor.source,
            filename: descriptor.filename,
            correctedName: corrected,
            fileSize: descriptor.fileSize,
            modificationDate: descriptor.modificationDate,
            sha1Hex: sha1Hex,
            nameHash: nameHash,
            contentHash: contentHash,
            hashKeyEpoch: epoch,
            remoteVolumeID: hmacReusable ? cached?.remoteVolumeID : nil,
            remoteLinkID: hmacReusable ? cached?.remoteLinkID : nil,
            outcome: hmacReusable ? cached?.outcome : nil,
            updatedAt: now()
        )
        try persistRecord(record)

        // Account-wide content dedupe + same-run coalescing. Loop invariant on exit: either we
        // returned a known-content skip, or we hold the pending-upload claim for this content.
        let contentKey = Self.contentKey(epoch: epoch, contentHash: contentHash)
        while true {
            // Bytes already proven on the server under ANY source path/filename (copied folder,
            // renamed file): adopt that remote link for this source - no remote query, no upload.
            if !isBurstMember, !requiresRelatedMatch,
                let known = store.trustedRecord(contentHash: contentHash, hashKeyEpoch: epoch),
                known.sha1Hex == sha1Hex,
                let knownLink = known.remoteLinkID,
                replacement.isEmpty || known.source == descriptor.source
            {
                record.remoteVolumeID = known.remoteVolumeID
                record.remoteLinkID = knownLink
                record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
                record.updatedAt = now()
                try persistRecord(record)
                return result(.skip(.knownFromManifest, remoteLinkID: knownLink))
            }
            guard pendingContentUploads[contentKey] != nil else {
                // Claim the content before the remote check - identical items resolving
                // concurrently must serialize here, not race to independent `.upload` decisions.
                pendingContentUploads[contentKey] = PendingUpload(owner: record, waiters: [])
                break
            }
            // Identical bytes are uploading right now - wait until that attempt settles
            // (recordUploaded or uploadDidFail), then re-check the manifest.
            await withCheckedContinuation { continuation in
                if pendingContentUploads[contentKey] != nil {
                    pendingContentUploads[contentKey]!.waiters.append(continuation)
                } else {
                    continuation.resume()  // claim vanished in the same turn - just re-loop
                }
            }
            try Task.checkCancellation()
        }

        // Filename reuse is valid (for example after resetting an iPhone), but Proton drafts are
        // name-scoped. Serialize same-name uploads only for the lifetime of the actual attempt so
        // an own draft observed below cannot belong to another live upload in this process.
        let nameKey = Self.nameKey(epoch: epoch, nameHash: nameHash)
        do {
            try await acquirePendingNameClaim(nameKey, owner: record)
        } catch {
            releasePendingContentClaim(contentKey, owner: descriptor)
            throw error
        }

        let remoteItems: [RemotePhotoDuplicate]
        do {
            remoteItems = try await duplicates(forNameHash: nameHash)
            try Task.checkCancellation()
        } catch {
            let detailedLookupError = error
            // The detailed endpoint is normally faster because `prime` batches large libraries.
            // The SDK gives us a safe exact fallback: a positive result proves the bytes are
            // already active; an empty/failed result cannot authorize an upload, so fail closed
            // with the original detailed-lookup error.
            let exactMatches =
                isBurstMember || requiresRelatedMatch || !replacement.isEmpty
                ? []
                : await checker.findExactActiveDuplicates(
                    correctedName: corrected,
                    sha1Digest: sha1Digest
                )
            if let exact = exactMatches.first {
                let decision = UploadDuplicateDecision.skip(.activeDuplicate, remoteLinkID: exact.nodeID)
                do {
                    try persist(decision, in: &record)
                } catch {
                    releasePendingUploadClaims(ownedBy: descriptor)
                    throw error
                }
                releasePendingUploadClaims(ownedBy: descriptor)
                return result(decision)
            }
            releasePendingUploadClaims(ownedBy: descriptor)
            throw detailedLookupError
        }

        let nameCandidates: (items: [RemotePhotoDuplicate], provesLive: Bool)
        do {
            nameCandidates = try await candidates(
                remoteItems, contentHash: contentHash, descriptor: descriptor, replacement: replacement)
        } catch {
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        let nameDecision = UploadDuplicateDecisionPolicy.decide(
            primary: .init(source: descriptor.source, nameHash: nameHash, contentHash: contentHash),
            remoteItems: nameCandidates.items,
            currentClientUID: currentClientUID
        )

        // Finish both passes before asking about deletion: same bytes outside the scope can prove a deletion,
        // and an active copy under another name can prove the photo live.
        var decision = nameDecision
        var provesLive = nameCandidates.provesLive
        do {
            if nameDecision.uploadsBytes {
                if let found = try await checker.findDuplicate(contentHash: contentHash) {
                    let contentCandidates = try await candidates(
                        [found], contentHash: contentHash, descriptor: descriptor, replacement: replacement)
                    provesLive = provesLive || contentCandidates.provesLive
                    if let remoteContent = contentCandidates.items.first {
                        decision = decisionForRemoteContent(
                            remoteContent,
                            replacingNameHash: nameDecision == .uploadReplacingDraft ? nameHash : nil)
                    }
                }
                try Task.checkCancellation()
            }
            if decision.uploadsBytes, !replacement.isEmpty, !provesLive,
                descriptor.source.kind == .photoLibraryAsset, descriptor.source.resource == .primary,
                descriptor.mainRemoteLinkID == nil, let replacementJournal
            {
                let entry = replacementJournal.entry(for: descriptor.source)
                if entry.keptDeleted == true {
                    decision = .skip(.deletedRemotely, remoteLinkID: replacement.current)
                } else if entry.backUpAgainRevision
                    != (descriptor.backupRevision ?? UploadBackupRevision(date: descriptor.modificationDate))
                {
                    // The person's consent covers exactly the version they saw; a later edit of a deleted photo
                    // asks again, so a consent that outlived its backup can never upload a later deletion.
                    decision = .awaitDeletionCheck
                }
            }
            try noteRestored(decision, in: replacement, of: descriptor.source)
            if decision != .awaitDeletionCheck {
                try replacementJournal?.clearDeletionCheck(for: descriptor.source)
            }
            try persist(decision, in: &record)
        } catch {
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        if !decision.uploadsBytes { releasePendingUploadClaims(ownedBy: descriptor) }
        return result(decision)
    }

    /// Complete lineage reads can discover a live main without a local manifest. Failed or incomplete reads leave
    /// the existing replacement behavior unchanged. Unedited assets and assets without an iCloud ID use no new read.
    private func replacementScope(
        for descriptor: UploadResourceDescriptor,
        cached: UploadIdentityRecord?,
        sha1Hex: String, nameHash: String, contentHash: String
    ) async throws -> UploadReplacementScope {
        var scope = try localReplacementScope(for: descriptor, cached: cached, sha1Hex: sha1Hex)
        guard let replacementJournal, descriptor.source.kind == .photoLibraryAsset,
            descriptor.source.resource == .primary, descriptor.mainRemoteLinkID == nil,
            let identifier = descriptor.externalIdentifier, !identifier.isEmpty
        else { return scope }
        // Runs on every pass, also on a retry whose remote target the journal already holds.
        scope = try await excludingForeignTargets(
            from: scope, identifier: identifier, source: descriptor.source, journal: replacementJournal)
        guard descriptor.isEditedPhoto, descriptor.externalIdentifierIsUnique,
            let creationDate = descriptor.photoLibraryCreationDate
        else { return scope }

        // Build every optional fact before changing the local scope or journal.
        let head: String
        let ancestors: Set<String>
        let foreign: Set<String>
        let candidateVisibility: [String: RemoteLinkVisibility]
        do {
            let identity = try await checker.activeMainLinkIDs(forExternalIdentifier: identifier)
            guard identity.complete, identity.links.count == 1, let target = identity.links.first,
                !scope.superseded.contains(target), target != scope.current
            else { return scope }
            let successors = try await checker.replacingMainLinkIDs(ofReplacedLink: scope.current ?? target)
            guard successors.complete, successors.links.subtracting([target]).isEmpty,
                let compound = try await checker.compound(ofMainLink: target),
                compound.externalIdentifier == identifier, !compound.tags.contains(PhotoTag.bursts.rawValue),
                UploadRemoteReplacementSafety.isSameCaptureSecond(remote: compound.captureDate, local: creationDate),
                UploadRemoteReplacementSafety.isNewerVersion(
                    localDate: descriptor.photoLibraryEditTime, remoteDate: compound.modificationDate)
            else { return scope }
            var originals: Set<String> = []
            for sha1 in descriptor.originalSHA1Hex {
                originals.insert(try await checker.contentHash(forSHA1Hex: sha1))
            }
            guard UploadRemoteReplacementSafety.hasAnchor(compound, originalHashes: originals) else { return scope }
            let ancestry = try await checker.replacedLinkIDs(ofReplacingMain: target)
            guard ancestry.complete else { return scope }
            var candidates = try await duplicates(forNameHash: nameHash)
            if let content = try await checker.findDuplicate(contentHash: contentHash) { candidates.append(content) }
            let matches = Set(
                candidates.filter { $0.linkState == .active && $0.contentHash == contentHash }
                    .compactMap(\.linkID))
            let asked = scope.retired.union(scope.superseded).union(ancestry.links).union(matches).union([target])
            var knownForeign: Set<String> = []
            for linkID in asked.sorted() {
                let external = try await checker.externalIdentifier(ofMainLink: linkID)
                guard external.complete else { return scope }
                if let remoteIdentifier = external.identifier, remoteIdentifier != identifier {
                    knownForeign.insert(linkID)
                }
            }
            guard !knownForeign.contains(target) else { return scope }
            candidateVisibility = try await checker.linkVisibility(of: asked.sorted())
            try Task.checkCancellation()
            head = target
            ancestors = ancestry.links.subtracting(knownForeign)
            foreign = knownForeign
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return scope
        }
        scope.retired.subtract(foreign)
        if let current = scope.current, foreign.contains(current) { scope.current = nil }
        try replacementJournal.addRemoteSuperseded(PhotoUID(volumeID: "", nodeID: head), for: descriptor.source)
        let remoteAncestors = ancestors.subtracting(scope.retired).subtracting(scope.superseded)
        scope.superseded.insert(head)
        scope.retired.formUnion(ancestors.subtracting(scope.superseded))
        scope.knownForeignLinks.formUnion(foreign)
        scope.liveHeads = [head]
        scope.candidateVisibility = candidateVisibility
        scope.remoteAncestors = remoteAncestors
        return scope
    }

    /// A locally adopted duplicate can belong to another asset: a known different iCloud identifier proves that, so
    /// such a photo never becomes a replacement target. Failed or incomplete reads keep the scope unchanged.
    private func excludingForeignTargets(
        from scope: UploadReplacementScope, identifier: String, source: UploadSourceIdentity,
        journal: any EditReplacementJournaling
    ) async throws -> UploadReplacementScope {
        guard !scope.superseded.isEmpty else { return scope }
        var foreign: Set<String> = []
        do {
            for linkID in scope.superseded.sorted() {
                let external = try await checker.externalIdentifier(ofMainLink: linkID)
                guard external.complete else { return scope }
                if let remote = external.identifier, remote != identifier { foreign.insert(linkID) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return scope
        }
        guard !foreign.isEmpty else { return scope }
        try journal.settle(foreign, related: [], trashed: false, for: source)
        var scope = scope
        scope.superseded.subtract(foreign)
        scope.retired.subtract(foreign)
        if let current = scope.current, foreign.contains(current) { scope.current = nil }
        scope.knownForeignLinks.formUnion(foreign)
        return scope
    }

    /// A photo-library primary with other bytes than its proven earlier upload was edited. The journal keeps the
    /// earlier photo before the record below forgets it, so the backup can replace it after the upload.
    private func localReplacementScope(
        for descriptor: UploadResourceDescriptor,
        cached: UploadIdentityRecord?,
        sha1Hex: String
    ) throws -> UploadReplacementScope {
        guard let replacementJournal, descriptor.source.kind == .photoLibraryAsset,
            descriptor.source.resource == .primary, descriptor.mainRemoteLinkID == nil
        else {
            return UploadReplacementScope(superseded: [], retired: [], current: nil)
        }
        var entry = replacementJournal.entry(for: descriptor.source)
        // An earlier upload of another client counts as well: the duplicate check proved it was this photo.
        let provenOutcomes = [UploadIdentityManifestStore.Outcome.uploaded, .duplicateActive].map(\.rawValue)
        // The manifest names the last upload of this photo, also when its bytes did not change.
        var lastUpload: String?
        if let cached, cached.outcome.map(provenOutcomes.contains) == true,
            let link = cached.remoteLinkID, !link.isEmpty
        {
            lastUpload = link
            if cached.sha1Hex != sha1Hex, !entry.superseded.contains(where: { $0.nodeID == link }) {
                let uid = PhotoUID(volumeID: cached.remoteVolumeID ?? "", nodeID: link)
                try replacementJournal.addSuperseded(uid, for: descriptor.source)
                entry.superseded.append(uid)
            }
        }
        return UploadReplacementScope(
            superseded: Set(entry.superseded.map(\.nodeID)), retired: Set(entry.retired),
            current: lastUpload ?? entry.superseded.last?.nodeID)
    }

    /// The remote rows that can prove this resource. A burst member and a secondary of a replacing edit count
    /// only a copy under their main photo. A primary ignores the photos that an edit replaces or replaced and
    /// their related photos: the backup moves those to the trash itself, so they are neither this photo nor a
    /// deletion by the person.
    private func candidates(
        _ remoteItems: [RemotePhotoDuplicate],
        contentHash: String,
        descriptor: UploadResourceDescriptor,
        replacement: UploadReplacementScope
    ) async throws -> (items: [RemotePhotoDuplicate], provesLive: Bool) {
        if descriptor.source.resource.isBurstMember {
            return (
                try await burstMemberCandidates(remoteItems, contentHash: contentHash, descriptor: descriptor), false
            )
        }
        if descriptor.requiresRelatedMatch {
            var relatedLinkIDs: Set<String> = []
            if remoteItems.contains(where: { $0.linkState != .draft }), let mainLinkID = descriptor.mainRemoteLinkID {
                relatedLinkIDs = try await checker.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
            }
            return (
                remoteItems.filter { item in
                    item.linkState == .draft || (item.linkID.map(relatedLinkIDs.contains) ?? false)
                }, false
            )
        }
        guard !replacement.isEmpty else { return (remoteItems, false) }
        // Only the state of a photo shows that it is still in the library: its current upload is active, the
        // person restored an earlier version, or an active main photo holds these bytes.
        let matches = remoteItems.filter { $0.linkState == .active && $0.contentHash == contentHash }
            .compactMap(\.linkID)
        var asked = replacement.retired.union(matches)
        if let current = replacement.current { asked.insert(current) }
        let visibility: [String: RemoteLinkVisibility]
        if let optional = replacement.candidateVisibility {
            visibility = optional
        } else {
            visibility = try await checker.linkVisibility(of: asked.sorted())
        }
        func isLiveMain(_ linkID: String) -> Bool {
            visibility[linkID].map { $0.isActive && $0.mainPhotoLinkID == nil } ?? false
        }
        let ownMatches = Set(matches.filter(isLiveMain)).filter {
            !replacement.knownForeignLinks.contains($0)
        }
        let adoptable = ownMatches.subtracting(replacement.superseded.subtracting(replacement.liveHeads))
        let liveRetired = replacement.retired.filter(isLiveMain)
        let restored = liveRetired.subtracting(adoptable).subtracting(replacement.remoteAncestors)

        guard
            replacement.current.map(isLiveMain) == true || !replacement.liveHeads.isEmpty
                || !restored.isEmpty || !adoptable.isEmpty
        else {
            // Nothing proves the photo live. Who removed it stays unknown, so the earlier rule applies: the
            // photos of the replacement do not count, and a trashed copy outside them is a deletion by the person.
            // An active copy under a main photo is a related file, such as the hidden original under a replaced
            // photo. It is no backup. The states above name those copies without a lookup of the related photos
            // of a main photo that may be in the trash or gone. A copy that left the library after the listing
            // named it active was a main photo, so it counts as a deletion by the person.
            let related = Set(
                matches.filter { visibility[$0].map { $0.isActive && $0.mainPhotoLinkID != nil } ?? false })
            let removed = Set(matches.filter { visibility[$0]?.isActive != true })
            let excluded = replacement.superseded.union(replacement.retired).union(related)
            return (
                remoteItems.compactMap { item in
                    guard let linkID = item.linkID else { return item }
                    guard !excluded.contains(linkID) else { return nil }
                    guard removed.contains(linkID) else { return item }
                    return RemotePhotoDuplicate(
                        nameHash: item.nameHash, contentHash: item.contentHash, linkState: .trashed, linkID: linkID,
                        clientUID: item.clientUID)
                }, false
            )
        }
        if replacement.current.map(isLiveMain) == true || !liveRetired.isEmpty {
            try replacementJournal?.clearDeletionChoice(for: descriptor.source)
        }
        // A restored earlier version with other bytes is an earlier photo again, so this upload replaces it.
        if !restored.isEmpty {
            try replacementJournal?.unretire(restored, for: descriptor.source)
            for linkID in restored.sorted() {
                let uid = PhotoUID(volumeID: "", nodeID: linkID)
                try replacementJournal?.addSuperseded(uid, for: descriptor.source)
            }
        }
        // The photo is in the library, so a trashed or deleted copy of these bytes is an earlier version that the
        // backup replaced, not a deletion by the person. An active copy counts only as a main photo: the hidden
        // original under the photo that this upload replaces, or a related file of a trashed photo, is no backup.
        let scope = replacement.superseded.union(replacement.retired)
        return (
            remoteItems.filter { item in
                guard item.linkState != .draft else { return true }
                guard item.linkState == .active, let linkID = item.linkID else { return false }
                return item.contentHash == contentHash ? adoptable.contains(linkID) : !scope.contains(linkID)
            }, true
        )
    }

    /// An earlier version that the person restored is the photo again: it leaves the retired list.
    private func noteRestored(
        _ decision: UploadDuplicateDecision, in replacement: UploadReplacementScope, of source: UploadSourceIdentity
    ) throws {
        guard case .skip(.activeDuplicate, let linkID?) = decision, replacement.retired.contains(linkID) else {
            return
        }
        try replacementJournal?.unretire([linkID], for: source)
    }

    /// Applies the burst-member rule. The server names the related photos of the member's main photo only when
    /// an active row with the member's content exists, so a new series costs no extra request.
    private func burstMemberCandidates(
        _ remoteItems: [RemotePhotoDuplicate],
        contentHash: String,
        descriptor: UploadResourceDescriptor
    ) async throws -> [RemotePhotoDuplicate] {
        let hasActiveContentMatch = remoteItems.contains { $0.linkState == .active && $0.contentHash == contentHash }
        var relatedLinkIDs: Set<String> = []
        if hasActiveContentMatch, let mainLinkID = descriptor.mainRemoteLinkID {
            relatedLinkIDs = try await checker.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
        }
        return UploadDuplicateDecisionPolicy.burstMemberCandidates(
            remoteItems, contentHash: contentHash, relatedLinkIDs: relatedLinkIDs)
    }

    /// Validates a manifest-proven remote resource against current server state. Unlike `resolve`,
    /// a remote miss is interpreted as a respected deletion because the manifest already proves
    /// that these exact bytes were uploaded/confirmed before. Callers use this only to disambiguate
    /// a secondary-resource draft; it can never authorize another upload.
    public func revalidateKnownRemote(
        _ descriptor: UploadResourceDescriptor
    ) async throws -> UploadDuplicateDecision? {
        let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
        let epoch = try await checker.hashKeyEpoch()
        guard let cached = store.record(for: descriptor.source),
            cached.isValid(for: descriptor, hashKeyEpoch: epoch),
            cached.correctedName == corrected,
            let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
            outcome == .uploaded || outcome == .duplicateActive,
            let knownLinkID = cached.remoteLinkID
        else {
            return nil
        }

        // This path exists specifically because a cached manifest answer is no longer sufficient.
        // Bypass both pipeline and backend caches so a recent trash/delete event is observable.
        invalidateNameCache()
        await checker.invalidateCachedRemoteState()

        // Revalidation is intentionally one asset at a time, so the SDK exact lookup handles the
        // common still-active case without adding round trips to batched initial scans.
        if let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex) {
            let exactMatches = await checker.findExactActiveDuplicates(
                correctedName: corrected,
                sha1Digest: digest
            )
            if let active = exactMatches.first {
                return .skip(.activeDuplicate, remoteLinkID: active.nodeID)
            }
        }

        // An SDK miss does not say whether the known item was trashed or deleted. Preserve the
        // detailed Photos response and content index for that distinction.
        let remoteItems = try await checker.findDuplicates(nameHashes: [cached.nameHash])
        let nameDecision = UploadDuplicateDecisionPolicy.decide(
            primary: .init(
                source: descriptor.source,
                nameHash: cached.nameHash,
                contentHash: cached.contentHash
            ),
            remoteItems: remoteItems,
            // Revalidation may only prove that a previously-known primary was deleted. It must
            // never authorize replacement of a draft from this read-only path.
            currentClientUID: nil
        )
        guard nameDecision.uploadsBytes else { return nameDecision }

        if let remoteContent = try await checker.findDuplicate(contentHash: cached.contentHash) {
            return decisionForRemoteContent(remoteContent, replacingNameHash: nil)
        }
        return .skip(.deletedRemotely, remoteLinkID: knownLinkID)
    }

    /// Persists only outcomes that remain useful across runs. Active duplicates are trusted by the
    /// manifest fast path. Trashed rows are diagnostic only and are rechecked because users can
    /// restore or permanently delete them. Draft/deleted states stay transient.
    private func persist(_ decision: UploadDuplicateDecision, in record: inout UploadIdentityRecord) throws {
        switch decision {
        case .skip(.activeDuplicate, let remoteLinkID):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
            record.remoteLinkID = remoteLinkID
            record.updatedAt = now()
            try persistRecord(record)
        case .skip(.trashedDuplicate, _):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
            record.updatedAt = now()
            try persistRecord(record)
        case .upload, .uploadReplacingDraft, .awaitDeletionCheck, .uploadMissingSecondaries, .skip:
            break
        }
    }

    private func persistRecord(_ record: UploadIdentityRecord) throws {
        guard store.upsert(record) else {
            throw UploadError.backend("Upload identity manifest could not be updated")
        }
    }

    private func decisionForRemoteContent(
        _ remote: RemotePhotoDuplicate,
        replacingNameHash: String?
    ) -> UploadDuplicateDecision {
        switch remote.linkState {
        case .draft:
            if let currentClientUID,
                remote.clientUID == currentClientUID,
                remote.nameHash == replacingNameHash
            {
                return .uploadReplacingDraft
            }
            return .skip(.draftExists, remoteLinkID: remote.linkID)
        case .trashed:
            return .skip(.trashedDuplicate, remoteLinkID: remote.linkID)
        case nil:
            return .skip(.deletedRemotely, remoteLinkID: remote.linkID)
        case .active:
            guard let linkID = remote.linkID, !linkID.isEmpty else {
                return .skip(.inconsistentRemoteState, remoteLinkID: nil)
            }
            return .skip(.activeDuplicate, remoteLinkID: linkID)
        }
    }

    /// Releases the same-content claim (if `owner` still holds it) and wakes every waiter so it
    /// re-checks the manifest / re-resolves against fresh state.
    private func releasePendingContentClaim(_ key: String, owner: UploadResourceDescriptor) {
        guard let pending = pendingContentUploads[key], pending.owner.isValid(for: owner) else { return }
        pendingContentUploads[key] = nil
        for waiter in pending.waiters { waiter.resume() }
    }

    private func acquirePendingNameClaim(
        _ key: String,
        owner: UploadIdentityRecord
    ) async throws {
        while true {
            guard pendingNameUploads[key] != nil else {
                pendingNameUploads[key] = PendingUpload(owner: owner, waiters: [])
                return
            }
            await withCheckedContinuation { continuation in
                if pendingNameUploads[key] != nil {
                    pendingNameUploads[key]!.waiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Drops the cached remote view (and detaches in-flight lookups) so the next `resolve`
    /// re-queries the server. Called after failed/cancelled upload attempts and before
    /// draft-blocked re-checks - the moments where the server may know more than the cache.
    public func invalidateCachedRemoteState() async {
        invalidateNameCache()
        await checker.invalidateCachedRemoteState()
    }

    private func invalidateNameCache() {
        cacheGeneration += 1
        duplicateCache.removeAll()
        // Don't cancel running lookups (their callers still get server truth as of their start),
        // but stop new callers from joining them and stop their results from repopulating the
        // invalidated cache (guarded by `cacheGeneration` in `lookup`).
        inFlight.removeAll()
    }

    /// Batch-prefetch for a fresh enqueue: computes name hashes (no content hashing) and queries
    /// the duplicates endpoint in Proton-sized chunks, so per-item `resolve` calls become cache
    /// hits. Clears only the short-lived name view. The backend's expensive account-wide content
    /// index has its own freshness window and must not be rebuilt every lookahead batch.
    public func prime(_ descriptors: [UploadResourceDescriptor]) async {
        invalidateNameCache()
        guard let epoch = try? await checker.hashKeyEpoch() else { return }

        var pending: [String] = []
        var pendingSet: Set<String> = []
        var correctedNamesToHash: [String] = []
        var correctedNamesToHashSet: Set<String> = []

        func appendPendingHash(_ hash: String) {
            if duplicateCache[hash] == nil, inFlight[hash] == nil, pendingSet.insert(hash).inserted {
                pending.append(hash)
            }
        }

        for descriptor in descriptors {
            let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
            let cached = store.record(for: descriptor.source)
            let hmacReusable =
                cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected }
                ?? false

            let nameHash: String
            if let cached, hmacReusable {
                // Fast-path rows won't query at resolve time either - skip them here too.
                if let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
                    outcome == .uploaded || outcome == .duplicateActive, cached.remoteLinkID != nil
                {
                    continue
                }
                nameHash = cached.nameHash
            } else {
                if correctedNamesToHashSet.insert(corrected).inserted {
                    correctedNamesToHash.append(corrected)
                }
                continue
            }
            appendPendingHash(nameHash)
        }

        if !correctedNamesToHash.isEmpty,
            let hashes = try? await checker.nameHashes(forCorrectedNames: correctedNamesToHash),
            hashes.count == correctedNamesToHash.count
        {
            for hash in hashes {
                appendPendingHash(hash)
            }
        }

        let chunks = stride(from: 0, to: pending.count, by: batchSize).map { start in
            Array(pending[start..<min(start + batchSize, pending.count)])
        }
        await withTaskGroup(of: Int.self) { group in
            var nextChunk = 0

            func submitNext() {
                guard nextChunk < chunks.count else { return }
                let index = nextChunk
                nextChunk += 1
                group.addTask { [self] in
                    _ = try? await lookup(batch: chunks[index])
                    return index
                }
            }

            for _ in 0..<min(Self.primeLookupConcurrency, chunks.count) {
                submitNext()
            }
            while await group.next() != nil {
                submitNext()
            }
        }
    }

    public func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        do {
            let epoch = try await checker.hashKeyEpoch()
            try persistRecord(
                UploadIdentityRecord(
                    source: descriptor.source,
                    filename: descriptor.filename,
                    correctedName: identity.correctedName,
                    fileSize: descriptor.fileSize,
                    modificationDate: descriptor.modificationDate,
                    sha1Hex: identity.sha1Hex,
                    nameHash: identity.nameHash,
                    contentHash: identity.contentHash,
                    hashKeyEpoch: epoch,
                    remoteVolumeID: remoteVolumeID,
                    remoteLinkID: remoteLinkID,
                    outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue,
                    updatedAt: now()
                ))
        } catch {
            await invalidateCachedRemoteState()
            releasePendingUploadClaims(ownedBy: descriptor)
            throw error
        }
        await checker.recordUploaded(contentHash: identity.contentHash, remoteLinkID: remoteLinkID)
        // The server now has this name and content active. A cached "free" view for this name hash
        // must not survive the upload it predates.
        duplicateCache[identity.nameHash, default: []].append(
            RemotePhotoDuplicate(
                nameHash: identity.nameHash,
                contentHash: identity.contentHash,
                linkState: .active,
                linkID: remoteLinkID
            ))
        // Settle the same-content claim after the manifest row exists, so released waiters find
        // it. Owner-scoped scan (not key computation) so a failed epoch fetch can never leak the
        // claim and hang waiters.
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    /// Reports that an upload attempt for a `.upload` decision ended without success (error,
    /// cancel, or stop). Drops the cached remote view (the server may have committed the attempt
    /// even though the call failed) and releases the same-content claim so identical waiting
    /// items re-resolve against fresh state.
    public func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    public func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor)
    }

    private func releasePendingUploadClaims(ownedBy owner: UploadResourceDescriptor) {
        for (key, pending) in pendingContentUploads where pending.owner.isValid(for: owner) {
            pendingContentUploads[key] = nil
            for waiter in pending.waiters { waiter.resume() }
        }
        for (key, pending) in pendingNameUploads where pending.owner.isValid(for: owner) {
            pendingNameUploads[key] = nil
            for waiter in pending.waiters { waiter.resume() }
        }
    }

    // MARK: - Duplicate lookup (cached / coalesced / batched)

    private func duplicates(forNameHash nameHash: String) async throws -> [RemotePhotoDuplicate] {
        if let hit = duplicateCache[nameHash] { return hit }
        if let running = inFlight[nameHash] {
            return try await running.value[nameHash] ?? []
        }
        return try await lookup(batch: [nameHash])[nameHash] ?? []
    }

    private func lookup(batch nameHashes: [String]) async throws -> [String: [RemotePhotoDuplicate]] {
        let checker = self.checker
        let generation = cacheGeneration
        let task = Task { () -> [String: [RemotePhotoDuplicate]] in
            let items = try await checker.findDuplicates(nameHashes: nameHashes)  // step 5: the one network call
            // Every requested hash gets an entry - [] distinguishes "server says free" from
            // "never asked" in the cache.
            var grouped = Dictionary(uniqueKeysWithValues: nameHashes.map { ($0, [RemotePhotoDuplicate]()) })
            for item in items { grouped[item.nameHash, default: []].append(item) }
            return grouped
        }
        for hash in nameHashes { inFlight[hash] = task }
        defer {
            for hash in nameHashes where inFlight[hash] == task { inFlight[hash] = nil }
        }
        let grouped = try await task.value
        // A view invalidated while this lookup ran must stay invalidated - the result predates it.
        if generation == cacheGeneration {
            for (hash, items) in grouped { duplicateCache[hash] = items }
        }
        return grouped
    }
}

/// The earlier uploads of one primary that an edit replaces (`superseded`) or already replaced (`retired`).
private struct UploadReplacementScope {
    var superseded: Set<String>
    var retired: Set<String>
    /// The photo that showed before this upload: the last upload that the manifest names, else the newest
    /// superseded photo of the journal.
    var current: String?
    var knownForeignLinks: Set<String> = []
    var liveHeads: Set<String> = []
    var remoteAncestors: Set<String> = []
    var candidateVisibility: [String: RemoteLinkVisibility]?

    var isEmpty: Bool { superseded.isEmpty && retired.isEmpty }
}
