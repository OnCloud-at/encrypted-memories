import Foundation
import UploadCore

/// How the sync run binds a local album to a Proton album.
public enum AlbumSyncResolution: Sendable, Equatable {
    /// Stored mapping if present; otherwise create a new Proton album. If a remote album already
    /// carries the same name, throw `AlbumSyncError.nameConflict` so the UI can ask the user.
    /// Automatic resolution never attaches by name alone.
    case automatic
    /// The user explicitly chose an existing Proton album (from the conflict dialog).
    case attachToExisting(remoteAlbumID: String)
    /// The user explicitly asked for a new album even though a name twin exists. The server may
    /// still reject the duplicate name - that error surfaces honestly.
    case createNew
}

/// Universal local-album to Proton-album sync engine. Platform-neutral: local albums come from an
/// injected source (PhotoKit adapter on Apple platforms), backup goes through the injected
/// executor (the standard upload/dedupe pipeline; media bytes are never uploaded twice), and
/// remote album operations go through the injected backend ops.
///
/// v1 is strictly additive (`AlbumSyncMode.additive`): nothing is removed from Proton, ever.
///
/// Durability: the local and remote album mapping is persisted before any backup or attach work, so a
/// crash mid-run can never cause a second album to be created for the same local album. Attach
/// work is re-derived per run from the manifest + the album's current children (idempotent -
/// "already a member" converges), so no separate pending-operation log is needed.
public actor AlbumSyncRunner {
    private let localSource: any AlbumSyncLocalAlbumSource
    private let backup: any AlbumSyncBackupExecuting
    private let remoteOps: any AlbumSyncRemoteAlbumOps
    private let linkLookup: any AlbumSyncRemoteLinkLookup
    private let mappingStore: AlbumSyncMappingStore?
    private let now: @Sendable () -> Date

    /// Photos per `attach` call and per same-content lookup - a progress and Stop granularity choice (the backend
    /// further batches to the API's own limit internally).
    private let attachChunkSize: Int

    private var onProgress: (@Sendable (AlbumSyncProgress) -> Void)?
    private var progress = AlbumSyncProgress()
    private var isRunning = false
    private var stopRequested = false

    public init(
        localSource: any AlbumSyncLocalAlbumSource,
        backup: any AlbumSyncBackupExecuting,
        remoteOps: any AlbumSyncRemoteAlbumOps,
        linkLookup: any AlbumSyncRemoteLinkLookup,
        mappingStore: AlbumSyncMappingStore?,
        attachChunkSize: Int = 50,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.localSource = localSource
        self.backup = backup
        self.remoteOps = remoteOps
        self.linkLookup = linkLookup
        self.mappingStore = mappingStore
        self.attachChunkSize = max(1, attachChunkSize)
        self.now = now
    }

    // MARK: - Observation

    public func setOnProgress(_ callback: @Sendable @escaping (AlbumSyncProgress) -> Void) {
        onProgress = callback
    }

    public var currentProgress: AlbumSyncProgress { progress }

    // MARK: - Precheck (for the UI's conflict dialog)

    public enum Precheck: Sendable, Equatable {
        /// A stored mapping exists - sync continues into that album, no questions.
        case mapped(remoteAlbumID: String)
        /// No mapping, and remote albums with the exact same (trimmed) name exist.
        case nameConflict([AlbumSyncRemoteAlbum])
        /// No mapping, no name twin - `automatic` will create a fresh album.
        case clear
    }

    /// What starting a sync for `album` would do. UI calls this to decide whether to show the
    /// "use existing Proton album?" dialog before `sync`.
    public func precheck(album: LocalAlbumSummary) async throws -> Precheck {
        guard let mappingStore, mappingStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        try await ensureAlbumPresent(albumID: album.id)
        if let mapping = mappingStore.mapping(localAlbumID: album.id) {
            return .mapped(remoteAlbumID: mapping.remoteAlbumID)
        }
        guard mappingStore.isOperational() else { throw AlbumSyncError.mappingStoreUnavailable }
        let twins = try await nameTwins(of: album.title)
        return twins.isEmpty ? .clear : .nameConflict(twins)
    }

    // MARK: - Sync

    /// Runs one full additive sync of `album`. Throws `AlbumSyncError.nameConflict` when
    /// `resolution == .automatic` and an unmapped name twin exists.
    @discardableResult
    public func sync(
        album: LocalAlbumSummary, resolution: AlbumSyncResolution = .automatic
    ) async throws -> AlbumSyncReport {
        guard !isRunning else { throw AlbumSyncError.alreadyRunning }
        guard let mappingStore, mappingStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        isRunning = true
        stopRequested = false
        defer { isRunning = false }

        do {
            let report = try await run(album: album, resolution: resolution, mappingStore: mappingStore)
            return report
        } catch {
            if progress.phase != .needsAttention {
                progress.phase = .needsAttention
                progress.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                publish()
            }
            throw error
        }
    }

    /// Requests a stop. The current attach chunk finishes; backup checkpoints and stops. Work
    /// already done is durable server-side, so the next run resumes/converges.
    public func stop() async {
        stopRequested = true
        await backup.stop()
    }

    // MARK: - Phases

    private func run(
        album: LocalAlbumSummary,
        resolution: AlbumSyncResolution,
        mappingStore: AlbumSyncMappingStore
    ) async throws -> AlbumSyncReport {
        progress = AlbumSyncProgress()
        progress.localAlbumID = album.id
        progress.albumTitle = album.title
        progress.phase = .scanningLocal
        publish()

        // Read local album identifiers without asset bytes. Missing is not empty: a deleted PhotoKit
        // collection must never be interpreted as a valid empty remote album.
        let identifiers = try await requireAlbumContents(albumID: album.id)
        progress.totalAssets = identifiers.count
        publish()
        try checkStop()

        // Resolve the Proton album first and persist the mapping. Fail fast on conflicts so a crash
        // cannot create a second album later.
        try await ensureAlbumPresent(albumID: album.id)
        try checkStop()
        let remoteAlbumID = try await resolveRemoteAlbum(
            album: album, resolution: resolution, mappingStore: mappingStore)
        try checkStop()

        // Back up every album asset through the standard pipeline. The dedupe manifest remains the
        // single duplicate authority, so already-backed-up assets cost one preflight lookup.
        try await ensureAlbumPresent(albumID: album.id)
        try checkStop()
        progress.phase = .backingUp
        publish()
        let updateBackupProgress: @Sendable (BackupSyncProgress) -> Void = { [weak self] snapshot in
            Task { await self?.applyBackupProgress(snapshot) }
        }
        let backupReport = try await backup.ensureBackedUp(
            localIdentifiers: identifiers, onProgress: updateBackupProgress)
        try checkStop()

        // Build the pure, idempotent attach plan from current members and manifest links.
        progress.phase = .checkingAlbum
        publish()
        var links = await linkLookup.remoteLinks(for: identifiers)
        try checkStop()
        let missing = identifiers.filter { links[$0] == nil }
        if !missing.isEmpty {
            let proven: [String: AlbumSyncRemoteLink]
            do {
                proven = try await backup.remoteProofLinks(for: missing)
            } catch {
                try checkStop()
                if error is CancellationError { throw error }
                if (error as? AlbumSyncError) == .stopped { throw error }
                proven = [:]
            }
            try checkStop()
            links.merge(proven) { existing, _ in existing }
        }
        try await ensureAlbumPresent(albumID: album.id)
        try checkStop()
        let children = try await remoteOps.childMainLinkIDs(albumID: remoteAlbumID)
        try checkStop()
        let sameContent = try await membersWithSameContent(links: links, children: children)
        try checkStop()
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: identifiers,
            remoteLinks: links,
            existingChildLinkIDs: children,
            memberWithSameContent: sameContent
        )
        progress.alreadyMember = plan.alreadyMember
        progress.unattachable = plan.missingRemote
        progress.trashedSkipped = plan.trashedRemote
        progress.attachTotal = plan.toAttach.count
        publish()
        try checkStop()

        // Attach in chunks for progress and stop granularity. The backend batches to the API limit.
        progress.phase = .attaching
        publish()
        var attachResult = AlbumSyncAttachResult()
        var index = 0
        while index < plan.toAttach.count {
            try checkStop()
            try await ensureAlbumPresent(albumID: album.id)
            try checkStop()
            let chunk = Array(plan.toAttach[index..<min(index + attachChunkSize, plan.toAttach.count)])
            let result = try await remoteOps.attach(chunk, albumID: remoteAlbumID)
            attachResult += result
            index += chunk.count
            progress.attachDone = attachResult.attached
            progress.alreadyMember = plan.alreadyMember + attachResult.alreadyMember
            progress.attachFailed = attachResult.failed
            progress.message = attachResult.firstFailureMessage
            publish()
        }

        // Persist the run outcome on the mapping and settle the status.
        try await ensureAlbumPresent(albumID: album.id)
        let attachFailedIdentifiers = Self.localIdentifiers(
            of: attachResult.failedLinkIDs, orderedLocalIdentifiers: identifiers, links: links)
        // A photo with a usable link goes into the album even when the backup keeps a part of it open, for
        // example the video of a Live Photo behind a draft. It is no complete backup, so the album reports it.
        let failedLinkIDs = Set(attachResult.failedLinkIDs)
        // A photo that attaches through another photo's link with the same bytes is not in the album when that
        // attach failed.
        let failedContent = Set(plan.toAttach.filter { failedLinkIDs.contains($0.uid.nodeID) }.compactMap(\.sha1Hex))
        let incompleteIdentifiers = Self.incompleteIdentifiers(
            orderedLocalIdentifiers: identifiers, links: links, attachFailedLinkIDs: failedLinkIDs,
            attachFailedContent: failedContent, albumMembers: children, backup: backupReport)
        progress.incomplete = incompleteIdentifiers.count
        let report = AlbumSyncReport(
            remoteAlbumID: remoteAlbumID,
            totalAssets: identifiers.count,
            attached: attachResult.attached,
            alreadyMember: plan.alreadyMember + attachResult.alreadyMember,
            attachFailed: attachResult.failed,
            unattachable: plan.missingRemote,
            trashedSkipped: plan.trashedRemote,
            incomplete: incompleteIdentifiers.count,
            problems: AlbumSyncProblemList.items(
                missingIdentifiers: plan.missingRemoteIdentifiers,
                attachFailedIdentifiers: attachFailedIdentifiers,
                incompleteIdentifiers: incompleteIdentifiers,
                backup: backupReport)
        )
        var mapping =
            mappingStore.mapping(localAlbumID: album.id)
            ?? AlbumSyncMapping(
                localAlbumID: album.id, remoteAlbumID: remoteAlbumID, title: album.title, createdAt: now())
        mapping.title = album.title
        mapping.lastSyncedAt = now()
        mapping.lastAttachedCount = report.attached
        mapping.lastFailedCount = report.attachFailed + report.unattachable + report.incomplete
        guard mappingStore.upsert(mapping) else { throw AlbumSyncError.mappingStoreUnavailable }

        progress.phase = report.isFullySynced ? .completed : .needsAttention
        if !report.isFullySynced, progress.message == nil {
            progress.message = attachResult.firstFailureMessage
        }
        publish()
        return report
    }

    /// For each SHA-1 of a link that is not in the album, an album member with the same bytes, for example another
    /// device's copy of a shared photo. The lookup runs in chunks, so Stop takes effect between them. A failed chunk
    /// ends the lookup with the members found so far, and the other photos attach as before.
    private func membersWithSameContent(
        links: [String: AlbumSyncRemoteLink], children: Set<String>
    ) async throws -> [String: String] {
        let candidates = Set(
            links.values.compactMap { link in
                link.isTrashed || children.contains(link.uid.nodeID) ? nil : link.sha1Hex
            }
        ).sorted()
        guard !candidates.isEmpty, !children.isEmpty else { return [:] }
        var copies: [String: Set<String>] = [:]
        var start = 0
        while start < candidates.count {
            try checkStop()
            let chunk = Set(candidates[start..<min(start + attachChunkSize, candidates.count)])
            start += chunk.count
            do {
                copies.merge(try await remoteOps.activeMainLinkIDs(withSameContentAs: chunk)) { $0.union($1) }
            } catch {
                // Stop and task cancellation end the run; any other failure, also a cancelled index refresh, keeps
                // today's attach for the rest.
                try checkStop()
                break
            }
        }
        // Only a current album member counts. The smallest member id keeps the choice stable between runs.
        return copies.compactMapValues { $0.intersection(children).min() }
    }

    /// The photos with a usable, not trashed link whose backup row is unresolved, in album order. A photo whose
    /// link failed to attach is not in the album and counts as failed, also when another photo shares the link.
    static func incompleteIdentifiers(
        orderedLocalIdentifiers: [String],
        links: [String: AlbumSyncRemoteLink],
        attachFailedLinkIDs: Set<String>,
        attachFailedContent: Set<String> = [],
        albumMembers: Set<String> = [],
        backup: AlbumSyncBackupReport
    ) -> [String] {
        orderedLocalIdentifiers.filter { identifier in
            guard let link = links[identifier], !link.isTrashed, !attachFailedLinkIDs.contains(link.uid.nodeID)
            else {
                return false
            }
            if let sha1Hex = link.sha1Hex, attachFailedContent.contains(sha1Hex),
                !albumMembers.contains(link.uid.nodeID)
            {
                return false
            }
            return backup.problems[identifier] != nil
        }
    }

    /// Maps failed link ids back, in album order, to the local photo that planned each attach:
    /// the first photo with that link, as in `AlbumSyncPlanner`.
    static func localIdentifiers(
        of failedLinkIDs: [String],
        orderedLocalIdentifiers: [String],
        links: [String: AlbumSyncRemoteLink]
    ) -> [String] {
        var remaining = Set(failedLinkIDs)
        var result: [String] = []
        for identifier in orderedLocalIdentifiers where !remaining.isEmpty {
            guard let link = links[identifier], !link.isTrashed,
                remaining.remove(link.uid.nodeID) != nil
            else { continue }
            result.append(identifier)
        }
        return result
    }

    private func resolveRemoteAlbum(
        album: LocalAlbumSummary,
        resolution: AlbumSyncResolution,
        mappingStore: AlbumSyncMappingStore
    ) async throws -> String {
        if let mapping = mappingStore.mapping(localAlbumID: album.id) {
            return mapping.remoteAlbumID
        }
        guard mappingStore.isOperational() else { throw AlbumSyncError.mappingStoreUnavailable }
        let name = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAlbumID: String
        switch resolution {
        case .automatic:
            let twins = try await nameTwins(of: album.title)
            try checkStop()
            guard twins.isEmpty else { throw AlbumSyncError.nameConflict(existing: twins) }
            try await ensureAlbumPresent(albumID: album.id)
            try checkStop()
            remoteAlbumID = try await remoteOps.createAlbum(name: name)
        case .attachToExisting(let existingID):
            try await ensureAlbumPresent(albumID: album.id)
            try checkStop()
            remoteAlbumID = existingID
        case .createNew:
            try await ensureAlbumPresent(albumID: album.id)
            try checkStop()
            remoteAlbumID = try await remoteOps.createAlbum(name: name)
        }
        guard
            mappingStore.upsert(
                AlbumSyncMapping(
                    localAlbumID: album.id,
                    remoteAlbumID: remoteAlbumID,
                    title: album.title,
                    createdAt: now()
                ))
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        return remoteAlbumID
    }

    private func nameTwins(of title: String) async throws -> [AlbumSyncRemoteAlbum] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try await remoteOps.listAlbums()
        return remote.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    private func requireAlbumContents(albumID: String) async throws -> [String] {
        switch try await localSource.albumContents(albumID: albumID) {
        case .present(let identifiers): identifiers
        case .missing: throw AlbumSyncError.localAlbumMissing
        }
    }

    private func ensureAlbumPresent(albumID: String) async throws {
        guard try await localSource.albumExists(albumID: albumID) else {
            throw AlbumSyncError.localAlbumMissing
        }
    }

    // MARK: - Helpers

    private func applyBackupProgress(_ snapshot: BackupSyncProgress) {
        guard progress.phase == .backingUp else { return }
        progress.backedUp = snapshot.backedUp
        progress.backupFailed = snapshot.failed
        progress.isWaitingForWiFi = snapshot.isPausedByPolicy && snapshot.isWaitingForWiFi
        publish()
    }

    private func checkStop() throws {
        if stopRequested { throw AlbumSyncError.stopped }
        if Task.isCancelled { throw AlbumSyncError.stopped }
    }

    private func publish() {
        onProgress?(progress)
    }
}
