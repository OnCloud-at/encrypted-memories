import AVFoundation
import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK
import UploadCore

private typealias LibraryPhotoTag = PhotosCore.PhotoTag

/// Bridges the feature modules to the Proton Drive SDK. Owns the `EncryptedMemoriesClient`, wires in
/// our HTTP + account clients, resolves the photos root, and adapts SDK types to `PhotosCore`.
///
/// Everything SDK-specific is isolated here so feature modules stay SDK-agnostic and new SDK
/// capabilities (albums, sharing, upload) can be added without touching the UI layer.
actor DriveSDKBridge: PhotosRepository, LibraryChangeTokenProvider, ThumbnailProvider, ThumbnailBatchLoader,
    PriorityThumbnailBatchLoader, FullMediaProvider, OriginalByteStreamProvider, OriginalFileProvider,
    VideoStreamProvider, PhotoMetadataProvider, BurstGroupProvider, PhotoLibraryProvider, FavoritesProvider,
    TrashProvider, LibraryStatsProvider
{
    private let photosClient: EncryptedMemoriesClient
    private let uploadClientUID: String
    private let driveSession: DriveSession
    private let requestGovernor = ProtonRequestGovernor()
    private var photosRoot: SDKNodeUid?
    private var photosShareID: String?
    /// App-owned SQLite timeline metadata store (`library-v1.sqlite`, PhotosCore). The bridge is
    /// the macOS adapter: it chooses the path + desktop SQLite tuning and injects both; schema and
    /// save/load logic live in Core.
    private let timelineStore: TimelineMetadataStore?
    /// Drive key-derivation + block decryption for video streaming (built once at sign-in).
    private let crypto: DriveCrypto
    private let photosVolumeBootstrap: PhotosVolumeBootstrapService
    private var streamSource: PhotoVideoStreamSource?
    /// Reused by burst viewer opens after the timeline enrichment already paid for the server listing.
    /// A timeline refresh replaces it atomically; a lookup miss fetches once to cover a newly-arrived burst.
    private var burstCatalogEntries: [PhotosListEntry]?
    private var burstCatalogLookup: [String: [String]] = [:]
    /// Account-scoped single flight for authoritative enumeration. Actor reentrancy alone does not serialize
    /// work across awaits; without this, foreground lifecycle, upload refresh and a second Mac window can all
    /// enumerate the same 20k-item library concurrently.
    private var timelineLoadTask: (generation: UInt64, task: Task<TimelineLoadSnapshot, any Error>)?
    private var timelineLoadGeneration: UInt64 = 0
    /// Three-pass quiet-window proof for a full Photos listing after event history becomes unusable. This state
    /// is intentionally memory-only; a relaunch restarts proof instead of trusting a partially observed window.
    private var continuityRecovery = TimelineContinuityRecoveryCoordinator()
    /// Primary uploads returned by the SDK but not yet observed in an authoritative photos listing.
    private var pendingUploadedNodeIDs = Set<String>()
    /// Low-priority, resumable reconciliation of lossy timeline tags with authoritative link MIME types.
    /// One task per bridge keeps lifecycle refreshes from starting duplicate scans.
    private var mediaTypeReconciliationTask: Task<Void, Never>?
    private var isShutDown = false
    private nonisolated let shutdownGate = JoinedShutdownGate()
    /// Where the per-account upload-identity manifest lives (next to `library-v1.sqlite`, so the
    /// sign-out purge covers it) and the platform SQLite tuning it opens with. Module-internal:
    /// the facade derives the account data directory + store policy for the backup sync stores
    /// (same directory, same purge coverage).
    let uploadManifestURL: URL
    let uploadManifestPolicy: LibraryDatabasePolicy

    /// Full sign-out / master-reset: erase the SDK metadata SQLite stores for `uid` (security
    /// follow-up #2 - non-secret node metadata that must not survive sign-out) AND the app-owned
    /// `library-v1.sqlite` account directory. The encrypted caches, video blocks, and account-data
    /// cache are erased by their own paths; this covers the remaining account-tied data at rest.
    /// Wired from `AppModel.signOut`.
    static func purgeMetadata(uid: String, policy: ProtonDriveBackendPolicy) {
        SDKMetadataStore.purgeMetadata(in: policy.sdkCacheDirectory, uid: uid)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: policy.libraryDatabaseBaseDirectory)
    }

    init(
        session: ProtonSession,
        store: SessionKeychainStore,
        policy: ProtonDriveBackendPolicy,
        deviceIdentityStore: DeviceIdentityKeychainStore = DeviceIdentityKeychainStore()
    ) async throws {
        let driveSession = DriveSession(
            session: session,
            store: store,
            config: .externalDriveEncryptedMemories,
            accountCacheDirectory: policy.sdkCacheDirectory,
            requestGovernor: requestGovernor
        )
        self.driveSession = driveSession

        DebugLog.log("bridge: fetching account data…")
        // Build the account client (fetch + decrypt the user's keys) up front. If the network is unavailable
        // (cold offline launch), fall back to the encrypted account cache persisted on a previous online launch,
        // so the library still opens (read-only, on cached data) instead of failing the whole signed-in UI.
        let account: AccountData
        do {
            account = try await driveSession.fetchAccountData()
            DebugLog.log(
                "bridge: account ok - \(account.addresses.count) addresses, \(account.userKeys.count) user keys")
        } catch {
            guard let cached = driveSession.cachedAccountData() else { throw error }
            account = cached
            DebugLog.log("bridge: OFFLINE - using cached account data (\(cached.addresses.count) addresses)")
        }
        let accountClient = try SDKAccountClientBuilder.build(account: account, keyPassword: session.keyPassword)
        DebugLog.log("bridge: account client built (\(accountClient.unlockedByKeyID.count) unlocked keys)")

        // Crypto for streaming: the same address keys, kept as (armored, passphrase) so we can
        // derive share/node keys and the per-file content session key on demand.
        let crypto = DriveCrypto(account: account, keyPassword: session.keyPassword)
        self.crypto = crypto
        self.photosVolumeBootstrap = PhotosVolumeBootstrapService(session: driveSession, crypto: crypto)

        let caches = policy.sdkCacheDirectory
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // Persisted timeline (per account) for instant startup. The store lives in PhotosCore at
        // Application Support/EncryptedMemories/<uid>/library-v1.sqlite (backup-excluded, re-derivable).
        let libraryDirectory = LibraryDatabaseLocation.prepareAccountDirectory(
            uid: session.uid,
            in: policy.libraryDatabaseBaseDirectory
        )
        self.timelineStore = TimelineMetadataStore(
            url: libraryDirectory.appendingPathComponent(LibraryDatabaseLocation.databaseFileName),
            policy: policy.libraryDatabasePolicy
        )
        self.uploadManifestURL = libraryDirectory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        self.uploadManifestPolicy = policy.libraryDatabasePolicy
        // The SDK cache contains both entity and secret material. Persist it only under a
        // stable account-bound 32-byte key; a missing key would make the SDK write plaintext.
        let uploadClientUID = UploadClientIdentity.make(
            accountUID: session.uid,
            deviceIdentifier: deviceIdentityStore.loadOrCreate()
        )
        self.uploadClientUID = uploadClientUID
        let uploadBufferSize = UploadTransportBufferPolicy.bufferSize()
        let config = ProtonDriveClientConfiguration(
            baseURL: "https://drive-api.proton.me/",  // trailing slash required by the C# core
            clientUID: uploadClientUID,
            httpTransferBufferSize: uploadBufferSize,
            boundStreamsCreator: {
                try UploadTransportBufferPolicy.makeBoundStreams(bufferSize: uploadBufferSize)
            },
            cachePath: caches.appendingPathComponent(
                SDKCacheProtection.fileName(accountUID: session.uid)
            ).path,
            cacheEncryptionKey: SDKCacheProtection.encryptionKey(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            )
        )
        self.photosClient = try await EncryptedMemoriesClient(
            configuration: config,
            httpClient: SDKHttpClient(driveSession: driveSession, requestGovernor: requestGovernor),
            accountClient: accountClient,
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in }
        )
        DebugLog.log("bridge: EncryptedMemoriesClient created ✓")
    }

    /// Ends account-scoped work and closes every SQLite owner before sign-out removes the account
    /// directory. Actor isolation orders this behind any operation currently using the stores.
    func shutdown() async {
        if !isShutDown {
            isShutDown = true
            timelineLoadGeneration &+= 1
            shutdownGate.closeAdmission()
            timelineLoadTask?.task.cancel()
            mediaTypeReconciliationTask?.cancel()
        }
        await shutdownGate.run { [weak self] in
            await self?.performShutdown()
        }
    }

    private nonisolated func withOpenSession<T: Sendable>(
        _ operation: @escaping @Sendable (isolated DriveSDKBridge) async throws -> T
    ) async throws -> T {
        try await shutdownGate.withAdmission { [self] in
            try await operation(self)
        }
    }

    private func performShutdown() async {
        let timelineTask = timelineLoadTask?.task
        timelineLoadTask = nil
        timelineTask?.cancel()

        let reconciliationTask = mediaTypeReconciliationTask
        mediaTypeReconciliationTask = nil
        reconciliationTask?.cancel()

        _ = await timelineTask?.result
        await reconciliationTask?.value
        timelineStore?.close()
        await photosClient.shutdown()
    }

    // MARK: - PhotosRepository

    func loadTimeline() async throws -> [TimelineSection] {
        try await withOpenSession { bridge in
            try await bridge.loadTimelineSnapshotImpl().sections
        }
    }

    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        try await withOpenSession { bridge in
            try await bridge.loadTimelineSnapshotImpl()
        }
    }

    private func loadTimelineSnapshotImpl() async throws -> TimelineLoadSnapshot {
        guard !isShutDown else { throw CancellationError() }
        if let timelineLoadTask {
            return try await timelineLoadTask.task.value
        }

        timelineLoadGeneration &+= 1
        let generation = timelineLoadGeneration
        let task = Task { try await self.performTimelineLoad(generation: generation) }
        timelineLoadTask = (generation, task)
        do {
            let snapshot = try await task.value
            if timelineLoadTask?.generation == generation { timelineLoadTask = nil }
            return snapshot
        } catch {
            if timelineLoadTask?.generation == generation { timelineLoadTask = nil }
            throw error
        }
    }

    private func performTimelineLoad(generation: UInt64) async throws -> TimelineLoadSnapshot {
        do {
            try checkTimelineLoad(generation: generation)
            let root = try await resolvePhotosRoot()
            try checkTimelineLoad(generation: generation)
            // Keep the previous rows + token intact while network work is in flight. The final SQLite save
            // atomically replaces both only after the enumeration is complete and stable; cancellation, process
            // death or a transient endpoint failure therefore cannot poison the next warm launch.
            let cachedValidationToken = timelineStore?.validationToken()
            let cachedEventToken = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                from: cachedValidationToken
            )
            let historyEventProbe = try await volumeEventProbe(
                volumeID: root.volumeID,
                cursor: cachedEventToken,
                priority: .userInitiated
            )
            if historyEventProbe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
            var continuityRecoveryRequired = historyEventProbe.requiresAuthoritativeRefresh
            let startEventProbe: SDKEventCursorResult
            if continuityRecoveryRequired {
                // A continuity event is not a committable cursor. Seed a fresh current cursor, then prove a
                // complete server listing against it over the bounded quiet window below.
                startEventProbe = try await volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: nil,
                    priority: .userInitiated
                )
                guard !startEventProbe.requiresAuthoritativeRefresh else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
            } else {
                startEventProbe = historyEventProbe
            }
            let startEventToken = try eventCursor(from: startEventProbe)
            try checkTimelineLoad(generation: generation)
            DebugLog.log("timeline: photos root \(root.volumeID.prefix(8))…/\(root.nodeID.prefix(8))… - enumerating")
            let mediaTypeEvidence = timelineStore?.mediaTypeEvidence(volumeID: root.volumeID) ?? [:]
            let currentValidationToken = TimelineInventoryValidationTokenPolicy.persistedToken(
                remoteEventToken: startEventToken
            )
            let unmaterializedEvidenceNodeIDs =
                timelineStore?.unmaterializedMediaTypeEvidenceNodeIDs(
                    volumeID: root.volumeID
                ) ?? []
            var enrichmentComplete = true
            let source =
                continuityRecoveryRequired
                ? TimelineInventorySource.authoritativePhotosList
                : TimelineInventorySourcePolicy.decide(
                    cachedEventToken: cachedValidationToken,
                    currentEventToken: currentValidationToken,
                    hasPendingLocalUploads: !pendingUploadedNodeIDs.isEmpty,
                    hasUnmaterializedLocalEvidence: !unmaterializedEvidenceNodeIDs.isEmpty
                )
            let sections: [TimelineSection]
            let reconciliationItems: [PhotoItem]
            let burstMemberIDs: [String: [String]]
            let burstEntries: [PhotosListEntry]?
            var authoritativeInventoryFingerprint: String?

            switch source {
            case .authoritativePhotosList:
                let expectedRemoteNodeIDs: Set<String>?
                if continuityRecoveryRequired {
                    expectedRemoteNodeIDs = nil
                } else {
                    expectedRemoteNodeIDs = try await remotelyChangedActivePhotoNodeIDs(
                        since: cachedEventToken,
                        currentEventToken: startEventToken,
                        volumeID: root.volumeID
                    )
                    if expectedRemoteNodeIDs == nil {
                        continuityRecoveryRequired = true
                    }
                }
                let entries: [PhotosListEntry]
                if continuityRecoveryRequired {
                    entries = try await continuityRecovery.fetchInventory(
                        cursor: startEventToken,
                        now: .now
                    ) { [driveSession] in
                        try await driveSession.fetchPhotosList(volumeID: root.volumeID)
                    }
                } else {
                    entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID)
                }
                authoritativeInventoryFingerprint = TimelineContinuityInventoryFingerprint.make(entries: entries)
                let representedNodeIDs = Set(entries.map(\.linkID)).union(
                    entries.flatMap { $0.relatedPhotos.map(\.linkID) }
                )
                if let expectedRemoteNodeIDs {
                    let missing = expectedRemoteNodeIDs.subtracting(representedNodeIDs)
                    guard missing.isEmpty else {
                        throw TimelineInventoryVisibilityError.remoteChangesNotVisible(missing.count)
                    }
                }
                pendingUploadedNodeIDs.subtract(representedNodeIDs)
                let unresolvedEvidenceNodeIDs = unmaterializedEvidenceNodeIDs.subtracting(representedNodeIDs)
                if !unresolvedEvidenceNodeIDs.isEmpty {
                    pendingUploadedNodeIDs.formUnion(
                        try await activeNodeIDs(unresolvedEvidenceNodeIDs)
                    )
                }
                burstMemberIDs = Self.burstMemberLookup(from: entries)
                burstEntries = entries
                sections = Self.group(
                    entries,
                    volumeID: root.volumeID,
                    mediaTypeOverrides: mediaTypeEvidence,
                    sectionID: "all"
                )
                reconciliationItems = sections.flatMap(\.items)
                DebugLog.log("timeline: authoritative photos listing returned \(reconciliationItems.count) items ✓")

            case .sdkCache:
                let collector = SDKEnumerationCollector<PhotoTimelineItem>()
                let items = try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                    try await photosClient.enumerateTimeline(
                        in: root,
                        cancellationToken: cancellationToken,
                        onPhotoEnumerated: { result in collector.receive(result) }
                    )
                    return try collector.collected()
                } cancel: { [photosClient] cancellationToken in
                    try? await photosClient.cancelEnumerateTimeline(cancellationToken: cancellationToken)
                }
                try checkTimelineLoad(generation: generation)
                DebugLog.log("timeline: SDK cache enumerated \(items.count) items ✓")
                let enrichment = await TimelineTagEnrichmentLoader.load {
                    [driveSession, volumeID = root.volumeID] tag, onPage in
                    try await driveSession.forEachPhotosListPage(
                        volumeID: volumeID,
                        tag: tag.rawValue,
                        onPage: onPage
                    )
                }
                try checkTimelineLoad(generation: generation)
                if enrichment.wasCancelled { throw CancellationError() }

                let videoNodeIDs: Set<String>
                if let videos = enrichment.videos.value {
                    videoNodeIDs = videos
                } else {
                    videoNodeIDs = []
                    enrichmentComplete = false
                    if let error = enrichment.videos.errorDescription {
                        DebugLog.log("timeline: video tag enrichment skipped - \(error)")
                    }
                }
                let livePhotoVideoIDs: [String: String]
                if let lives = enrichment.livePhotos.value {
                    livePhotoVideoIDs = lives
                } else {
                    livePhotoVideoIDs = [:]
                    enrichmentComplete = false
                    if let error = enrichment.livePhotos.errorDescription {
                        DebugLog.log("timeline: live-photo tag enrichment skipped - \(error)")
                    }
                }
                if let bursts = enrichment.bursts.value {
                    burstMemberIDs = Self.burstMemberLookup(from: bursts)
                    burstEntries = bursts
                } else {
                    burstMemberIDs = [:]
                    burstEntries = nil
                    enrichmentComplete = false
                    if let error = enrichment.bursts.errorDescription {
                        DebugLog.log("timeline: burst tag enrichment skipped - \(error)")
                    }
                }
                sections = Self.group(
                    items,
                    videoNodeIDs: videoNodeIDs,
                    mediaTypeOverrides: mediaTypeEvidence,
                    livePhotoVideoIDs: livePhotoVideoIDs,
                    burstMemberIDs: burstMemberIDs
                )
                reconciliationItems = sections.flatMap(\.items)
            }
            try checkTimelineLoad(generation: generation)
            guard pendingUploadedNodeIDs.isEmpty else {
                throw TimelineInventoryVisibilityError.pendingUploadsNotVisible(pendingUploadedNodeIDs.count)
            }
            var continuityRecoveryQualified = false
            let endEventToken: String
            if continuityRecoveryRequired {
                guard let authoritativeInventoryFingerprint else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
                let qualification = try await continuityRecovery.qualify(
                    startCursor: startEventToken,
                    inventoryFingerprint: authoritativeInventoryFingerprint,
                    now: .now
                ) { [self] in
                    let probe = try await volumeEventProbe(
                        volumeID: root.volumeID,
                        cursor: startEventToken,
                        priority: .userInitiated
                    )
                    return TimelineContinuityPostInventoryProbe(
                        cursor: try eventCursor(from: probe),
                        requiresAuthoritativeRefresh: probe.requiresAuthoritativeRefresh
                    )
                }
                endEventToken = qualification.endCursor
                continuityRecoveryQualified = qualification.recoveryQualified
            } else {
                let endEventProbe = try await volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: startEventToken,
                    priority: .userInitiated
                )
                endEventToken = try eventCursor(from: endEventProbe)
                // A new continuity loss during enumeration starts a fresh proof window on the next load. Do not
                // return a successful memory-only snapshot because the monitor would consume its probed token.
                guard !endEventProbe.requiresAuthoritativeRefresh else {
                    continuityRecovery.reset()
                    throw TimelineContinuityRecoveryPendingError()
                }
                continuityRecovery.reset()
            }
            try checkTimelineLoad(generation: generation)
            let commit = TimelineLoadCommitPolicy.decide(
                startEventToken: startEventToken,
                endEventToken: endEventToken,
                enrichmentComplete: enrichmentComplete
            )
            if continuityRecoveryQualified, commit.persistedValidationToken == nil {
                throw TimelineContinuityRecoveryPendingError()
            }
            if let persistedToken = commit.persistedValidationToken {
                try checkTimelineLoad(generation: generation)
                let cacheSaved = try continuityRecovery.persist(
                    recoveryQualified: continuityRecoveryQualified
                ) {
                    writeTimelineCache(
                        sections,
                        validationToken: TimelineInventoryValidationTokenPolicy.persistedToken(
                            remoteEventToken: persistedToken
                        )
                    )
                }
                if source == .authoritativePhotosList, cacheSaved,
                    timelineStore?.pruneUnmaterializedMediaTypeEvidence(volumeID: root.volumeID) == false
                {
                    DebugLog.log("timeline: stale media-type evidence cleanup failed")
                }
            } else {
                DebugLog.log("timeline: usable inventory kept in memory; incomplete enrichment will retry")
            }
            if let burstEntries {
                burstCatalogEntries = burstEntries
                burstCatalogLookup = burstMemberIDs
            }
            scheduleMediaTypeReconciliation(
                items: reconciliationItems,
                alreadyClassifiedNodeIDs: Set(mediaTypeEvidence.keys)
            )
            return TimelineLoadSnapshot(
                sections: sections,
                validationToken: monitorToken(remoteToken: commit.monitorBaseline)
            )
        } catch is TimelineContinuityRecoveryPendingError {
            DebugLog.log("timeline: continuity recovery is still converging")
            throw TimelineContinuityRecoveryPendingError()
        } catch {
            // A transport error, cancellation, or other invalid observation breaks the quiet window. A future
            // recovery attempt must collect all three qualified full inventories again.
            continuityRecovery.reset()
            DebugLog.log("timeline: FAILED - \(error)")
            throw error
        }
    }

    private func checkTimelineLoad(generation: UInt64) throws {
        try Task.checkCancellation()
        guard !isShutDown, timelineLoadGeneration == generation else {
            throw CancellationError()
        }
    }

    /// Last-known timeline from disk, for instant startup (no spinner). Reads from SQLite - then
    /// `loadTimeline()` refreshes in the background.
    func cachedTimeline() -> [TimelineSection]? {
        guard !isShutDown else { return nil }
        return cachedTimelineSnapshot()?.sections
    }

    func cachedTimelineSnapshot() -> CachedTimelineSnapshot? {
        guard !isShutDown else { return nil }
        guard let store = timelineStore else { return nil }
        let items = store.load()
        let validationToken = store.validationToken()
        guard !items.isEmpty || validationToken != nil else { return nil }
        DebugLog.log("timeline: served \(items.count) items from SQLite cache ✓")
        let sections =
            items.isEmpty
            ? []
            : [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
        return CachedTimelineSnapshot(sections: sections, validationToken: validationToken)
    }

    func cachedTimelineValidationToken() -> String? {
        guard !isShutDown else { return nil }
        return timelineStore?.validationToken()
    }

    /// One bounded SDK event probe. A changed cursor tells the shared foreground monitor to perform
    /// an authoritative timeline refresh; unchanged polls never enumerate or decrypt the library.
    func libraryChangeToken() async throws -> String {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                from: bridge.timelineStore?.validationToken()
            )
            let probe = try await bridge.volumeEventProbe(
                volumeID: root.volumeID,
                cursor: cursor,
                priority: .background
            )
            if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
            let remote: String
            if probe.requiresAuthoritativeRefresh {
                let seed = try await bridge.volumeEventProbe(
                    volumeID: root.volumeID,
                    cursor: nil,
                    priority: .background
                )
                guard !seed.requiresAuthoritativeRefresh else {
                    throw TimelineContinuityRecoveryPendingError()
                }
                remote = try bridge.eventCursor(from: seed)
            } else {
                remote = try bridge.eventCursor(from: probe)
            }
            return bridge.monitorToken(remoteToken: remote)
        }
    }

    func launchValidationToken() async throws -> String {
        try await withOpenSession { bridge in
            try await bridge.launchValidationTokenImpl()
        }
    }

    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String {
        try await withOpenSession { bridge in
            if let volumeID = snapshot.sections.lazy.flatMap(\.items).first?.uid.volumeID {
                let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
                    from: snapshot.validationToken
                )
                let probe = try await bridge.volumeEventProbe(
                    volumeID: volumeID,
                    cursor: cursor,
                    priority: .userInitiated
                )
                if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
                guard !probe.requiresAuthoritativeRefresh else {
                    throw TimelineContinuityRecoveryPendingError()
                }
                let remoteToken = try bridge.eventCursor(from: probe)
                return TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: remoteToken)
            }
            return try await bridge.launchValidationTokenImpl()
        }
    }

    private func launchValidationTokenImpl() async throws -> String {
        let root = try await resolvePhotosRoot()
        let cursor = TimelineInventoryValidationTokenPolicy.remoteEventToken(
            from: timelineStore?.validationToken()
        )
        let probe = try await volumeEventProbe(
            volumeID: root.volumeID,
            cursor: cursor,
            priority: .userInitiated
        )
        if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
        guard !probe.requiresAuthoritativeRefresh else {
            throw TimelineContinuityRecoveryPendingError()
        }
        let remoteToken = try eventCursor(from: probe)
        return TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: remoteToken)
    }

    private func volumeEventProbe(
        volumeID: String,
        cursor: String?,
        priority: ProtonRequestPriority
    ) async throws -> SDKEventCursorResult {
        let accumulator = SDKEventCursorAccumulator(cursor: cursor)
        return try await ProtonRequestContext.$priority.withValue(priority) {
            try await SDKCancellableOperation.run { [photosClient] cancellationToken in
                try await photosClient.enumerateEvents(
                    treeEventScopeId: volumeID,
                    cursor: cursor,
                    cancellationToken: cancellationToken,
                    onDriveEventEnumerated: { result in accumulator.receive(result) }
                )
                return try accumulator.result()
            } cancel: { [photosClient] cancellationToken in
                try? await photosClient.cancelEnumerateEvents(cancellationToken: cancellationToken)
            }
        }
    }

    private func eventCursor(from probe: SDKEventCursorResult) throws -> String {
        if probe.scopeAccessLost { throw DriveEventScopeAccessLostError() }
        guard let cursor = probe.cursor else { throw SDKEventCursorError.missingCursor }
        return cursor
    }

    private func monitorToken(remoteToken: String) -> String {
        "\(remoteToken)#media=\(timelineStore?.mediaTypeEvidenceRevision() ?? 0)"
    }

    /// Returns active photo-volume file IDs represented by events after the cached inventory token. The Photos
    /// listing can lag the volume event feed; callers must not commit the new token until these IDs are visible.
    /// A server-requested full event refresh returns nil because no bounded event evidence remains to validate.
    private func remotelyChangedActivePhotoNodeIDs(
        since cachedEventToken: String?,
        currentEventToken: String,
        volumeID: String
    ) async throws -> Set<String>? {
        guard let cachedEventToken,
            !cachedEventToken.isEmpty,
            cachedEventToken != currentEventToken,
            let photosShareID
        else { return [] }

        var eventID = cachedEventToken
        var activeNodeIDs = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await driveSession.fetchVolumeEvents(volumeID: volumeID, since: eventID)
            if page.requiresRefresh { return nil }
            TimelineRemoteEventVisibilityPolicy.apply(
                page.events,
                photosShareID: photosShareID,
                to: &activeNodeIDs
            )
            eventID = page.eventID
            if !page.hasMore { return activeNodeIDs }
        }
    }

    /// Starts at the newest items so recently uploaded videos repair first, then checkpoints every
    /// successful metadata batch. `fetch_metadata` supports 150 links per call, so even a 35k
    /// library is a few hundred bounded requests rather than one request per asset.
    private func scheduleMediaTypeReconciliation(
        items: [PhotoItem],
        alreadyClassifiedNodeIDs: Set<String>
    ) {
        guard timelineStore != nil, mediaTypeReconciliationTask == nil else { return }
        let unknown = items.reversed().compactMap { item -> PhotoUID? in
            let nodeID = item.uid.nodeID
            guard !alreadyClassifiedNodeIDs.contains(nodeID) else { return nil }
            return item.uid
        }
        guard !unknown.isEmpty else { return }
        mediaTypeReconciliationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.reconcileMediaTypes(unknown)
        }
    }

    private func reconcileMediaTypes(_ unknown: [PhotoUID]) async {
        var changed = false
        defer {
            if changed, timelineStore?.publishMediaTypeEvidenceRevision() == false {
                DebugLog.log("timeline: could not publish reconciled media-type revision")
            }
            mediaTypeReconciliationTask = nil
        }
        do {
            let context = try await photosShareContext()
            var resolved = 0
            let batchSize = UploadDedupePipeline.protonDuplicateBatchSize
            for start in stride(from: 0, to: unknown.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(unknown[start..<min(start + batchSize, unknown.count)])
                let links = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                    try await driveSession.fetchPhotoLinksMetadata(
                        shareID: context.shareID,
                        linkIDs: batch.map(\.nodeID)
                    )
                }
                let volumeID = batch[0].volumeID
                let evidence = Dictionary(
                    uniqueKeysWithValues: links.compactMap { link -> (PhotoUID, String)? in
                        guard let nodeID = link.linkID, let mimeType = link.mimeType else { return nil }
                        return (PhotoUID(volumeID: volumeID, nodeID: nodeID), mimeType)
                    }
                )
                let result = timelineStore?.recordMediaTypeEvidence(evidence, publishRevision: false)
                guard result?.succeeded != false else {
                    throw NSError(
                        domain: "EncryptedMemories.MediaTypeReconciliation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "media type checkpoint could not be saved"]
                    )
                }
                changed = changed || (result?.changedRows ?? 0) > 0
                resolved += evidence.count
            }
            DebugLog.log("timeline: media-type reconciliation resolved \(resolved)/\(unknown.count) links ✓")
        } catch is CancellationError {
            DebugLog.log("timeline: media-type reconciliation cancelled; persisted batches will resume")
        } catch {
            DebugLog.log("timeline: media-type reconciliation paused after a recoverable failure - \(error)")
        }
    }

    @discardableResult
    private func writeTimelineCache(_ sections: [TimelineSection], validationToken: String?) -> Bool {
        guard let store = timelineStore else { return false }
        let result = store.save(sections.flatMap(\.items), validationToken: validationToken)
        if !result.succeeded {
            DebugLog.log("timeline: cache save failed - validation token not published")
        } else if result.skippedUnchanged {
            DebugLog.log("timeline: cache unchanged - save skipped (digest match)")
        } else {
            DebugLog.log(
                "timeline: cache saved gen=\(result.generation) upserts=\(result.upsertedRows) swept=\(result.sweptRows) ok=\(result.succeeded)"
            )
        }
        return result.succeeded
    }

    /// Evidence-only active links are completed uploads still converging into the Photos listing.
    /// Deleted links and Live Photo resources already represented by their main item may be pruned.
    private func activeNodeIDs(_ nodeIDs: Set<String>) async throws -> Set<String> {
        let context = try await photosShareContext()
        let ordered = nodeIDs.sorted()
        var active = Set<String>()
        let batchSize = UploadDedupePipeline.protonDuplicateBatchSize
        for start in stride(from: 0, to: ordered.count, by: batchSize) {
            let batch = Array(ordered[start..<min(start + batchSize, ordered.count)])
            let links = try await driveSession.fetchPhotoLinksMetadata(
                shareID: context.shareID,
                linkIDs: batch
            )
            active.formUnion(
                links.compactMap { link in
                    guard let linkID = link.linkID, link.state == nil || link.state == 1 else { return nil }
                    return linkID
                })
        }
        return active
    }

    // MARK: - LibraryStatsProvider

    /// Rows persisted in the local SQLite timeline store - surfaced as "metadata rows" in Settings.
    func metadataRowCount() async -> Int {
        (try? await withOpenSession { bridge in
            bridge.timelineStore?.count() ?? 0
        }) ?? 0
    }

    // MARK: - ThumbnailProvider

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.singleThumbnail(uid, type: .thumbnail)
        }
    }

    // MARK: - ThumbnailBatchLoader

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        do {
            return try await withOpenSession { bridge in
                await bridge.loadThumbnailsImpl(
                    for: uids,
                    priority: .nearViewportScrollAhead,
                    onLoaded: onLoaded
                )
            }
        } catch {
            return ThumbnailBatchLoadResult(batchError: "cancelled")
        }
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        do {
            return try await withOpenSession { bridge in
                await bridge.loadThumbnailsImpl(for: uids, priority: priority, onLoaded: onLoaded)
            }
        } catch {
            return ThumbnailBatchLoadResult(batchError: "cancelled")
        }
    }

    private func loadThumbnailsImpl(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let sdkUids = uids.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let failures = BatchFailureBox()
        let isInteractive = priority == .visibleNow
        let priorityScope = await requestGovernor.beginPriorityScope(
            priority.requestPriority,
            promoting: [.api, .storageDownload],
            suspending: isInteractive ? [.storageUpload] : []
        )
        do {
            try await ProtonRequestContext.$priority.withValue(priority.requestPriority) {
                try await photosClient.downloadThumbnails(
                    photoUids: sdkUids,
                    type: .thumbnail,
                    cancellationToken: UUID(),
                    onThumbnailDownloaded: { result in
                        switch result {
                        case .success(let item?):
                            let uid = PhotoUID(volumeID: item.fileUid.volumeID, nodeID: item.fileUid.nodeID)
                            switch item.result {
                            case .success(let data):
                                onLoaded(uid, data)
                            case .failure(let error):
                                failures.recordItem(uid, reason: error.localizedDescription)
                            }
                        case .success(nil):
                            break
                        case .failure(let error):
                            failures.recordStream(error.localizedDescription)
                        }
                    }
                )
            }
        } catch {
            failures.recordStream((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        await requestGovernor.endPriorityScope(priorityScope)
        let result = failures.result
        if result != .delivered {
            let sample = result.itemErrors.first.map { "\($0.key.nodeID.prefix(8))…: \($0.value)" } ?? "-"
            DebugLog.log(
                "[ThumbBatch] n=\(uids.count) itemErrors=\(result.itemErrors.count) (\(sample)) batchError=\(result.batchError ?? "-")"
            )
        }
        return result
    }

    // MARK: - FullMediaProvider

    func preview(for uid: PhotoUID) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.singleThumbnail(uid, type: .preview)
        }
    }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await withOpenSession { bridge in
            try await bridge.originalDataImpl(for: uid, onProgress: onProgress)
        }
    }

    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withOpenSession { bridge in
            try await bridge.streamOriginalBytesImpl(for: uid, onChunk: onChunk, onProgress: onProgress)
        }
    }

    private func streamOriginalBytesImpl(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            try await ProtonRequestContext.$priority.withValue(.immediate) {
                let source = try await fileSource()
                try await source.streamOriginalBytes(uid: uid, onChunk: onChunk, onProgress: onProgress)
            }
            await requestGovernor.endPriorityScope(priorityScope)
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
    }

    private func originalDataImpl(
        for uid: PhotoUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            let result = try await ProtonRequestContext.$priority.withValue(.immediate) {
                let source = try await fileSource()
                return try await source.originalData(uid: uid, onProgress: onProgress)
            }
            await requestGovernor.endPriorityScope(priorityScope)
            return result
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
    }

    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withOpenSession { bridge in
            try await bridge.writeOriginalImpl(for: uid, to: destination, onProgress: onProgress)
        }
    }

    private func writeOriginalImpl(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }

        let token = UUID()
        let sdkUID = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            let operation = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await photosClient.downloadOperation(
                    photoUid: sdkUID,
                    destinationUrl: partial,
                    cancellationToken: token,
                    progressCallback: { onProgress($0.fractionCompleted) }
                )
            }
            let verificationIssue = try await withTaskCancellationHandler {
                try await operation.awaitDownloadWithResilience(
                    operationalResilience: BasicOperationalResilience.default,
                    onRetriableErrorReceived: { error in
                        DebugLog.log("original file transfer retry: \(error.localizedDescription)")
                    }
                )
            } onCancel: {
                Task { try? await operation.cancel() }
            }
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            onProgress(1)
            if let verificationIssue {
                DebugLog.log(
                    "original file completed with verification warning: \(verificationIssue.localizedDescription)")
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        await requestGovernor.endPriorityScope(priorityScope)
    }

    private func singleThumbnail(_ uid: PhotoUID, type: ThumbnailData.ThumbnailType) async throws -> Data {
        let sdkUid = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let box = DataBox()
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        do {
            try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await photosClient.downloadThumbnails(
                    photoUids: [sdkUid],
                    type: type,
                    cancellationToken: UUID(),
                    onThumbnailDownloaded: { result in
                        if case .success(let item?) = result, case .success(let data) = item.result {
                            box.set(data)
                        }
                    }
                )
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
        await requestGovernor.endPriorityScope(priorityScope)
        guard let data = box.value else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    // MARK: - Photos root resolution

    private func resolvePhotosRoot() async throws -> SDKNodeUid {
        if let photosRoot { return photosRoot }
        let context = try await photosVolumeBootstrap.resolve()
        let root = SDKNodeUid(volumeID: context.volumeID, nodeID: context.rootLinkID)
        photosRoot = root
        photosShareID = context.shareID
        return root
    }

    /// The photos share context for the dedupe service - same discovery + cache as every other
    /// photos feature (`resolvePhotosRoot`).
    func photosShareContext() async throws -> PhotosShareContext {
        try await withOpenSession { bridge in
            try await bridge.photosShareContextImpl()
        }
    }

    private func photosShareContextImpl() async throws -> PhotosShareContext {
        let root = try await resolvePhotosRoot()
        guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
        return PhotosShareContext(volumeID: root.volumeID, shareID: shareID, rootLinkID: root.nodeID)
    }

    /// Lazily builds (and caches) the streaming/metadata source once the photos share id is known.
    private func fileSource() async throws -> PhotoVideoStreamSource {
        _ = try await resolvePhotosRoot()  // ensures photosShareID is populated
        guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
        if let streamSource { return streamSource }
        let source = PhotoVideoStreamSource(session: driveSession, crypto: crypto, shareID: shareID)
        streamSource = source
        return source
    }

    // MARK: - PhotoLibraryProvider

    nonisolated func makeAlbumCatalogBackend() -> SDKAlbumCatalogBackend {
        SDKAlbumCatalogBackend(client: photosClient, admission: shutdownGate)
    }

    /// Sets an album's cover to an already-uploaded photo (direct REST; SDK 0.25.0 has no album-write API).
    /// The photo's `nodeID` is its Drive link id.
    func setAlbumCover(albumID: String, photoUID: PhotoUID) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.setAlbumCover(
                volumeID: root.volumeID,
                albumLinkID: albumID,
                coverLinkID: photoUID.nodeID
            )
        }
    }

    func deleteAlbum(albumID: String) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.deleteAlbum(volumeID: root.volumeID, albumLinkID: albumID)
        }
    }

    func removePhotos(_ photoUIDs: [PhotoUID], fromAlbum albumID: String) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.removeFromAlbum(
                volumeID: root.volumeID,
                albumLinkID: albumID,
                linkIDs: photoUIDs.map(\.nodeID)
            )
        }
    }

    /// Refreshes the lightweight account snapshot used by Settings (email and Drive quota). The existing
    /// account-data request also updates the encrypted offline cache; it does not rebuild the signed-in client.
    func refreshAccountInfo() async throws {
        try await withOpenSession { bridge in
            _ = try await bridge.driveSession.fetchAccountData()
        }
    }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        try await withOpenSession { bridge in
            try await bridge.timelineImpl(filter: filter)
        }
    }

    private func timelineImpl(filter: PhotoFilter) async throws -> [TimelineSection] {
        switch filter {
        case .all:
            return try await loadTimelineSnapshotImpl().sections
        case .tag(let tag):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: tag.rawValue)
            return Self.group(
                entries,
                volumeID: root.volumeID,
                mediaTypeOverrides: timelineStore?.mediaTypeEvidence(volumeID: root.volumeID) ?? [:]
            )
        case .album(let id, _):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchAlbumPhotos(volumeID: root.volumeID, albumLinkID: id)
            return Self.group(
                entries,
                volumeID: root.volumeID,
                mediaTypeOverrides: timelineStore?.mediaTypeEvidence(volumeID: root.volumeID) ?? [:]
            )
        case .trash:
            let root = try await resolvePhotosRoot()
            let links = try await driveSession.listTrash(volumeID: root.volumeID)
                .filter { $0.type != 1 && $0.type != 3 }  // drop folders + albums; keep files/unknown
                .filter { $0.mainPhotoLinkID == nil }  // hide Live-Photo paired videos, like the timeline
            let photos =
                links
                .compactMap { l -> PhotoItem? in
                    guard let id = l.linkID else { return nil }
                    let isVideo = l.mimeType?.hasPrefix("video/") == true
                    return PhotoItem(
                        uid: PhotoUID(volumeID: root.volumeID, nodeID: id),
                        captureTime: Date(timeIntervalSince1970: l.captureTime),
                        mediaType: isVideo ? "video/quicktime" : "image/jpeg",
                        tags: isVideo ? [.videos] : [])
                }
                .sorted(by: TimelineOrder.areInIncreasingOrder)
            return [
                TimelineSection(id: "trash", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)
            ]
        case .map:
            return []  // the Map route renders the map, not a timeline
        }
    }

    // MARK: - FavoritesProvider

    func favoriteUIDs() async throws -> Set<PhotoUID> {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            let entries = try await bridge.driveSession.fetchPhotosList(
                volumeID: root.volumeID,
                tag: LibraryPhotoTag.favorites.rawValue
            )
            return Set(entries.map { PhotoUID(volumeID: root.volumeID, nodeID: $0.linkID) })
        }
    }

    func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws {
        try await withOpenSession { bridge in
            try await SDKFavoriteWriter(client: bridge.photosClient).setFavorites(uids, favorite: favorite)
        }
    }

    // MARK: - TrashProvider

    func trash(_ uids: [PhotoUID]) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.trash(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
            // Debug-gated end-to-end verification: the moved links must actually surface in the volume trash
            // listing (this is the seam that silently broke before - trash "succeeded" but Recently Deleted
            // stayed empty). Costs one extra listing round-trip, only when the debug log is on.
            if DebugLog.isEnabled {
                let trashed = Set(
                    (try? await bridge.driveSession.listTrash(volumeID: root.volumeID))?.compactMap(\.linkID) ?? []
                )
                let missing = uids.map(\.nodeID).filter { !trashed.contains($0) }
                DebugLog.log(
                    "trash-verify: \(uids.count - missing.count)/\(uids.count) moved links visible in trash listing"
                        + (missing.isEmpty
                            ? "" : " MISSING=\(missing.map { $0.prefix(8) + "…" }.joined(separator: ","))"))
            }
        }
    }

    func restore(_ uids: [PhotoUID]) async throws {
        try await withOpenSession { bridge in
            let root = try await bridge.resolvePhotosRoot()
            try await bridge.driveSession.restore(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
        }
    }

    func emptyTrash() async throws {
        try await withOpenSession { bridge in
            _ = try await bridge.resolvePhotosRoot()
            try await SDKCancellableOperation.run { [photosClient = bridge.photosClient] cancellationToken in
                try await photosClient.emptyTrash(cancellationToken: cancellationToken)
            } cancel: { [photosClient = bridge.photosClient] cancellationToken in
                try? await photosClient.cancelEmptyTrash(cancellationToken: cancellationToken)
            }
        }
    }

    /// Builds timeline sections from direct-listing entries (tag filters + album contents).
    private static func group(
        _ entries: [PhotosListEntry],
        volumeID: String,
        mediaTypeOverrides: [String: String] = [:],
        sectionID: String = "filtered"
    ) -> [TimelineSection] {
        let burstMemberIDs = burstMemberLookup(from: entries)
        let photos =
            entries
            .map { e -> PhotoItem in
                photoItem(
                    from: e,
                    volumeID: volumeID,
                    mediaTypeOverride: mediaTypeOverrides[e.linkID],
                    burstMemberIDs: burstMemberIDs[e.linkID] ?? []
                )
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        return [
            TimelineSection(id: sectionID, date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)
        ]
    }

    // MARK: - PhotoMetadataProvider

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        try await withOpenSession { bridge in
            try await bridge.metadataImpl(for: uid)
        }
    }

    private func metadataImpl(for uid: PhotoUID) async throws -> PhotoMetadata {
        let source = try await fileSource()
        let raw = try await source.fileMetadata(linkID: uid.nodeID)
        if let mimeType = raw.mimeType {
            let result = timelineStore?.recordMediaTypeEvidence([uid: mimeType])
            if result?.succeeded == false {
                DebugLog.log("timeline: could not persist media type resolved by viewer")
            }
        }
        let xa = raw.xattr
        let duration = xa?.media?.duration
        if let duration {
            let result = timelineStore?.updateDurations([uid: duration])
            if result?.succeeded == false {
                DebugLog.log("timeline: could not persist video duration resolved from metadata")
            }
        }
        var mod: Date?
        if let s = xa?.common?.modificationTime {
            mod = ISO8601DateFormatter().date(from: s)
        }
        return PhotoMetadata(
            filename: raw.filename,
            mimeType: raw.mimeType,
            fileSize: raw.size ?? xa?.common?.size,
            pixelWidth: xa?.media?.width,
            pixelHeight: xa?.media?.height,
            device: xa?.camera?.device,
            durationSeconds: duration,
            modificationTime: mod,
            latitude: xa?.location?.latitude,
            longitude: xa?.location?.longitude
        )
    }

    // MARK: - BurstGroupProvider

    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
        try await withOpenSession { bridge in
            try await bridge.burstGroupImpl(containing: uid)
        }
    }

    private func burstGroupImpl(containing uid: PhotoUID) async throws -> [PhotoItem] {
        let root = try await resolvePhotosRoot()
        let burstEntries: [PhotosListEntry]
        let lookup: [String: [String]]
        if let cached = burstCatalogEntries {
            // The cached tagged listing is complete. A missing UID is a confirmed non-member, not a reason to
            // enumerate the same potentially large bursts listing again.
            burstEntries = cached
            lookup = burstCatalogLookup
        } else {
            let fetched = try await driveSession.fetchPhotosList(
                volumeID: root.volumeID, tag: LibraryPhotoTag.bursts.rawValue)
            let fetchedLookup = Self.burstMemberLookup(from: fetched)
            burstCatalogEntries = fetched
            burstCatalogLookup = fetchedLookup
            burstEntries = fetched
            lookup = fetchedLookup
        }
        guard let memberIDs = lookup[uid.nodeID], memberIDs.count > 1 else { return [] }

        let entriesByID = Dictionary(burstEntries.map { ($0.linkID, $0) }, uniquingKeysWith: { first, _ in first })
        let anchorEntry =
            entriesByID[uid.nodeID]
            ?? burstEntries.first { entry in
                memberIDs.contains(entry.linkID)
            }
        let anchorTime = anchorEntry.map { Date(timeIntervalSince1970: $0.captureTime) } ?? .distantPast

        return memberIDs.enumerated().map { offset, id in
            if let entry = entriesByID[id] {
                return Self.photoItem(from: entry, volumeID: root.volumeID, burstMemberIDs: memberIDs)
            }
            return Self.syntheticBurstMember(
                id: id,
                volumeID: root.volumeID,
                memberIDs: memberIDs,
                anchorTime: anchorTime,
                offset: offset
            )
        }
    }

    // MARK: - VideoStreamProvider

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        try await withOpenSession { bridge in
            try await bridge.makeStreamingAssetImpl(for: uid)
        }
    }

    private func makeStreamingAssetImpl(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        let priorityScope = await requestGovernor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        let source: PhotoVideoStreamSource
        do {
            source = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await fileSource()
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }

        // Throws `.notAVideo` cheaply for images, so the viewer falls back to its image path.
        let prepared: PreparedVideo
        do {
            prepared = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await source.prepare(uid: uid)
            }
        } catch {
            await requestGovernor.endPriorityScope(priorityScope)
            throw error
        }
        let loader = ProtonVideoResourceLoader(
            prepared: prepared,
            source: source,
            crypto: crypto,
            admission: shutdownGate
        )
        // Unique per-item URL so AVFoundation never reuses a cached asset/loader across videos.
        let host = uid.nodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "stream"
        let asset = AVURLAsset(url: URL(string: "protonvideo://\(host)")!)
        let queue = DispatchQueue(label: "me.proton.photos.video-loader")
        asset.resourceLoader.setDelegate(loader, queue: queue)
        await requestGovernor.endPriorityScope(priorityScope)
        return StreamingVideoAsset(asset: asset, retaining: loader)
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        try await withOpenSession { bridge in
            let priorityScope = await bridge.requestGovernor.beginPriorityScope(
                .immediate,
                promoting: [.api, .storageDownload],
                suspending: [.storageUpload]
            )
            do {
                try await ProtonRequestContext.$priority.withValue(.immediate) {
                    let source = try await bridge.fileSource()
                    try await source.prefetchEncrypted(uid: uid)
                }
                await bridge.requestGovernor.endPriorityScope(priorityScope)
            } catch {
                await bridge.requestGovernor.endPriorityScope(priorityScope)
                throw error
            }
        }
    }

    // MARK: - Mapping

    private static func group(
        _ items: [PhotoTimelineItem], videoNodeIDs: Set<String> = [],
        mediaTypeOverrides: [String: String] = [:],
        livePhotoVideoIDs: [String: String] = [:],
        burstMemberIDs: [String: [String]] = [:]
    ) -> [TimelineSection] {
        let photos =
            items
            .map { item -> PhotoItem in
                let nodeID = item.nodeUid.nodeID
                let mediaType =
                    mediaTypeOverrides[nodeID]
                    ?? (videoNodeIDs.contains(nodeID) ? "video/quicktime" : "image/jpeg")
                let isVideo = mediaType.hasPrefix("video/")
                let relatedVideo = livePhotoVideoIDs[nodeID]  // a live photo's paired video link, if any
                let burstMembers = burstMemberIDs[nodeID] ?? []
                var tags: Set<LibraryPhotoTag> = []
                if isVideo { tags.insert(.videos) }
                if relatedVideo != nil { tags.insert(.motionPhotos) }
                if burstMembers.count > 1 { tags.insert(.bursts) }
                return PhotoItem(
                    uid: PhotoUID(volumeID: item.nodeUid.volumeID, nodeID: nodeID),
                    captureTime: Date(timeIntervalSince1970: item.captureTime),
                    mediaType: mediaType,
                    isLivePhoto: relatedVideo != nil,
                    relatedVideoID: relatedVideo,
                    tags: tags,
                    burstMemberIDs: burstMembers)
            }
            // Ascending order places the oldest item at the top and the newest at the bottom.
            // The grid opens scrolled to the bottom so the newest photos are shown first. The
            // comparator is the canonical (t, vol, node) timeline order, matching the DB index, so
            // equal-second captures keep a stable position across refreshes and relaunches.
            .sorted(by: TimelineOrder.areInIncreasingOrder)

        // one continuous section - no per-day/month breaks. Apple's "All Photos" is a single
        // uninterrupted justified run, which also keeps pinch-zoom smooth (no divider lines to
        // disturb the re-justify) and makes thumbnail sizing consistent across the whole library.
        return [TimelineSection(id: "all", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)]
    }

    private static func tags(from rawValues: [Int]) -> Set<LibraryPhotoTag> {
        Set(rawValues.compactMap(LibraryPhotoTag.init(rawValue:)))
    }

    private static func photoItem(
        from entry: PhotosListEntry,
        volumeID: String,
        mediaTypeOverride: String? = nil,
        burstMemberIDs: [String] = []
    ) -> PhotoItem {
        let mediaType =
            mediaTypeOverride
            ?? (entry.tags.contains(LibraryPhotoTag.videos.rawValue) ? "video/quicktime" : "image/jpeg")
        let isVideo = mediaType.hasPrefix("video/")
        var tags = Self.tags(from: entry.tags)
        tags.remove(.videos)
        if isVideo { tags.insert(.videos) }
        if burstMemberIDs.count > 1 { tags.insert(.bursts) }
        return PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: entry.linkID),
            captureTime: Date(timeIntervalSince1970: entry.captureTime),
            mediaType: mediaType,
            isLivePhoto: entry.isLivePhoto,
            relatedVideoID: entry.isLivePhoto ? entry.relatedVideoLinkID : nil,
            tags: tags,
            burstMemberIDs: burstMemberIDs
        )
    }

    private static func syntheticBurstMember(
        id: String,
        volumeID: String,
        memberIDs: [String],
        anchorTime: Date,
        offset: Int
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: id),
            captureTime: anchorTime.addingTimeInterval(Double(offset) * 0.001),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: memberIDs
        )
    }

    private static func burstMemberLookup(from entries: [PhotosListEntry]) -> [String: [String]] {
        let candidates =
            entries
            .filter { $0.tags.contains(LibraryPhotoTag.bursts.rawValue) }
            .map {
                BurstGroupCandidate(
                    id: $0.linkID,
                    relatedIDs: $0.relatedPhotos.map(\.linkID),
                    captureTime: Date(timeIntervalSince1970: $0.captureTime)
                )
            }
        return BurstGroupResolver.memberLookup(candidates: candidates)
    }
}

private extension ThumbnailPriority {
    var requestPriority: ProtonRequestPriority {
        switch self {
        case .visibleNow: .immediate
        case .zoomAnchorAndFocusRow: .userInitiated
        case .likelyZoomOutTargetCoverage, .nearViewportScrollAhead: .foregroundPrefetch
        case .idleLibraryCrawl: .maintenance
        }
    }
}

// MARK: - PhotoDimensionRecording (learned w/h into the library metadata DB)

extension DriveSDKBridge: PhotoDimensionRecording {
    /// Batched by `PhotoDimensionCoalescer`; the store fills only rows without dimensions
    /// (first-seen-wins), so repeated decodes and future true-dimension writers can coexist.
    func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {
        _ = try? await withOpenSession { bridge in
            bridge.timelineStore?.updateDimensions(batch)
        }
    }
}

// MARK: - PhotoUploading (UploadFeature seam)

/// Library upload via the SDK's `EncryptedMemoriesClient`. The SDK resolves the photos root itself, encrypts
/// + streams blocks (through `SDKHttpClient.requestUploadToStorage`), and returns the new node id. The
/// queue/state-machine lives in the pure `UploadManager`; this is just the transport.
extension DriveSDKBridge: PhotoUploading {
    nonisolated var capabilities: UploadBackendCapabilities {
        // The SDK exposes operation-level pause/resume, but we drive uploads through the `uploadPhoto`
        // convenience (no held operation), so in-flight pause isn't wired: queued items pause at the
        // queue level; cancelled/failed items retry from the start (honestly, not byte-resumed).
        .sdkUploader
    }

    /// The universal dedupe pipeline for this account: the SQLite identity manifest (per-account
    /// directory, purged on sign-out) + the Proton-keyed duplicate service. Built once at facade
    /// composition. If the manifest cannot open, return a fail-closed resolver: uploading without
    /// duplicate protection would risk library duplicates.
    nonisolated func makeUploadIdentityResolver() -> UploadIdentityResolverComposition {
        guard let store = UploadIdentityManifestStore(url: uploadManifestURL, policy: uploadManifestPolicy) else {
            DebugLog.log("[Dedupe] manifest store unavailable - uploads disabled")
            return UploadIdentityResolverComposition(
                resolver: ShutdownGatedUploadIdentityResolver(
                    base: DedupeUnavailableIdentityResolver(),
                    admission: shutdownGate
                ),
                close: {}
            )
        }
        let service = ProtonUploadDedupeService(
            session: driveSession,
            crypto: crypto,
            photosClient: photosClient,
            contentIndexStore: store
        ) { [self] in
            try await photosShareContext()
        }
        let pipeline = UploadDedupePipeline(
            store: store,
            checker: service,
            currentClientUID: uploadClientUID
        )
        return UploadIdentityResolverComposition(
            resolver: ShutdownGatedUploadIdentityResolver(base: pipeline, admission: shutdownGate),
            close: { store.close() }
        )
    }

    /// The album WRITE service (create + add-photos crypto/REST). Built once at facade
    /// composition; shares the bridge's session, crypto, and photos-share discovery.
    nonisolated func makeAlbumWriteService() -> ProtonAlbumWriteService {
        ProtonAlbumWriteService(
            session: driveSession,
            crypto: crypto,
            admission: shutdownGate
        ) { [self] in
            try await photosShareContext()
        }
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        try await withOpenSession { bridge in
            try await bridge.uploadImpl(request, onProgress: onProgress)
        }
    }

    private func uploadImpl(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        guard !isShutDown else { throw CancellationError() }
        try Task.checkCancellation()
        onProgress(UploadProgress(phase: .preparing))
        let isVideo = request.mediaType.hasPrefix("video/")
        let thumbnails = await UploadMediaProcessor.thumbnails(for: request.fileURL, isVideo: isVideo)
        try Task.checkCancellation()
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        do {
            // Secondary resources (a Live Photo's paired video) reference their primary. Core may
            // only know the primary's LINK id (from a duplicate-check row, which carries no
            // volume); every photo lives in the single photos volume, so an empty volumeID
            // resolves to the photos root's volume here at the transport boundary.
            var mainPhotoUid: SDKNodeUid?
            if let main = request.mainPhotoUID {
                let volumeID = main.volumeID.isEmpty ? try await resolvePhotosRoot().volumeID : main.volumeID
                try Task.checkCancellation()
                mainPhotoUid = SDKNodeUid(volumeID: volumeID, nodeID: main.nodeID)
            }
            try Task.checkCancellation()
            let operation = try await photosClient.uploadOperation(
                name: request.name,
                fileURL: request.fileURL,
                fileSize: request.fileSize,
                modificationDate: request.modificationDate,
                captureTime: request.captureTime,
                mainPhotoUid: mainPhotoUid,
                mediaType: request.mediaType,
                thumbnails: thumbnails,
                tags: Self.normalizedUploadTags(
                    requested: request.tags,
                    mediaType: request.mediaType,
                    isRelatedResource: mainPhotoUid != nil
                ),
                additionalMetadata: request.additionalMetadata.map {
                    AdditionalMetadata(name: $0.name, utf8JsonValue: $0.utf8JsonValue)
                },
                overrideExistingDraft: request.overrideExistingDraft,
                // From the dedupe pipeline's hashing phase - the SDK verifies the streamed bytes
                // against this digest server-side.
                expectedSHA1: request.expectedSHA1,
                cancellationToken: request.cancellationToken,
                progressCallback: { p in
                    onProgress(UploadProgress(phase: .uploading, fraction: p.fractionCompleted))
                }
            )
            let ids: UploadedFileIdentifiers
            do {
                try Task.checkCancellation()
                guard !operation.isCancellationRequested else { throw CancellationError() }
                try operation.claimStart()
                try Task.checkCancellation()
                ids = try await photosClient.startUpload(
                    operation: operation,
                    onRetriableErrorReceived: { _ in }
                )
            } catch {
                // The SDK deliberately keeps a cancelled operation's server draft so callers that
                // retain the operation can resume it. We do not support relaunch-resume, therefore
                // losing this local operation without disposal would strand the name indefinitely.
                if error is CancellationError || Self.isSDKCancellation(error) {
                    do {
                        try await operation.cleanUpTemporaryState()
                    } catch let cleanupError {
                        // Keep cancellation semantics for the queue. A later same-client preflight
                        // can still replace the draft if Proton could not dispose it right now.
                        DebugLog.log("[Upload] cancellation cleanup failed file=\(request.name) err=\(cleanupError)")
                    }
                }
                await operation.releaseResources()
                throw error
            }
            await operation.releaseResources()
            DebugLog.log("[Upload] completed node=\(ids.nodeUid.nodeID.prefix(8))… file=\(request.name)")
            let uid = PhotoUID(volumeID: ids.nodeUid.volumeID, nodeID: ids.nodeUid.nodeID)
            if mainPhotoUid == nil {
                pendingUploadedNodeIDs.insert(uid.nodeID)
            }
            _ = timelineStore?.recordMediaTypeEvidence(
                [uid: request.mediaType],
                publishRevision: false
            )
            return uid
        } catch {
            DebugLog.log("[Upload] FAILED file=\(request.name) err=\(error)")
            if error is CancellationError || Self.isSDKCancellation(error) {
                throw CancellationError()
            }
            throw Self.uploadError(from: error, filename: request.name)
        }
    }

    /// Standalone videos must carry Proton's tag 2 at creation; relying on asynchronous server
    /// classification produced valid movie bytes that every tag-driven timeline exposed as still
    /// images. A Live Photo's related motion resource is deliberately untagged so it cannot surface
    /// as a second standalone grid item.
    nonisolated static func normalizedUploadTags(
        requested: [Int],
        mediaType: String,
        isRelatedResource: Bool
    ) -> [Int] {
        var tags = Set(requested)
        if mediaType.lowercased().hasPrefix("video/") && !isRelatedResource {
            tags.insert(LibraryPhotoTag.videos.rawValue)
        } else {
            tags.remove(LibraryPhotoTag.videos.rawValue)
        }
        return tags.sorted()
    }

    /// Preserve the SDK's typed failure domain at the Core boundary. URL/socket failures retry as
    /// network problems; HTTP 408/429/5xx retry as temporary service failures; other API responses
    /// retain Proton's concrete message and follow the ordinary finite item retry policy.
    nonisolated static func uploadError(from error: Error, filename: String) -> any Error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return UploadCore.UploadError.transport(code: nsError.code, message: message)
        }
        guard let sdkError = error as? ProtonDriveSDKError else {
            return UploadCore.UploadError.backend(message)
        }
        if let fileSystemError = sdkError.underlyingFileSystemErrorCode,
            let mapped = uploadFileSystemError(fileSystemError, filename: filename)
        {
            return mapped
        }
        if sdkError.underlyingSocketNetworkError != nil {
            return UploadCore.UploadError.transport(code: NSURLErrorNetworkConnectionLost, message: message)
        }
        if let transport = sdkError.underlyingHTTPNetworkError {
            if let code = transport.httpCode, code == 408 || code == 429 || (500...599).contains(code) {
                return UploadCore.UploadError.retryableBackend(code: code, message: message)
            }
            switch transport.errorType {
            case .userAuthenticationError, .configurationLimitExceeded:
                return UploadCore.UploadError.backend(message)
            default:
                return UploadCore.UploadError.transport(
                    code: NSURLErrorNetworkConnectionLost,
                    message: message
                )
            }
        }
        if let api = sdkError.underlyingAPINetworkError,
            let code = api.httpCode,
            code == 408 || code == 429 || (500...599).contains(code)
        {
            return UploadCore.UploadError.retryableBackend(code: code, message: message)
        }
        return UploadCore.UploadError.backend(message)
    }

    /// Maps SDK 0.25's normalized local-file failures into the existing queue domains. In
    /// particular, low disk space reuses the backup runner's durable resource-pressure policy.
    nonisolated static func uploadFileSystemError(
        _ code: ProtonDriveSDKError.FileSystemErrorCode,
        filename: String
    ) -> (any Error)? {
        switch code {
        case .notFound:
            UploadCore.UploadError.fileMissing(filename)
        case .permissionDenied:
            UploadCore.UploadError.permissionDenied(filename)
        case .outOfSpace:
            BackupTempFileStore.BackupTempFileError.diskBudgetExceeded
        case .unknown:
            nil
        }
    }

    private nonisolated static func isSDKCancellation(_ error: Error) -> Bool {
        (error as? ProtonDriveSDKError)?.domain == .successfulCancellation
    }

    func cancel(token: UUID) async {
        _ = try? await withOpenSession { bridge in
            do {
                try await bridge.photosClient.cancelUpload(with: token)
            } catch {
                // The SDK cancellation owner releases its token even when native cancellation fails.
                // Keep the queue's nonthrowing control seam, but preserve evidence for diagnostics.
                DebugLog.log("[Upload] native cancellation failed token=\(token) err=\(error)")
            }
        }
    }
}

enum DriveBridgeError: LocalizedError {
    case noPhotosShare
    var errorDescription: String? {
        switch self {
        case .noPhotosShare: String(localized: "error.no_photos_library")
        }
    }
}

/// The SDK reported that this event scope is no longer accessible. Retrying the same scope cannot
/// recover, so the shared monitor stops until account lifecycle creates a new backend instance.
private struct DriveEventScopeAccessLostError: LocalizedError, LibraryChangeTerminalError {
    var errorDescription: String? {
        String(localized: "error.no_photos_library")
    }
}

/// Thread-safe one-shot data holder for the SDK thumbnail callback.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    func set(_ data: Data) { lock.withLock { _data = data } }
    var value: Data? { lock.withLock { _data } }
}

/// Thread-safe collector for per-item and stream-level failures of one thumbnail batch.
private final class BatchFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var itemErrors: [PhotoUID: String] = [:]
    private var streamError: String?

    func recordItem(_ uid: PhotoUID, reason: String) {
        lock.withLock { itemErrors[uid] = reason }
    }

    func recordStream(_ reason: String) {
        lock.withLock { if streamError == nil { streamError = reason } }
    }

    var result: ThumbnailBatchLoadResult {
        lock.withLock { ThumbnailBatchLoadResult(batchError: streamError, itemErrors: itemErrors) }
    }
}
