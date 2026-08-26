import CryptoKit
import Foundation
import PhotosCore
import ProtonDriveSDK
import UploadCore

// MARK: - HMAC

/// The Proton photo identity HMAC: HMAC-SHA256 over the message's UTF-8 bytes, keyed with the
/// decrypted photos-root hash key, lowercase hex - byte-identical to the reference clients
/// (CommonCrypto there, CryptoKit here; the algorithm is the same).
enum ProtonPhotoHMAC {
    static func hex(message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Duplicate service

enum ProtonUploadDedupeError: LocalizedError {
    /// The photos root link carried no `FolderProperties.NodeHashKey` - without it no
    /// Proton-compatible identity can be computed, so dedupe (and upload preflight) must fail
    /// rather than guess.
    case missingRootHashKey

    var errorDescription: String? {
        switch self {
        case .missingRootHashKey: "The photo library's hash key is unavailable."
        }
    }
}

/// `UploadDuplicateChecking` over the real Proton account: resolves and caches the photos-root
/// hash key through the Drive key chain (share key, root node key, and decrypted `NodeHashKey`),
/// computes the identity HMACs, and queries the find-duplicates endpoint.
///
/// Privacy: never logs names, hashes, or key material - only counts.
actor ProtonUploadDedupeService: UploadDuplicateChecking {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let photosClient: EncryptedMemoriesClient
    private let contentIndexStore: any UploadRemoteContentIndexStore
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    private struct Material: Sendable {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let hashKey: Data
        let epoch: String
    }

    private var material: Material?
    private var materialTask: Task<Material, any Error>?
    private var remoteContentIndexTask: Task<Void, any Error>?
    private var remoteIndexProgressHandlers: [UUID: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void] =
        [:]
    private var remoteContentIndexGeneration = 0
    private var lastRemoteContentRefreshAt: Date?
    private static let remoteContentIndexLifetime: TimeInterval = 15
    /// Four metadata requests overlap network latency without producing the unbounded request fan-out
    /// used by the reference client. Decryption and the transactional store update remain serialized.
    private static let remoteMetadataRequestConcurrency = 4
    private static let remoteMetadataWindow =
        UploadDedupePipeline.protonDuplicateBatchSize * remoteMetadataRequestConcurrency

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        photosClient: EncryptedMemoriesClient,
        contentIndexStore: any UploadRemoteContentIndexStore,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.photosClient = photosClient
        self.contentIndexStore = contentIndexStore
        self.contextProvider = contextProvider
    }

    // MARK: UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: name, key: try await resolveMaterial().hashKey)
    }

    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        let key = try await resolveMaterial().hashKey
        return names.map { ProtonPhotoHMAC.hex(message: $0, key: key) }
    }

    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: sha1Hex, key: try await resolveMaterial().hashKey)
    }

    func hashKeyEpoch() async throws -> String {
        try await resolveMaterial().epoch
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        let context = try await resolveMaterial().context
        let entries = try await session.findPhotoDuplicates(volumeID: context.volumeID, nameHashes: nameHashes)
        DebugLog.log("[Dedupe] duplicates query hashes=\(nameHashes.count) matches=\(entries.count)")
        return entries.map { entry in
            RemotePhotoDuplicate(
                nameHash: entry.hash,
                contentHash: entry.contentHash,
                linkState: entry.linkState.flatMap(RemotePhotoDuplicate.LinkState.init(rawValue:)),
                linkID: entry.linkID,
                clientUID: entry.clientUID
            )
        }
    }

    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] {
        do {
            let matches = try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                try await photosClient.findPhotoDuplicates(
                    name: correctedName,
                    sha1: sha1Digest,
                    cancellationToken: cancellationToken
                )
            } cancel: { [photosClient] cancellationToken in
                try? await photosClient.cancelFindPhotoDuplicates(cancellationToken: cancellationToken)
            }
            DebugLog.log("[Dedupe] SDK exact query matches=\(matches.count)")
            return matches.map { PhotoUID(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        } catch {
            // Keep the already-proven detailed endpoint as a compatibility fallback if the
            // fresh wrapper/native route fails.
            DebugLog.log("[Dedupe] SDK exact query unavailable; using detailed fallback - \(error)")
            return []
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        let record = contentIndexStore.remoteContentRecord(
            contentHash: contentHash,
            hashKeyEpoch: material.epoch
        )
        let health = contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch)
        if record == nil, case .degraded(_, let unresolvedCount) = health {
            DebugLog.log(
                "[Dedupe] content miss with incomplete remote metadata; continuing availability-first unresolved=\(unresolvedCount)"
            )
        }
        return try ProtonRemoteContentIndexLookup.duplicate(
            contentHash: contentHash,
            record: record,
            health: health
        )
    }

    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        let health = contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch)
        guard health != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        return health
    }

    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        let token = UUID()
        remoteIndexProgressHandlers[token] = progress
        await progress(.init(phase: .loading))
        defer { remoteIndexProgressHandlers[token] = nil }
        let material = try await resolveMaterial()
        if let checkpoint = contentIndexStore.remoteContentIndexBuildCheckpoint(hashKeyEpoch: material.epoch) {
            await progress(.init(phase: .indexing, completed: checkpoint.cursor, total: checkpoint.total))
        }
        try await refreshRemoteContentIndex(material: material)
        guard contentIndexStore.remoteContentIndexHealth(hashKeyEpoch: material.epoch) != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        await progress(.init(phase: .ready))
    }

    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        guard !identities.isEmpty else { return [:] }
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        return contentIndexStore.remoteAssetRecords(
            for: identities,
            hashKeyEpoch: material.epoch
        )
    }

    func invalidateCachedRemoteState() async {
        remoteContentIndexGeneration += 1
        lastRemoteContentRefreshAt = nil
        remoteContentIndexTask?.cancel()
        remoteContentIndexTask = nil
        if let material {
            _ = contentIndexStore.invalidateRemoteContentIndexBuild(hashKeyEpoch: material.epoch)
        }
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        guard let material = try? await resolveMaterial() else { return }
        _ = contentIndexStore.upsertRemoteContentRecord(
            UploadRemoteContentIndexRecord(
                contentHash: contentHash,
                hashKeyEpoch: material.epoch,
                remoteLinkID: remoteLinkID
            ))
    }

    // MARK: Key material

    /// Share bootstrap + root link fetch + key-chain decryption, resolved once and cached for the
    /// service's lifetime (the bridge is rebuilt on sign-in, so the cache can't outlive the
    /// account). Coalesced behind a task so concurrent first calls resolve once.
    private func resolveMaterial() async throws -> Material {
        if let material { return material }
        if let materialTask { return try await materialTask.value }
        let session = self.session
        let crypto = self.crypto
        let contextProvider = self.contextProvider
        let task = Task { () -> Material in
            let context = try await contextProvider()
            let bootstrap = try await session.getJSON("/drive/shares/\(context.shareID)", as: DedupeShareBootstrap.self)
            let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
            let response = try await session.getJSON(
                "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)",
                as: DedupeRootLinkResponse.self
            )
            guard let armoredHashKey = response.link.folderProperties?.nodeHashKey else {
                throw ProtonUploadDedupeError.missingRootHashKey
            }
            let nodeKey = try crypto.unlockNode(
                key: response.link.nodeKey,
                passphrase: response.link.nodePassphrase,
                parent: shareKey
            )
            let hashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: nodeKey).utf8)
            // Irreversible fingerprint for manifest validity - never the key itself.
            let epoch = SHA256.hash(data: hashKey).prefix(8).map { String(format: "%02x", $0) }.joined()
            DebugLog.log("[Dedupe] photos root hash key resolved (epoch \(epoch))")
            return Material(context: context, rootKey: nodeKey, hashKey: hashKey, epoch: epoch)
        }
        materialTask = task
        defer { materialTask = nil }
        do {
            let resolved = try await task.value
            material = resolved
            return resolved
        } catch {
            DebugLog.log("[Dedupe] hash key resolution FAILED - \(error)")
            throw error
        }
    }

    // MARK: Remote content index

    private func refreshRemoteContentIndex(material: Material) async throws {
        if let lastRemoteContentRefreshAt,
            Date().timeIntervalSince(lastRemoteContentRefreshAt) < Self.remoteContentIndexLifetime
        {
            return
        }
        if let remoteContentIndexTask { return try await remoteContentIndexTask.value }

        let session = self.session
        let crypto = self.crypto
        let store = self.contentIndexStore
        let generation = remoteContentIndexGeneration
        let report: @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { [weak self] value in
            await self?.emitRemoteIndexProgress(value)
        }
        let task = Task {
            if let checkpoint = store.remoteContentIndexCheckpoint(hashKeyEpoch: material.epoch),
                store.hasRemoteAssetIndexCheckpoint(hashKeyEpoch: material.epoch)
            {
                try await Self.applyRemoteEvents(
                    from: checkpoint,
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store,
                    progress: report
                )
            } else {
                try await Self.rebuildRemoteContentIndex(
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store,
                    progress: report
                )
            }
        }
        remoteContentIndexTask = task
        do {
            try await task.value
            guard remoteContentIndexGeneration == generation else { throw CancellationError() }
            remoteContentIndexTask = nil
            lastRemoteContentRefreshAt = Date()
        } catch {
            if remoteContentIndexGeneration == generation { remoteContentIndexTask = nil }
            throw error
        }
    }

    private func emitRemoteIndexProgress(_ value: UploadRemoteIndexPreparationProgress) async {
        for handler in remoteIndexProgressHandlers.values { await handler(value) }
    }

    private static func rebuildRemoteContentIndex(
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore,
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .loading))
        let eventID = try await session.latestVolumeEventID(volumeID: material.context.volumeID)
        var sourceIDs = Set<String>()
        try await session.forEachPhotosListPage(volumeID: material.context.volumeID) { page in
            try Task.checkCancellation()
            for photo in page {
                sourceIDs.insert(photo.linkID)
                sourceIDs.formUnion(photo.relatedPhotos.map(\.linkID))
            }
        }
        let ids = sourceIDs.sorted()
        var sourceHasher = SHA256()
        for id in ids {
            sourceHasher.update(data: Data(id.utf8))
            sourceHasher.update(data: Data([0]))
        }
        let sourceFingerprint = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard
            let build = store.beginRemoteContentIndexBuild(
                hashKeyEpoch: material.epoch,
                eventID: eventID,
                sourceFingerprint: sourceFingerprint,
                total: ids.count,
                updatedAt: Date()
            )
        else {
            throw UploadError.backend("Remote duplicate index checkpoint could not be saved")
        }
        await progress(.init(phase: .indexing, completed: build.cursor, total: ids.count))
        for start in stride(from: build.cursor, to: ids.count, by: remoteMetadataWindow) {
            try Task.checkCancellation()
            let end = min(start + remoteMetadataWindow, ids.count)
            let window = Array(ids[start..<end])
            let fetched = try await fetchLinks(
                ids: window,
                shareID: material.context.shareID,
                session: session
            )
            var rows = try makeIndexRows(
                links: fetched.links,
                expectedActiveFileIDs: Set(window),
                endpointFailureIDs: fetched.endpointFailureIDs,
                material: material,
                crypto: crypto,
                generation: eventID
            )
            await repairUnresolvedRows(
                &rows,
                links: fetched.links,
                material: material,
                session: session,
                crypto: crypto
            )
            let external = rows.externalIdentitiesByLinkID.map {
                UploadRemoteExternalIdentityRecord(remoteLinkID: $0.key, externalIdentity: $0.value)
            }
            guard
                store.appendRemoteContentIndexBuild(
                    records: rows.records,
                    unresolvedIssues: rows.unresolvedIssues,
                    externalIdentities: external,
                    hashKeyEpoch: material.epoch,
                    buildID: build.buildID,
                    nextCursor: end,
                    updatedAt: Date()
                )
            else {
                throw UploadError.backend("Remote duplicate index checkpoint could not be saved")
            }
            await progress(.init(phase: .indexing, completed: end, total: ids.count))
        }
        await progress(.init(phase: .applyingChanges, completed: ids.count, total: ids.count))
        let externalIdentities = store.stagedRemoteExternalIdentities(
            hashKeyEpoch: material.epoch,
            buildID: build.buildID
        )
        // The first pass establishes the deterministic checkpoint source. Re-read the relationship
        // pages after metadata is staged, but retain only the proof accumulator rather than the full
        // remote listing. Cross-page ambiguity remains global inside the accumulator.
        var proofAccumulator = RemotePhotoAssetProofBuilder.Accumulator(hashKeyEpoch: material.epoch)
        try await session.forEachPhotosListPage(volumeID: material.context.volumeID) { page in
            try Task.checkCancellation()
            proofAccumulator.append(
                photos: page,
                externalIdentitiesByLinkID: externalIdentities
            )
        }
        let remoteAssetRecords = proofAccumulator.finish()
        let checkpoint = UploadRemoteContentIndexCheckpoint(eventID: eventID, refreshedAt: Date())
        guard
            store.finishRemoteContentIndexBuild(
                remoteAssetRecords: remoteAssetRecords,
                hashKeyEpoch: material.epoch,
                buildID: build.buildID,
                checkpoint: checkpoint
            )
        else {
            throw UploadError.backend("Remote duplicate index could not be saved")
        }
        DebugLog.log(
            "[Dedupe] remote content index rebuilt links=\(ids.count)"
        )
    }

    private static func applyRemoteEvents(
        from checkpoint: UploadRemoteContentIndexCheckpoint,
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore,
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void = { _ in }
    ) async throws {
        await progress(.init(phase: .applyingChanges))
        var eventID = checkpoint.eventID
        while true {
            try Task.checkCancellation()
            let page = try await session.fetchVolumeEvents(
                volumeID: material.context.volumeID,
                since: eventID
            )
            if page.requiresRefresh {
                try await rebuildRemoteContentIndex(
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store,
                    progress: progress
                )
                return
            }

            let relevant = page.events.filter { event in
                event.eventType == 0
                    || event.contextShareID == material.context.shareID
            }
            let removedIDs = Array(Set(relevant.map(\.linkID)))
            let activeFileIDs = Set(
                relevant.compactMap { event -> String? in
                    guard event.eventType != 0 else { return nil }
                    if let type = event.linkType, type != 2 { return nil }
                    if let state = event.linkState, state != 1 { return nil }
                    return event.linkID
                })
            let fetched = try await fetchLinks(
                ids: Array(activeFileIDs),
                shareID: material.context.shareID,
                session: session
            )
            var rows = try makeIndexRows(
                links: fetched.links,
                expectedActiveFileIDs: activeFileIDs,
                endpointFailureIDs: fetched.endpointFailureIDs,
                material: material,
                crypto: crypto,
                generation: page.eventID
            )
            await repairUnresolvedRows(
                &rows,
                links: fetched.links,
                material: material,
                session: session,
                crypto: crypto
            )
            let next = UploadRemoteContentIndexCheckpoint(eventID: page.eventID, refreshedAt: Date())
            guard
                store.applyRemoteContentIndexChanges(
                    upserting: rows.records,
                    upsertingRemoteAssetRecords: rows.remoteAssetRecords,
                    unresolvedIssues: rows.unresolvedIssues,
                    removingRemoteLinkIDs: removedIDs,
                    hashKeyEpoch: material.epoch,
                    expectedEventID: eventID,
                    checkpoint: next
                )
            else {
                throw UploadError.backend("Remote duplicate index changes could not be saved")
            }
            eventID = page.eventID
            if !page.hasMore { return }
        }
    }

    private struct RemoteMetadataFetch {
        var links: [String: AlbumPhotoLinkBody]
        var endpointFailureIDs: Set<String>
    }

    private static func fetchLinks(
        ids: [String],
        shareID: String,
        session: DriveSession
    ) async throws -> RemoteMetadataFetch {
        guard !ids.isEmpty else { return RemoteMetadataFetch(links: [:], endpointFailureIDs: []) }
        let chunks = stride(from: 0, to: ids.count, by: UploadDedupePipeline.protonDuplicateBatchSize).map { start in
            Array(ids[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, ids.count)])
        }
        var links: [String: AlbumPhotoLinkBody] = [:]
        links.reserveCapacity(ids.count)
        var endpointFailureIDs: Set<String> = []

        await withTaskGroup(of: ([AlbumPhotoLinkBody], [String]).self) { group in
            var nextChunk = 0

            func submitNext() {
                guard nextChunk < chunks.count else { return }
                let chunk = chunks[nextChunk]
                nextChunk += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (try await session.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: chunk), [])
                    } catch {
                        return ([], chunk)
                    }
                }
            }

            for _ in 0..<min(Self.remoteMetadataRequestConcurrency, chunks.count) {
                submitNext()
            }
            while let (batch, failedIDs) = await group.next() {
                for link in batch {
                    if let id = link.linkID { links[id] = link }
                }
                endpointFailureIDs.formUnion(failedIDs)
                submitNext()
            }
        }

        // One immediate targeted re-fetch repairs partial/missed metadata responses without ever
        // downloading originals. A second failure becomes a typed unresolved row below; it does not
        // turn an otherwise readable remote index into a global backup stop.
        let missing = ids.filter { links[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: UploadDedupePipeline.protonDuplicateBatchSize) {
            try Task.checkCancellation()
            let batch = Array(
                missing[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, missing.count)])
            guard let retry = try? await session.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: batch) else {
                endpointFailureIDs.formUnion(batch)
                continue
            }
            for link in retry {
                if let id = link.linkID {
                    links[id] = link
                    endpointFailureIDs.remove(id)
                }
            }
        }
        if links.count < ids.count {
            DebugLog.log("[Dedupe] metadata re-fetch unresolved=\(ids.count - links.count)")
        }
        return RemoteMetadataFetch(links: links, endpointFailureIDs: endpointFailureIDs)
    }

    private struct RemoteContentIndexRows {
        var records: [UploadRemoteContentIndexRecord] = []
        var remoteAssetRecords: [UploadRemoteAssetIndexRecord] = []
        var unresolvedIssues: [UploadRemoteContentIndexIssue] = []
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]

        mutating func merge(_ other: Self) {
            records.append(contentsOf: other.records)
            unresolvedIssues.append(contentsOf: other.unresolvedIssues)
            externalIdentitiesByLinkID.merge(other.externalIdentitiesByLinkID) { _, new in new }
        }
    }

    private static func makeIndexRows(
        links: [String: AlbumPhotoLinkBody],
        expectedActiveFileIDs: Set<String>,
        endpointFailureIDs: Set<String>,
        material: Material,
        crypto: DriveCrypto,
        generation: String,
        observedAt: Date = Date()
    ) throws -> RemoteContentIndexRows {
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardDateFormatter = ISO8601DateFormatter()
        standardDateFormatter.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: String) -> Date? {
            fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
        }

        var records: [UploadRemoteContentIndexRecord] = []
        records.reserveCapacity(expectedActiveFileIDs.count)
        var unresolved: [UploadRemoteContentIndexIssue] = []
        func issue(_ id: String, _ reason: UploadRemoteContentIndexIssue.Reason) -> UploadRemoteContentIndexIssue {
            UploadRemoteContentIndexIssue(
                remoteLinkID: id,
                reason: reason,
                firstObservedAt: observedAt,
                lastObservedAt: observedAt,
                lastRepairAttemptAt: nil,
                indexGeneration: generation
            )
        }
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]
        externalIdentitiesByLinkID.reserveCapacity(expectedActiveFileIDs.count)
        for id in expectedActiveFileIDs {
            try Task.checkCancellation()
            guard let link = links[id] else {
                unresolved.append(issue(id, endpointFailureIDs.contains(id) ? .endpointFailure : .missingLinkMetadata))
                continue
            }
            guard link.type == nil || link.type == 2,
                link.state == nil || link.state == 1
            else {
                continue
            }
            guard let nodeKey = link.nodeKey, let nodePassphrase = link.nodePassphrase else {
                unresolved.append(issue(id, .missingKeyMetadata))
                continue
            }
            guard let armoredXAttr = link.xAttr ?? link.fileProperties?.activeRevision?.xAttr else {
                unresolved.append(issue(id, .missingEncryptedAttributes))
                continue
            }
            let fileKey: UnlockableKey
            let data: Data
            do {
                fileKey = try crypto.unlockNode(
                    key: nodeKey,
                    passphrase: nodePassphrase,
                    parent: material.rootKey
                )
                data = try crypto.decryptXAttr(armoredXAttr, node: fileKey)
            } catch {
                unresolved.append(issue(id, .decryptFailure))
                continue
            }
            let attributes: DedupeXAttr
            do {
                attributes = try JSONDecoder().decode(DedupeXAttr.self, from: data)
            } catch {
                unresolved.append(issue(id, .invalidAttributes))
                continue
            }
            if let iOSPhotos = attributes.iOSPhotos,
                let cloudID = iOSPhotos.iCloudID,
                !cloudID.isEmpty,
                let rawDate = iOSPhotos.modificationTime,
                let modificationDate = parseDate(rawDate)
            {
                externalIdentitiesByLinkID[id] = UploadBackupExternalIdentity(
                    identifier: cloudID,
                    modificationDate: modificationDate
                )
            }
            guard let sha1 = attributes.common?.digests?.sha1?.lowercased(), !sha1.isEmpty else {
                unresolved.append(issue(id, .missingContentHash))
                continue
            }
            records.append(
                UploadRemoteContentIndexRecord(
                    contentHash: ProtonPhotoHMAC.hex(message: sha1, key: material.hashKey),
                    hashKeyEpoch: material.epoch,
                    remoteLinkID: id
                ))
        }

        return RemoteContentIndexRows(
            records: records,
            unresolvedIssues: unresolved,
            externalIdentitiesByLinkID: externalIdentitiesByLinkID
        )
    }

    /// One bounded repair attempt for rows whose xattrs did not yield a content hash. The remote
    /// encrypted name is decrypted locally, corrected exactly like an upload name, HMACed locally,
    /// and queried through Proton's existing duplicate endpoint. Only an exact returned LinkID may
    /// repair a row; no original bytes are downloaded.
    private static func repairUnresolvedRows(
        _ rows: inout RemoteContentIndexRows,
        links: [String: AlbumPhotoLinkBody],
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        attemptedAt: Date = Date()
    ) async {
        guard !rows.unresolvedIssues.isEmpty else { return }
        var linkIDsByNameHash: [String: Set<String>] = [:]
        for index in rows.unresolvedIssues.indices {
            rows.unresolvedIssues[index].lastRepairAttemptAt = attemptedAt
            let id = rows.unresolvedIssues[index].remoteLinkID
            guard let armoredName = links[id]?.name else { continue }
            do {
                let clearName = try crypto.decryptName(armoredName, parent: material.rootKey)
                let corrected = ProtonPhotoNameCorrection.correctedName(for: clearName)
                let nameHash = ProtonPhotoHMAC.hex(message: corrected, key: material.hashKey)
                linkIDsByNameHash[nameHash, default: []].insert(id)
            } catch {
                rows.unresolvedIssues[index].reason = .decryptFailure
            }
        }

        var repaired: [String: UploadRemoteContentIndexRecord] = [:]
        let hashes = linkIDsByNameHash.keys.sorted()
        for start in stride(from: 0, to: hashes.count, by: UploadDedupePipeline.protonDuplicateBatchSize) {
            let batch = Array(hashes[start..<min(start + UploadDedupePipeline.protonDuplicateBatchSize, hashes.count)])
            do {
                let duplicates = try await session.findPhotoDuplicates(
                    volumeID: material.context.volumeID,
                    nameHashes: batch
                )
                for duplicate in duplicates {
                    guard let linkID = duplicate.linkID,
                        let expectedLinkIDs = linkIDsByNameHash[duplicate.hash],
                        expectedLinkIDs.contains(linkID),
                        duplicate.linkState == nil || duplicate.linkState == 1,
                        let contentHash = duplicate.contentHash,
                        !contentHash.isEmpty
                    else { continue }
                    repaired[linkID] = UploadRemoteContentIndexRecord(
                        contentHash: contentHash,
                        hashKeyEpoch: material.epoch,
                        remoteLinkID: linkID
                    )
                }
            } catch {
                let failedHashes = Set(batch)
                for index in rows.unresolvedIssues.indices {
                    let linkID = rows.unresolvedIssues[index].remoteLinkID
                    if failedHashes.contains(where: { linkIDsByNameHash[$0]?.contains(linkID) == true }) {
                        rows.unresolvedIssues[index].reason = .endpointFailure
                    }
                }
            }
        }
        rows.records.append(contentsOf: repaired.values)
        rows.unresolvedIssues.removeAll { repaired[$0.remoteLinkID] != nil }

        if !rows.unresolvedIssues.isEmpty {
            let counts = Dictionary(grouping: rows.unresolvedIssues, by: \.reason)
                .map { "\($0.key.rawValue)=\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            DebugLog.log(
                "[Dedupe] degraded remote metadata unresolved=\(rows.unresolvedIssues.count) reasons=\(counts)"
            )
        }
    }
}

/// Narrow availability-first rule: an exact indexed match still wins; a readable index with remote
/// rows missing encrypted SHA-1 metadata permits upload on a content miss; local index failure does not.
enum ProtonRemoteContentIndexLookup {
    static func duplicate(
        contentHash: String,
        record: UploadRemoteContentIndexRecord?,
        health: UploadRemoteContentIndexHealth
    ) throws -> RemotePhotoDuplicate? {
        if let record {
            return RemotePhotoDuplicate(
                nameHash: "",
                contentHash: contentHash,
                linkState: .active,
                linkID: record.remoteLinkID
            )
        }
        guard health != .unavailable else {
            throw UploadError.backend("Remote duplicate index is unavailable")
        }
        return nil
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct DedupeShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case passphrase = "Passphrase"
    }
}

private struct DedupeRootLinkResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }

    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: FolderProperties?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey"
            case nodePassphrase = "NodePassphrase"
            case folderProperties = "FolderProperties"
        }

        struct FolderProperties: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}

// MARK: - Duplicates endpoint (DriveSession)

/// One row of `DuplicateHashes` from the find-duplicates endpoint. `linkState`: 0 = draft,
/// 1 = active, 2 = trashed, absent = deleted.
struct PhotoDuplicateEntry: Decodable {
    let hash: String
    let contentHash: String?
    let linkState: Int?
    let clientUID: String?
    let linkID: String?
    enum CodingKeys: String, CodingKey {
        case hash = "Hash"
        case contentHash = "ContentHash"
        case linkState = "LinkState"
        case
            clientUID = "ClientUID"
        case linkID = "LinkID"
    }
}

private struct PhotoDuplicatesResponse: Decodable {
    let duplicateHashes: [PhotoDuplicateEntry]?
    enum CodingKeys: String, CodingKey { case duplicateHashes = "DuplicateHashes" }
}

extension DriveSession {
    /// Queries which of `nameHashes` already exist in the photo volume - the Proton duplicate
    /// check. Callers batch to Proton's request size (150); this sends one request.
    func findPhotoDuplicates(volumeID: String, nameHashes: [String]) async throws -> [PhotoDuplicateEntry] {
        guard !nameHashes.isEmpty else { return [] }
        let data = try await send(
            "/drive/volumes/\(volumeID)/photos/duplicates",
            method: "POST",
            body: ["NameHashes": nameHashes],
            retryOnRateLimit: true
        )
        return (try JSONDecoder().decode(PhotoDuplicatesResponse.self, from: data)).duplicateHashes ?? []
    }
}
