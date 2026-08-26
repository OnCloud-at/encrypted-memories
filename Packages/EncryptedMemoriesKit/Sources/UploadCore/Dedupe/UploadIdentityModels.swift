import Foundation
import PhotosCore

// MARK: - Source identity

/// Stable, platform-neutral identity for one uploadable source resource.
/// All upload paths use this vocabulary so the dedupe pipeline stays cross-platform.
public struct UploadSourceIdentity: Sendable, Hashable, Codable {
    /// Which adapter produced the resource - the namespace of `identifier`.
    public enum Kind: String, Sendable, Codable {
        /// A file on disk; `identifier` is the absolute file-system path.
        case fileURL
        /// A photo-library asset resource. Prefer a stable provider identifier when available.
        /// Fall back to a local identifier only when necessary.
        case photoLibraryAsset
    }

    /// The role of this resource within its compound. Kept as an open raw-value wrapper because
    /// PhotoKit can expose more than the original Live-Photo pair: RAW alternates, edited renders,
    /// adjustment data, proxy resources, and additional resource types use the same representation.
    public struct Resource: RawRepresentable, Sendable, Hashable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue.isEmpty ? Self.primary.rawValue : rawValue
        }

        public static let primary = Resource(rawValue: "primary")
        /// Backward-compatible identity for the classic Live Photo paired video.
        public static let livePairedVideo = Resource(rawValue: "livePairedVideo")

        public static func photoKit(role: String, ordinal: Int) -> Resource {
            Resource(rawValue: "photoKit.\(role).\(max(0, ordinal))")
        }
    }

    public let kind: Kind
    public let identifier: String
    public let resource: Resource

    public init(kind: Kind, identifier: String, resource: Resource = .primary) {
        self.kind = kind
        self.identifier = identifier
        self.resource = resource
    }

    /// Identity of a local file upload (the macOS manual path).
    public static func file(_ url: URL, resource: Resource = .primary) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .fileURL, identifier: url.standardizedFileURL.path, resource: resource)
    }
}

// MARK: - Resource descriptor

/// Everything a source adapter must state about one resource before any bytes are read - the input
/// to hashing, cache validity, and the duplicate check. Platform adapters only construct these;
/// they never make dedupe decisions themselves.
public struct UploadResourceDescriptor: Sendable {
    public let source: UploadSourceIdentity
    /// Local file readable for upload. For a deferred PhotoKit descriptor this is a placeholder;
    /// the precomputed digest is sufficient for dedupe and Core materializes a real file only for
    /// an `.upload` decision.
    public let fileURL: URL
    /// The claimed original filename (used for Proton name correction + the name hash).
    public let filename: String
    public let fileSize: Int64
    public let modificationDate: Date
    /// Digest produced while the source streamed its bytes. PhotoKit supplies it before any temp
    /// export; local-file adapters leave it nil and use the shared streaming file hasher.
    public let precomputedSHA1Digest: Data?
    /// Admission intent for local hashing only. It is never persisted or sent to the server.
    public let workIntent: LibraryWorkIntent
    /// The primary resource of this compound when `source.resource` is secondary - lets a future
    /// Live Photo path upload only the missing paired video via `mainPhotoUid`.
    public let mainResource: UploadSourceIdentity?

    public init(
        source: UploadSourceIdentity,
        fileURL: URL,
        filename: String,
        fileSize: Int64,
        modificationDate: Date,
        precomputedSHA1Digest: Data? = nil,
        workIntent: LibraryWorkIntent = .userInitiated,
        mainResource: UploadSourceIdentity? = nil
    ) {
        self.source = source
        self.fileURL = fileURL
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.precomputedSHA1Digest = precomputedSHA1Digest
        self.workIntent = workIntent
        self.mainResource = mainResource
    }

    public func withWorkIntent(_ intent: LibraryWorkIntent) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: fileURL,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modificationDate,
            precomputedSHA1Digest: precomputedSHA1Digest,
            workIntent: intent,
            mainResource: mainResource
        )
    }
}

// MARK: - Computed identity

/// The Proton-compatible identity of one resource: what the duplicate check compares and what the
/// upload itself needs (`expectedSHA1`). Hashes are lowercase hex.
public struct UploadIdentity: Sendable, Equatable, Codable {
    /// Proton-corrected filename (invalid characters replaced, whitespace trimmed) - the name that
    /// is actually uploaded AND hashed, so local and remote agree.
    public let correctedName: String
    /// HMAC-SHA256(correctedName, photos root hash key) - Proton's duplicate lookup key.
    public let nameHash: String
    /// Lowercase hex SHA-1 of the raw file bytes.
    public let sha1Hex: String
    /// The same SHA-1 as 20 raw bytes - passed to the SDK upload as `expectedSHA1`.
    public let sha1Digest: Data
    /// HMAC-SHA256(sha1Hex, photos root hash key) - Proton's content identity.
    public let contentHash: String

    public init(correctedName: String, nameHash: String, sha1Hex: String, sha1Digest: Data, contentHash: String) {
        self.correctedName = correctedName
        self.nameHash = nameHash
        self.sha1Hex = sha1Hex
        self.sha1Digest = sha1Digest
        self.contentHash = contentHash
    }
}

// MARK: - Remote duplicate state

/// One remote row from Proton's find-duplicates endpoint (`DuplicateHashes[]`), reduced to what
/// the decision policy needs. Backend adapters map wire JSON to this; the policy never sees
/// transport types.
public struct RemotePhotoDuplicate: Sendable, Equatable {
    /// `LinkState` raw values of the duplicates payload (Proton Drive iOS 1.61.0,
    /// `FindDuplicatesEndpoint`). A missing state (`nil`) means the link was deleted.
    public enum LinkState: Int, Sendable {
        case draft = 0
        case active = 1
        case trashed = 2
    }

    /// The remote NAME hash this row matched (wire key `Hash`).
    public let nameHash: String
    /// The remote content hash HMAC (wire key `ContentHash`), when the server returns one.
    public let contentHash: String?
    public let linkState: LinkState?
    public let linkID: String?
    /// The uploading client's self-chosen identifier. Core uses it only to distinguish this
    /// installation's interrupted draft from foreign/unknown work.
    public let clientUID: String?

    public init(
        nameHash: String,
        contentHash: String?,
        linkState: LinkState?,
        linkID: String?,
        clientUID: String? = nil
    ) {
        self.nameHash = nameHash
        self.contentHash = contentHash
        self.linkState = linkState
        self.linkID = linkID
        self.clientUID = clientUID
    }
}

// MARK: - Decision

/// The dedupe outcome for one compound. `UploadDuplicateDecisionPolicy` is the sole producer.
///
/// There is no rename case. A name match with different content uploads as a new photo under the same name.
public enum UploadDuplicateDecision: Sendable, Equatable {
    /// Why a compound is skipped instead of uploaded.
    public enum SkipReason: Sendable, Equatable {
        /// An active remote photo already has this exact name + content (and, for compounds, all
        /// secondary resources). Nothing to do.
        case activeDuplicate
        /// The identical photo sits in the user's trash - they deleted it intentionally, so
        /// re-uploading would resurrect unwanted data.
        case trashedDuplicate
        /// A remote DRAFT occupies this name hash (an upload in progress, possibly by another
        /// client). Proton skips rather than racing it.
        case draftExists
        /// The identical photo existed remotely and was deleted (state absent) - treated as a
        /// deliberate user deletion.
        case deletedRemotely
        /// The server confirmed a duplicate but the response was missing the link id - the data
        /// is inconsistent, so the safe action is to not upload.
        case inconsistentRemoteState
        /// The persistent manifest remembers this exact resource as already uploaded / an active
        /// duplicate - skipped without a remote round-trip.
        case knownFromManifest
    }

    /// No remote occupant blocks the compound - push the bytes (with the unchanged name).
    case upload
    /// This installation owns an interrupted remote draft for the name. Upload through Proton's
    /// explicit draft-override path so the stale draft is replaced instead of parking forever.
    case uploadReplacingDraft
    /// The compound (primary + all secondaries) is already represented remotely; do not upload.
    /// `remoteLinkID` identifies the existing primary when the server/manifest provided it.
    case skip(SkipReason, remoteLinkID: String?)
    /// The primary photo exists remotely and stays untouched, but these secondary resources are
    /// missing and should be uploaded with `mainPhotoUid = primaryLinkID`.
    case uploadMissingSecondaries(primaryLinkID: String, missing: [UploadSourceIdentity])

    public var uploadsBytes: Bool {
        switch self {
        case .upload, .uploadReplacingDraft:
            true
        case .skip, .uploadMissingSecondaries:
            false
        }
    }
}

// MARK: - Persistent manifest record

/// One row of the persistent upload-identity manifest: enough to skip rehashing an unchanged local
/// resource and to remember a still-valid duplicate decision. Never stores plaintext content -
/// only names, sizes, dates, and hex hashes.
public struct UploadIdentityRecord: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var filename: String
    public var correctedName: String
    public var fileSize: Int64
    public var modificationDate: Date
    public var sha1Hex: String
    public var nameHash: String
    public var contentHash: String
    /// Fingerprint of the photos-root hash key the HMACs were computed with (an irreversible
    /// digest prefix, never key material). A different epoch - the photos share was recreated -
    /// invalidates the cached HMACs while the SHA-1 stays reusable.
    public var hashKeyEpoch: String
    /// The remote photo this resource is known to be (an active duplicate or our own completed
    /// upload), as `volumeID` + `linkID`.
    public var remoteVolumeID: String?
    public var remoteLinkID: String?
    /// Raw persisted form of the last decision (see `UploadIdentityManifestStore.Outcome`).
    public var outcome: String?
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        filename: String,
        correctedName: String,
        fileSize: Int64,
        modificationDate: Date,
        sha1Hex: String,
        nameHash: String,
        contentHash: String,
        hashKeyEpoch: String,
        remoteVolumeID: String? = nil,
        remoteLinkID: String? = nil,
        outcome: String? = nil,
        updatedAt: Date
    ) {
        self.source = source
        self.filename = filename
        self.correctedName = correctedName
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.sha1Hex = sha1Hex
        self.nameHash = nameHash
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.remoteVolumeID = remoteVolumeID
        self.remoteLinkID = remoteLinkID
        self.outcome = outcome
        self.updatedAt = updatedAt
    }

    /// Conservative cache validity for the SHA-1: reusable only when every cheap attribute still
    /// matches exactly. Any drift - size, mtime, name, or a different claimed filename - forces a
    /// rehash. Equal mtimes compare in the same `timeIntervalSince1970` projection they were
    /// persisted in, so filesystem/date round-trips stay exact.
    public func isValid(for descriptor: UploadResourceDescriptor) -> Bool {
        source == descriptor.source
            && filename == descriptor.filename
            && fileSize == descriptor.fileSize
            && modificationDate.timeIntervalSince1970 == descriptor.modificationDate.timeIntervalSince1970
    }

    /// Cached HMACs (name/content hash) are additionally keyed by the hash-key epoch.
    public func isValid(for descriptor: UploadResourceDescriptor, hashKeyEpoch epoch: String) -> Bool {
        isValid(for: descriptor) && hashKeyEpoch == epoch
    }
}

// MARK: - Pipeline seams

/// Persistent identity manifest - implemented by `UploadIdentityManifestStore` (SQLite) in
/// production and by an in-memory fake in tests.
public protocol UploadIdentityStore: Sendable {
    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord?
    /// Any row proving this content is already represented remotely for this account: same
    /// content-hash HMAC under the same key epoch, with a trustworthy outcome (`uploaded` or
    /// `duplicateActive`) and a remote link. Source-path and filename independent - this is what
    /// lets a copied folder (or a renamed file) skip re-uploading bytes the account already owns.
    /// Trashed and deleted outcomes are not trustworthy here.
    func trustedRecord(contentHash: String, hashKeyEpoch: String) -> UploadIdentityRecord?
    @discardableResult
    func upsert(_ record: UploadIdentityRecord) -> Bool
}

/// One active remote photo identity retained by the local content index. The hash is already keyed
/// to the account's photos root; no plaintext filename or media bytes are stored.
public struct UploadRemoteContentIndexRecord: Sendable, Equatable {
    public var contentHash: String
    public var hashKeyEpoch: String
    public var remoteLinkID: String

    public init(contentHash: String, hashKeyEpoch: String, remoteLinkID: String) {
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.remoteLinkID = remoteLinkID
    }
}

/// One remote photo whose encrypted metadata could not yield a trusted content hash.
///
/// The record deliberately stays inside the account-scoped backend store. UI and logs receive only
/// aggregate counts/reason classes; the remote link identifier is never published as diagnostics.
public struct UploadRemoteContentIndexIssue: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable, Codable {
        case missingLinkMetadata
        case missingKeyMetadata
        case missingEncryptedAttributes
        case missingContentHash
        case decryptFailure
        case invalidAttributes
        case endpointFailure
    }

    public var remoteLinkID: String
    public var reason: Reason
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var lastRepairAttemptAt: Date?
    /// Durable remote event/build identity. This bounds immediate repair to one attempt per
    /// generation while ordinary refresh/backoff decides when a later generation may retry.
    public var indexGeneration: String

    public init(
        remoteLinkID: String,
        reason: Reason,
        firstObservedAt: Date,
        lastObservedAt: Date,
        lastRepairAttemptAt: Date?,
        indexGeneration: String
    ) {
        self.remoteLinkID = remoteLinkID
        self.reason = reason
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.lastRepairAttemptAt = lastRepairAttemptAt
        self.indexGeneration = indexGeneration
    }
}

/// Durable volume-event frontier for the remote content index. A page is applied transactionally
/// with its next event ID, so a crash either replays the whole page or resumes after all its rows.
public struct UploadRemoteContentIndexCheckpoint: Sendable, Equatable {
    public var eventID: String
    public var refreshedAt: Date

    public init(eventID: String, refreshedAt: Date) {
        self.eventID = eventID
        self.refreshedAt = refreshedAt
    }
}

/// Durable cursor for an interrupted full remote-index build. The source list must be sorted
/// deterministically; a matching event ID and source fingerprint allow the next process to resume.
public struct UploadRemoteContentIndexBuildCheckpoint: Sendable, Equatable {
    /// Opaque durable writer fence. A cancelled or superseded rebuild must present the exact token
    /// that owns the current staging tables before it can append or publish rows.
    public var buildID: String
    public var eventID: String
    public var sourceFingerprint: String
    public var cursor: Int
    public var total: Int
    public var updatedAt: Date

    public init(
        buildID: String,
        eventID: String,
        sourceFingerprint: String,
        cursor: Int,
        total: Int,
        updatedAt: Date
    ) {
        self.buildID = buildID
        self.eventID = eventID
        self.sourceFingerprint = sourceFingerprint
        self.cursor = max(0, cursor)
        self.total = max(0, total)
        self.updatedAt = updatedAt
    }
}

/// Remote source identity staged while a full content index is built.
public struct UploadRemoteExternalIdentityRecord: Sendable, Equatable {
    public var remoteLinkID: String
    public var externalIdentity: UploadBackupExternalIdentity

    public init(remoteLinkID: String, externalIdentity: UploadBackupExternalIdentity) {
        self.remoteLinkID = remoteLinkID
        self.externalIdentity = externalIdentity
    }
}

/// Shared preparation state surfaced by every backend that maintains a remote duplicate index.
public struct UploadRemoteIndexPreparationProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case loading
        case indexing
        case applyingChanges
        case ready
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int?

    public init(phase: Phase, completed: Int = 0, total: Int? = nil) {
        self.phase = phase
        self.completed = max(0, completed)
        self.total = total.map { max(0, $0) }
    }
}

/// One active remote compound proved by encrypted source metadata. `remoteLinkIDs` contains the
/// primary and every related resource that contributed to `resourceCount`; any event touching one
/// of those links invalidates the whole proof.
public struct UploadRemoteAssetIndexRecord: Sendable, Equatable {
    public var externalIdentity: UploadBackupExternalIdentity
    public var resourceCount: Int
    public var remoteLinkIDs: [String]
    public var hashKeyEpoch: String

    public init(
        externalIdentity: UploadBackupExternalIdentity,
        resourceCount: Int,
        remoteLinkIDs: [String],
        hashKeyEpoch: String
    ) {
        self.externalIdentity = externalIdentity
        self.resourceCount = max(1, resourceCount)
        self.remoteLinkIDs = remoteLinkIDs
        self.hashKeyEpoch = hashKeyEpoch
    }
}

/// Privacy-safe health summary for the account-wide encrypted content index. Counts are enough for
/// admission and UI warning thresholds; link IDs and hashes never leave the backend/store boundary.
public enum UploadRemoteContentIndexHealth: Sendable, Equatable {
    case complete(indexedCount: Int)
    case degraded(indexedCount: Int, unresolvedCount: Int)
    case unavailable

    public var unresolvedCount: Int {
        if case .degraded(_, let count) = self { return max(0, count) }
        return 0
    }

    public var remoteCount: Int {
        switch self {
        case .complete(let indexedCount):
            max(0, indexedCount)
        case .degraded(let indexedCount, let unresolvedCount):
            max(0, indexedCount) + max(0, unresolvedCount)
        case .unavailable:
            0
        }
    }

    public var warningThreshold: Int {
        min(100, max(10, Int(ceil(Double(remoteCount) * 0.01))))
    }

    public var shouldWarn: Bool {
        unresolvedCount >= warningThreshold
    }
}

/// Persistent, platform-neutral cache for account-wide content dedupe. Proton-specific code owns
/// remote enumeration and event decoding; Core owns the transactional storage contract.
public protocol UploadRemoteContentIndexStore: Sendable {
    func remoteContentRecord(contentHash: String, hashKeyEpoch: String) -> UploadRemoteContentIndexRecord?
    func remoteContentIndexCheckpoint(hashKeyEpoch: String) -> UploadRemoteContentIndexCheckpoint?
    func hasRemoteAssetIndexCheckpoint(hashKeyEpoch: String) -> Bool
    func remoteAssetRecords(
        for identities: [UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    /// Distinguishes readable-but-incomplete remote metadata from a local database failure. Missing
    /// remote hashes may degrade duplicate coverage; an unavailable index must remain fail-closed.
    func remoteContentIndexHealth(hashKeyEpoch: String) -> UploadRemoteContentIndexHealth
    func remoteContentIndexBuildCheckpoint(hashKeyEpoch: String) -> UploadRemoteContentIndexBuildCheckpoint?
    func beginRemoteContentIndexBuild(
        hashKeyEpoch: String,
        eventID: String,
        sourceFingerprint: String,
        total: Int,
        updatedAt: Date
    ) -> UploadRemoteContentIndexBuildCheckpoint?
    @discardableResult
    func appendRemoteContentIndexBuild(
        records: [UploadRemoteContentIndexRecord],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        externalIdentities: [UploadRemoteExternalIdentityRecord],
        hashKeyEpoch: String,
        buildID: String,
        nextCursor: Int,
        updatedAt: Date
    ) -> Bool
    func stagedRemoteExternalIdentities(
        hashKeyEpoch: String,
        buildID: String
    ) -> [String: UploadBackupExternalIdentity]
    @discardableResult
    func finishRemoteContentIndexBuild(
        remoteAssetRecords: [UploadRemoteAssetIndexRecord],
        hashKeyEpoch: String,
        buildID: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool
    @discardableResult
    func invalidateRemoteContentIndexBuild(hashKeyEpoch: String) -> Bool
    @discardableResult
    func replaceRemoteContentIndex(
        _ records: [UploadRemoteContentIndexRecord],
        remoteAssetRecords: [UploadRemoteAssetIndexRecord],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool
    @discardableResult
    func applyRemoteContentIndexChanges(
        upserting records: [UploadRemoteContentIndexRecord],
        upsertingRemoteAssetRecords: [UploadRemoteAssetIndexRecord],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        removingRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        expectedEventID: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool
    @discardableResult
    func upsertRemoteContentRecord(_ record: UploadRemoteContentIndexRecord) -> Bool
}

/// Local content hashing with streaming SHA-1.
/// The protocol lets tests and platform adapters provide hashing without changing the pipeline.
/// Hashing runs asynchronously so concurrent items do not block the queue.
public protocol UploadHashing: Sendable {
    /// The 20-byte SHA-1 of the resource's bytes. Must stream (O(buffer) memory) and must honour
    /// task cancellation between chunks.
    func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data
}

/// Default file-URL hasher used by every platform's local-file path.
public struct UploadFileHasher: UploadHashing {
    public init() {}

    public func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data {
        if let digest = descriptor.precomputedSHA1Digest {
            guard digest.count == 20 else {
                throw UploadError.backend("Invalid precomputed SHA-1 digest")
            }
            return digest
        }
        return try UploadContentSHA1.digest(ofFileAt: descriptor.fileURL)
    }
}

/// Proton-keyed identity hashing + the remote duplicate lookup. Implemented in ProtonDriveBackend
/// (the only layer that can reach the photos root hash key and the authenticated API).
public protocol UploadDuplicateChecking: Sendable {
    /// HMAC-SHA256 over the corrected name, keyed with the photos root hash key. Lowercase hex.
    func nameHash(forCorrectedName name: String) async throws -> String
    /// Batch form used by large backup lookaheads. Implementations that own the key material can
    /// resolve it once and hash the whole batch without one actor hop per filename.
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String]
    /// HMAC-SHA256 over the lowercase-hex SHA-1 string, same key. Lowercase hex.
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String
    /// Remote occupants of the given name hashes. Callers pass at most
    /// `UploadDedupePipeline.protonDuplicateBatchSize` hashes per call.
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate]
    /// SDK-owned exact-match check. Unlike the detailed endpoint seam above, this returns only
    /// active photos whose corrected name and content SHA-1 both match. Implementations may return
    /// an empty list when the SDK call is unavailable; the detailed conservative policy remains.
    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID]
    /// Optional stronger lookup: an active remote photo with the same content hash, independent
    /// of filename/name hash. Backends that cannot provide a remote content index return nil.
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate?
    /// Brings the persistent remote identity index current before a queue starts resolving items.
    /// Backends without such an index use the default no-op implementation.
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth
    /// Exact active-remote proofs for source identities stored in Proton's encrypted metadata.
    /// Missing entries are unknown, never negative proof.
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    /// Drops backend-owned remote duplicate/content caches. Called whenever the upload resolver's
    /// remote view is known stale; the next lookup must re-read server state.
    func invalidateCachedRemoteState() async
    /// Updates backend-owned content indexes after this client commits an upload. This is a local
    /// optimization only; the upload manifest remains the authoritative durability boundary.
    func recordUploaded(contentHash: String, remoteLinkID: String) async
    /// Irreversible fingerprint of the current photos-root hash key (for manifest validity) -
    /// never the key itself.
    func hashKeyEpoch() async throws -> String
}

public extension UploadDuplicateChecking {
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        var hashes: [String] = []
        hashes.reserveCapacity(names.count)
        for name in names {
            hashes.append(try await nameHash(forCorrectedName: name))
        }
        return hashes
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { nil }
    func findExactActiveDuplicates(correctedName: String, sha1Digest: Data) async -> [PhotoUID] { [] }
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .ready))
    }
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        .complete(indexedCount: 0)
    }
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] { [:] }
    func invalidateCachedRemoteState() async {}
    func recordUploaded(contentHash: String, remoteLinkID: String) async {}
}

/// Fail-closed resolver used when the account's identity manifest cannot be opened. Uploading
/// without duplicate checks would violate the "same bytes upload once" contract, so every resolve
/// fails before any media bytes can leave the device.
public struct DedupeUnavailableIdentityResolver: UploadIdentityResolving {
    private let message: String

    public init(message: String = "Duplicate protection is unavailable; upload cannot start safely.") {
        self.message = message
    }

    public func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw UploadError.backend(message)
    }

    public func prime(_ descriptors: [UploadResourceDescriptor]) async {}
    public func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String
    ) async throws {}
    public func invalidateCachedRemoteState() async {}
    public func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {}
}

/// The pipeline seam `UploadManager` uses to resolve a descriptor into identity and decision.
/// `UploadDedupePipeline` serves every platform.
public protocol UploadIdentityResolving: Sendable {
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult
    /// Re-checks a still-valid local upload proof against current remote state without ever
    /// returning a fresh-upload decision. Backup uses this only when an unfinished secondary is
    /// blocked by a draft: if the already-uploaded primary was subsequently trashed/deleted, the
    /// compound must respect that deletion instead of waiting on the secondary forever.
    func revalidateKnownRemote(_ descriptor: UploadResourceDescriptor) async throws -> UploadDuplicateDecision?
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth
    /// Batch-prefetch duplicate states for a fresh enqueue batch (Proton queries name hashes in
    /// chunks of 150). Best-effort: failures surface later through per-item `resolve`.
    func prime(_ descriptors: [UploadResourceDescriptor]) async
    /// Records that `descriptor` was uploaded as `remoteLinkID` so later runs can skip it without
    /// a remote round-trip.
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String)
        async throws
    /// Drops any batch-cached remote duplicate state so the next `resolve` re-queries the server.
    /// Call after a failed or cancelled upload attempt and before rechecking a draft-blocked item.
    /// The server may have committed work that predates the cache, so stale state could double-upload.
    func invalidateCachedRemoteState() async
    /// Call when a `.upload` attempt ends without `recordUploaded` because of an error, cancellation,
    /// or stop. This settles the same-content claim and drops the cached remote view.
    /// Waiting identical items re-resolve instead of hanging. Exactly one of `recordUploaded` or
    /// `uploadDidFail` must follow each `.upload` decision.
    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async
    /// The transport committed remotely, but the caller could not durably queue local
    /// reconciliation. Releases coalescing waiters and invalidates cached duplicate state so all
    /// subsequent work re-queries the server rather than trusting the failed local attempt.
    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async
}

public extension UploadIdentityResolving {
    func revalidateKnownRemote(_ descriptor: UploadResourceDescriptor) async throws -> UploadDuplicateDecision? { nil }
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] { [:] }
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws {
        await progress(.init(phase: .ready))
    }
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        .complete(indexedCount: 0)
    }
    func prime(_ descriptors: [UploadResourceDescriptor]) async {}
    func invalidateCachedRemoteState() async {}
    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {}
    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await uploadDidFail(descriptor)
    }
}

/// The outcome of the pre-upload phase for one resource.
public struct UploadPreflightResult: Sendable, Equatable {
    public let identity: UploadIdentity
    public let decision: UploadDuplicateDecision

    public init(identity: UploadIdentity, decision: UploadDuplicateDecision) {
        self.identity = identity
        self.decision = decision
    }
}

/// Typed proof returned only after the transport reports an irreversible remote commit. Keeping
/// this distinct from a local queue/manifest success lets durable backup code reconcile a commit
/// whose local settlement failed without blindly uploading the bytes again.
public struct UploadRemoteCommitReceipt: Sendable, Equatable, Codable {
    public let remoteVolumeID: String
    public let remoteLinkID: String

    public init(remoteVolumeID: String, remoteLinkID: String) {
        self.remoteVolumeID = remoteVolumeID
        self.remoteLinkID = remoteLinkID
    }
}

/// The only two legal exits from an operation passed to `withUploadDecision`: a decision that did
/// not upload bytes, or a transport-confirmed commit carrying its receipt.
public enum UploadDecisionOperationResult<Value: Sendable>: Sendable {
    case noUpload(Value)
    case remoteCommitted(Value, receipt: UploadRemoteCommitReceipt)
}

/// The server committed bytes, but the local identity manifest could not record the receipt. The
/// caller must persist `receipt` as reconciliation work and must not retry the upload itself.
public struct UploadRemoteCommitSettlementError: LocalizedError, Sendable {
    public let receipt: UploadRemoteCommitReceipt
    public let settlementMessage: String
    public let reconciliationPersisted: Bool

    public init(
        receipt: UploadRemoteCommitReceipt,
        settlementMessage: String,
        reconciliationPersisted: Bool = false
    ) {
        self.receipt = receipt
        self.settlementMessage = settlementMessage
        self.reconciliationPersisted = reconciliationPersisted
    }

    public var errorDescription: String? { settlementMessage }
}

public extension UploadIdentityResolving {
    /// Owns claim acquisition and exactly one logical settlement for an upload decision. Feature
    /// code supplies the transport operation but cannot forget cancellation/error cleanup: an
    /// operation error settles through `uploadDidFail`, while a remote receipt settles through
    /// `recordUploaded`. A manifest failure is surfaced with the receipt for durable reconciliation.
    func withUploadDecision<Value: Sendable>(
        _ descriptor: UploadResourceDescriptor,
        onRemoteCommit: (
            @Sendable (
                _ identity: UploadIdentity,
                _ receipt: UploadRemoteCommitReceipt
            ) async throws -> Void
        )? = nil,
        operation: (UploadPreflightResult) async throws -> UploadDecisionOperationResult<Value>
    ) async throws -> Value {
        let preflight = try await resolve(descriptor)

        guard preflight.decision.uploadsBytes else {
            switch try await operation(preflight) {
            case .noUpload(let value):
                return value
            case .remoteCommitted:
                throw UploadError.backend("Upload decision scope received a remote commit for a no-upload decision")
            }
        }

        do {
            let outcome = try await operation(preflight)
            guard case .remoteCommitted(let value, let receipt) = outcome else {
                throw UploadError.backend("Upload decision scope ended without a remote commit receipt")
            }
            if let onRemoteCommit {
                do {
                    try await onRemoteCommit(preflight.identity, receipt)
                } catch {
                    await remoteCommitNeedsReconciliation(descriptor)
                    throw UploadRemoteCommitSettlementError(
                        receipt: receipt,
                        settlementMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        reconciliationPersisted: false
                    )
                }
            }
            do {
                try await recordUploaded(
                    descriptor,
                    identity: preflight.identity,
                    remoteVolumeID: receipt.remoteVolumeID,
                    remoteLinkID: receipt.remoteLinkID
                )
            } catch {
                throw UploadRemoteCommitSettlementError(
                    receipt: receipt,
                    settlementMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    reconciliationPersisted: onRemoteCommit != nil
                )
            }
            return value
        } catch let settlement as UploadRemoteCommitSettlementError {
            // `recordUploaded` is itself a settlement attempt and the real pipeline releases its
            // owned claims on persistence failure. Do not issue a second logical settlement.
            throw settlement
        } catch {
            await uploadDidFail(descriptor)
            throw error
        }
    }
}
