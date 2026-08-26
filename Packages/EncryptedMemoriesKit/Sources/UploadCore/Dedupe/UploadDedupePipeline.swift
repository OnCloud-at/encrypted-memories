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
    private struct PendingContentUpload {
        var owner: UploadSourceIdentity
        var waiters: [CheckedContinuation<Void, Never>]
    }

    /// The server draft is keyed by the encrypted/corrected name. Different photos can legally
    /// share a camera filename, but they must not upload under that name concurrently: otherwise
    /// one live upload can look exactly like a stale same-client draft to the other.
    private struct PendingNameUpload {
        var owner: UploadSourceIdentity
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private var pendingContentUploads: [String: PendingContentUpload] = [:]
    private var pendingNameUploads: [String: PendingNameUpload] = [:]

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
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.hasher = hasher
        self.checker = checker
        self.resourceCoordinator = resourceCoordinator
        self.currentClientUID = currentClientUID
        self.batchSize = max(1, batchSize)
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

        // Manifest fast path: this exact resource (same name/size/mtime/key epoch) is known to be
        // on the server - uploaded by us or confirmed as an active duplicate. No hash, no query.
        if let cached, hmacReusable,
            let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
            outcome == .uploaded || outcome == .duplicateActive,
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
            if let known = store.trustedRecord(contentHash: contentHash, hashKeyEpoch: epoch),
                known.sha1Hex == sha1Hex,
                let knownLink = known.remoteLinkID
            {
                record.remoteVolumeID = known.remoteVolumeID
                record.remoteLinkID = knownLink
                record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
                record.updatedAt = now()
                try persistRecord(record)
                return UploadPreflightResult(
                    identity: identity, decision: .skip(.knownFromManifest, remoteLinkID: knownLink))
            }
            guard pendingContentUploads[contentKey] != nil else {
                // Claim the content before the remote check - identical items resolving
                // concurrently must serialize here, not race to independent `.upload` decisions.
                pendingContentUploads[contentKey] = PendingContentUpload(owner: descriptor.source, waiters: [])
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
            try await acquirePendingNameClaim(nameKey, owner: descriptor.source)
        } catch {
            releasePendingContentClaim(contentKey, owner: descriptor.source)
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
            let exactMatches = await checker.findExactActiveDuplicates(
                correctedName: corrected,
                sha1Digest: sha1Digest
            )
            if let exact = exactMatches.first {
                let decision = UploadDuplicateDecision.skip(.activeDuplicate, remoteLinkID: exact.nodeID)
                do {
                    try persist(decision, in: &record)
                } catch {
                    releasePendingUploadClaims(ownedBy: descriptor.source)
                    throw error
                }
                releasePendingUploadClaims(ownedBy: descriptor.source)
                return UploadPreflightResult(identity: identity, decision: decision)
            }
            releasePendingUploadClaims(ownedBy: descriptor.source)
            throw detailedLookupError
        }

        let nameDecision = UploadDuplicateDecisionPolicy.decide(
            primary: .init(source: descriptor.source, nameHash: nameHash, contentHash: contentHash),
            remoteItems: remoteItems,
            currentClientUID: currentClientUID
        )

        // The batched name endpoint is both the Proton-native path and the cheap path. Any skip it
        // proves is already conservative, so return immediately. Only a would-upload item needs the
        // expensive account-wide content fallback for renamed/copied originals.
        if nameDecision.uploadsBytes {
            do {
                if let remoteContent = try await checker.findDuplicate(contentHash: contentHash) {
                    let contentDecision = decisionForRemoteContent(
                        remoteContent,
                        replacingNameHash: nameDecision == .uploadReplacingDraft ? nameHash : nil
                    )
                    try persist(contentDecision, in: &record)
                    if !contentDecision.uploadsBytes {
                        releasePendingUploadClaims(ownedBy: descriptor.source)
                    }
                    return UploadPreflightResult(identity: identity, decision: contentDecision)
                }
                try Task.checkCancellation()
            } catch {
                releasePendingUploadClaims(ownedBy: descriptor.source)
                throw error
            }
        } else {
            do {
                try persist(nameDecision, in: &record)
            } catch {
                releasePendingUploadClaims(ownedBy: descriptor.source)
                throw error
            }
            releasePendingUploadClaims(ownedBy: descriptor.source)
            return UploadPreflightResult(identity: identity, decision: nameDecision)
        }

        // Both claims stay held: the caller now owns this content/name upload and must settle it via
        // `recordUploaded` (success) or `uploadDidFail` (anything else).
        return UploadPreflightResult(identity: identity, decision: nameDecision)
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
        default:
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
    private func releasePendingContentClaim(_ key: String, owner: UploadSourceIdentity) {
        guard let pending = pendingContentUploads[key], pending.owner == owner else { return }
        pendingContentUploads[key] = nil
        for waiter in pending.waiters { waiter.resume() }
    }

    private func acquirePendingNameClaim(
        _ key: String,
        owner: UploadSourceIdentity
    ) async throws {
        while true {
            guard pendingNameUploads[key] != nil else {
                pendingNameUploads[key] = PendingNameUpload(owner: owner, waiters: [])
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
            releasePendingUploadClaims(ownedBy: descriptor.source)
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
        releasePendingUploadClaims(ownedBy: descriptor.source)
    }

    /// Reports that an upload attempt for a `.upload` decision ended without success (error,
    /// cancel, or stop). Drops the cached remote view (the server may have committed the attempt
    /// even though the call failed) and releases the same-content claim so identical waiting
    /// items re-resolve against fresh state.
    public func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor.source)
    }

    public func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await invalidateCachedRemoteState()
        releasePendingUploadClaims(ownedBy: descriptor.source)
    }

    private func releasePendingUploadClaims(ownedBy owner: UploadSourceIdentity) {
        for (key, pending) in pendingContentUploads where pending.owner == owner {
            pendingContentUploads[key] = nil
            for waiter in pending.waiters { waiter.resume() }
        }
        for (key, pending) in pendingNameUploads where pending.owner == owner {
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
