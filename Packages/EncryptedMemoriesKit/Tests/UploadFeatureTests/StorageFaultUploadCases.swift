import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

// Sweep cases of the operations that upload: the backup run and the manual upload settlement (#1155). Their fake
// remote lives in the `StorageFaultRemote` of the sweep, so a crash keeps what it received and rule I3 sees a second
// upload of the same photo.

/// The remote of an uploading case: the uploads that `StorageFaultRemote` recorded are the photos of the remote, and
/// its duplicate check finds them by name and content, as the Proton duplicate lookup does.
final class StorageFaultUploadRemote: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    let checker = FakeChecker()
    private let remote: StorageFaultRemote
    private let contentHash: @Sendable (String) -> String

    /// `contentHash` gives the content hash that the duplicate check reports for a file name.
    init(remote: StorageFaultRemote, contentHash: @Sendable @escaping (String) -> String) {
        self.remote = remote
        self.contentHash = contentHash
        for name in remote.uploads { publish(name) }
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        remote.recordUpload(request.name)
        publish(request.name)
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}

    private func publish(_ name: String) {
        checker.remoteItemsByNameHash["nh(\(name))"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(\(name))", contentHash: contentHash(name), linkState: .active,
                linkID: testUID(name).nodeID)
        ]
    }
}

/// The clock of one launch of an uploading case. Each launch starts one hour after the one before it, as a real launch
/// comes after the run it repeats: the runner takes over a row that a killed run left in progress only once its date
/// lies in the past. The count of launches lives in a file next to the stores, so a crash image keeps it; no state of
/// the sweep reads it.
func storageFaultLaunchClock(in directory: URL, from start: Date) throws -> BackupTestClock {
    let file = directory.appendingPathComponent("launches")
    let launches = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0) } ?? 0
    try String(launches + 1).write(to: file, atomically: true, encoding: .utf8)
    return BackupTestClock(start: start.addingTimeInterval(TimeInterval(launches) * 3_600))
}

extension StorageFaultState {
    /// Adds every table of the SQLite file at `url` without the columns that hold the time of a write, or a time that a
    /// write derives from it (the time of an exclusion, the next attempt). A restart runs later than the run it repeats,
    /// and a retry advances the clock, so these times differ between two runs with the same outcome.
    mutating func addSQLiteTablesWithoutWriteTimes(of url: URL) throws {
        try addSQLiteTables(of: url)
        let timeColumns: Set<String> = ["updated_at", "created_at", "recorded_at", "excluded_at", "next_attempt_at"]
        let columns = try withSQLiteDatabase(at: url) { database in
            try tables.keys.filter { $0.hasPrefix("\(url.lastPathComponent)/") }.map { key in
                let table = String(key.dropFirst(url.lastPathComponent.count + 1))
                let names = try sqliteRows(database, "SELECT name FROM pragma_table_info('\(table)');", typed: false)
                return (table, names.filter { !timeColumns.contains($0) })
            }
        }
        for (table, names) in columns {
            let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
            try setSQLiteRows(of: table, in: url, sql: "SELECT \(list) FROM \"\(table)\";")
        }
    }
}

/// The content hash that `FakeHasher` and `FakeChecker` give the file at `path`.
func storageFaultContentHash(path: String) -> String {
    "ch(\(UploadContentSHA1.hexString(digest: FakeHasher.digest(ofSeed: path))))"
}

/// One backup run until the queue is drained (`BackupSyncRunner.runUntilDrained`), as the backup controller starts
/// it: two new photos upload, and a third one that the remote already holds is recorded as backed up without an
/// upload. The run writes the queue, the backup state, the pending store and the identity manifest. A restart runs
/// the backup again on the stores that a launch opens.
struct BackupRunCase: StorageFaultCase {
    struct World {
        let queue: UploadBackupSyncQueueManifestStore
        let state: UploadBackupStateManifestStore
        let pending: PendingBackupManifestStore
        let identities: UploadIdentityManifestStore
        let runner: BackupSyncRunner
        let recorder: PendingBackupEventRecorder
        let remote: StorageFaultRemote
    }

    let id = "backup.runUntilDrained"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let names = ["new-1.jpg", "new-2.jpg", "on-remote.jpg"]
    private static let start = Date(timeIntervalSince1970: 1_720_000_000)

    private static func path(_ name: String) -> String {
        URL(fileURLWithPath: "/backup/\(name)").standardizedFileURL.path
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        remote.recordUpload("on-remote.jpg")
        let world = try open(directory, remote: remote)
        defer { close(world) }
        for name in Self.names {
            XCTAssertTrue(
                world.queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .file(URL(fileURLWithPath: "/backup/\(name)")),
                        revision: UploadBackupRevision(date: Self.start.addingTimeInterval(-3_600)),
                        originalFilename: name, byteCount: 4, state: .discovered, attempts: 0,
                        updatedAt: Self.start.addingTimeInterval(-60))))
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let clock = try storageFaultLaunchClock(in: directory, from: Self.start)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let state = try XCTUnwrap(
            UploadBackupStateManifestStore(
                url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)))
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        let identities = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let uploadRemote = StorageFaultUploadRemote(remote: remote) { storageFaultContentHash(path: Self.path($0)) }
        let recorder = PendingBackupEventRecorder(store: pending, now: { clock.now })
        let runner = BackupSyncRunner(
            queue: queue,
            preflight: UploadBackupPreflightIndex(store: state, now: { clock.now }),
            resolver: ScriptedBackupResolver(defaultModified: Self.start.addingTimeInterval(-3_600)),
            identityResolver: UploadDedupePipeline(
                store: identities, hasher: FakeHasher(), checker: uploadRemote.checker, now: { clock.now }),
            uploader: uploadRemote,
            configuration: BackupSyncRunner.Configuration(throttle: BackupThrottlePolicy(baseConcurrency: 1)),
            clock: clock, events: recorder, now: { clock.now })
        return World(
            queue: queue, state: state, pending: pending, identities: identities, runner: runner, recorder: recorder,
            remote: remote)
    }

    func faultTargets(of world: World) -> [Any] { [world.queue, world.state, world.pending, world.identities] }

    func run(_ world: World) async -> Bool {
        let progress = await world.runner.runUntilDrained()
        // A run that reports every photo as backed up must also have every photo on the remote.
        return progress.failed == 0 && progress.uploaded + progress.alreadyBackedUp == Self.names.count
            && Set(Self.names).isSubset(of: world.remote.uploads)
    }

    func close(_ world: World) {
        world.recorder.finish()
        world.queue.close()
        world.state.close()
        world.pending.close()
        world.identities.close()
    }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        let queue = directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        for name in [
            UploadBackupSyncQueueManifestStore.databaseFileName, UploadBackupStateManifestStore.databaseFileName,
            PendingBackupManifestStore.databaseFileName, UploadIdentityManifestStore.databaseFileName,
        ] {
            try state.addSQLiteTablesWithoutWriteTimes(of: directory.appendingPathComponent(name))
        }
        // Where a run stops decides details of a correct outcome. When the remote received a photo and the run then
        // fails or ends before its local record is complete, the retry or the next run can only find that photo on the
        // remote: the queue then says "already backed up" instead of "completed", the handoff says "deduplicated" and
        // carries no volume, and the manifest says "duplicateActive" without a volume. A retry also counts one more
        // attempt. The comparison therefore keeps, for every photo, whether it is backed up, whether the manifest finds
        // it on the remote, its remote link and its handoff. It leaves out the attempts, the handoff kind and volume,
        // and the manifest volume. Every other manifest outcome, and a missing one, still counts.
        try state.setSQLiteRows(
            of: "backup_sync_queue", in: queue,
            sql: """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                  CASE WHEN state IN ('completed', 'alreadyBackedUp') THEN 'backed up' ELSE state END,
                  last_error, remote_commit_reconciliation FROM backup_sync_queue;
                """)
        try state.setSQLiteRows(
            of: "handoff", in: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName),
            sql: "SELECT source_kind, source_id, revision_us, remote_link_id, acknowledged FROM handoff;")
        try state.setSQLiteRows(
            of: "upload_identity", in: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName),
            sql: """
                SELECT source_kind, source_id, resource, filename, corrected, size, mtime, sha1_hex, name_hash,
                  content_hash, key_epoch, remote_link,
                  CASE WHEN outcome IN ('uploaded', 'duplicateActive') THEN 'on remote' ELSE outcome END
                FROM upload_identity;
                """)
        // The duplicate-check evidence is read only by the display gates of `PendingBackupCoordinator`, which let the
        // pending grid show a photo whose queue row has not passed its check yet; no owed work reads it, and the
        // coordinator removes it when it retires the photo. `PendingBackupEventRecorder.recordUploadEvidence` returns
        // without an error when its write fails, so a failure there leaves the row out for good while the run goes on.
        // The sweep reports this at two points with one statement text, so no acceptance can name it; the comparison
        // leaves the table out.
        state.tables["\(PendingBackupManifestStore.databaseFileName)/upload_evidence"] = nil
        try state.addRecords(
            "queue row", of: queue, sql: "SELECT source_id || '#' || revision_us FROM backup_sync_queue;")
        return state
    }
}

/// The dedupe pipeline of the manual upload case, with its batched prefetch moved in front of the first decision of
/// each file. `UploadManager` starts the prefetch (`prime`) as a task of its own and does not wait for it, so its reads
/// of the identity manifest and those of the decision come in either order, and the points of the sweep would change
/// between runs. Here the prefetch always finishes before the decision starts, one of the orders that the manager
/// allows. Every other call goes to the pipeline unchanged. The prefetch only reads the manifest (`record(for:)`) and
/// asks the remote; it writes nothing durable. The sweep therefore does not cover these orders: a decision that starts
/// before or during the prefetch (the prefetch then clears the cached names while a decision runs), and a prefetch that
/// a cancelled item cancels (the manager cancels it only at shutdown). The prefetch here gets the descriptor of the
/// decision instead of the one that `UploadManager` builds from the file; the fields that it reads (source, file name,
/// main remote link) are the same in both.
final class StorageFaultPrimeFirstResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let lock = NSLock()
    private var primed: Set<UploadSourceIdentity> = []

    init(_ inner: UploadDedupePipeline) { self.inner = inner }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {}

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        if lock.withLock({ primed.insert(descriptor.source).inserted }) { await inner.prime([descriptor]) }
        return try await inner.resolve(descriptor)
    }

    func prepareRestoredCompound(
        _ context: UploadRestoredCompoundContext, isCurrent: @escaping @Sendable () -> Bool
    ) async throws { try await inner.prepareRestoredCompound(context, isCurrent: isCurrent) }
    func restoredPhotoOutcome(_ context: UploadRestoredCompoundContext) async throws -> PendingBackupReturnOutcome {
        try await inner.restoredPhotoOutcome(context)
    }
    func endRestoredCompound(_ context: UploadRestoredCompoundContext) async {
        await inner.endRestoredCompound(context)
    }
    func revalidateKnownRemote(_ descriptor: UploadResourceDescriptor) async throws -> UploadDuplicateDecision? {
        try await inner.revalidateKnownRemote(descriptor)
    }
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        try await inner.remoteAssetProofs(for: identities)
    }
    func prepareRemoteIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws { try await inner.prepareRemoteIndex(progress: progress) }
    func remoteIndexPreparationNotNeeded() async { await inner.remoteIndexPreparationNotNeeded() }
    func remoteContentIndexHealth() async throws -> UploadRemoteContentIndexHealth {
        try await inner.remoteContentIndexHealth()
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String
    ) async throws {
        try await inner.recordUploaded(
            descriptor, identity: identity, remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
    }
    func invalidateCachedRemoteState() async { await inner.invalidateCachedRemoteState() }
    func remoteMainsChangedHere() async { await inner.remoteMainsChangedHere() }
    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async { await inner.uploadDidFail(descriptor) }
    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        await inner.remoteCommitNeedsReconciliation(descriptor)
    }
    func identityRecord(for source: UploadSourceIdentity) async -> UploadIdentityRecord? {
        await inner.identityRecord(for: source)
    }
}

/// One manual upload of a photo into the library, with its durable settlement (`UploadManager`), wired as the account
/// wires it (`ProtonClientFacade`): the settlement store is required, and the dedupe pipeline over the identity
/// manifest decides before the bytes (its prefetch runs right before the decision, see
/// `StorageFaultPrimeFirstResolver`). This is the class of #1104: the receipt row, the identity record and the final
/// settlement row are separate writes. A launch restores the rows of the settlement store and settles a pending one
/// without bytes. The person adds the photo again only when the launch shows no item for it.
struct ManualUploadCase: StorageFaultCase {
    struct World {
        let settlements: UploadManualSettlementStore
        let identities: UploadIdentityManifestStore
        let manager: UploadManager
        let remote: StorageFaultRemote
    }

    let id = "manualUpload.library"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let start = Date(timeIntervalSince1970: 1_720_000_000)
    /// Outside the world, so that the path in a settlement row is the same in every copy of the world. The folder is
    /// unique to this process, so a sweep in another process never rewrites the file that this one uploads.
    private static let photo = FileManager.default.temporaryDirectory
        .appendingPathComponent("storage-fault-manual-upload-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("photo.jpg")

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        try FileManager.default.createDirectory(
            at: Self.photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("manual-upload-bytes".utf8).write(to: Self.photo, options: .atomic)
        close(try open(directory, remote: remote))
    }

    func finish() { try? FileManager.default.removeItem(at: Self.photo.deletingLastPathComponent()) }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let clock = try storageFaultLaunchClock(in: directory, from: Self.start)
        let settlements = try XCTUnwrap(
            UploadManualSettlementStore(
                url: directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)))
        let identities = try XCTUnwrap(
            UploadIdentityManifestStore(
                url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
        let uploadRemote = StorageFaultUploadRemote(remote: remote) { _ in
            storageFaultContentHash(path: Self.photo.standardizedFileURL.path)
        }
        let manager = UploadManager(
            uploader: uploadRemote,
            identityResolver: StorageFaultPrimeFirstResolver(
                UploadDedupePipeline(
                    store: identities, hasher: FakeHasher(), checker: uploadRemote.checker, now: { clock.now })),
            settlementStore: settlements, requiresDurableSettlement: true, maxConcurrent: 1, now: { clock.now })
        return World(settlements: settlements, identities: identities, manager: manager, remote: remote)
    }

    func faultTargets(of world: World) -> [Any] { [world.settlements, world.identities] }

    func run(_ world: World) async -> Bool {
        let (snapshots, continuation) = AsyncStream.makeStream(of: [UploadItem].self, bufferingPolicy: .unbounded)
        await world.manager.setOnChange { items, _ in continuation.yield(items) }
        // The launch restored the durable rows in `setOnChange`; the person adds the photo when no item shows it.
        if await world.manager.snapshot().isEmpty {
            _ = await world.manager.enqueueFiles([Self.photo], destination: .library)
        }
        let settled = await Self.firstTerminalSnapshot(of: snapshots)
        continuation.finish()
        await world.manager.shutdown()
        // A photo that the remote already holds ends as skipped and counts as backed up. A run that reports the photo as
        // backed up must also have it on the remote.
        let backedUp =
            settled?.allSatisfy { item in
                switch item.state {
                case .completed: true
                case .skipped(let reason): reason.countsAsBackedUp
                default: false
                }
            } ?? false
        return backedUp && world.remote.uploads.contains(Self.photo.lastPathComponent)
    }

    /// The first snapshot whose items all reached an end, or nil after 20 seconds: a run that never ends fails.
    private static func firstTerminalSnapshot(of snapshots: AsyncStream<[UploadItem]>) async -> [UploadItem]? {
        await withTaskGroup(of: [UploadItem]?.self) { group in
            group.addTask {
                for await items in snapshots where !items.isEmpty && items.allSatisfy(\.state.isTerminal) {
                    return items
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func close(_ world: World) {
        world.settlements.close()
        world.identities.close()
    }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        let settlements = directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        let identities = directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        try state.addSQLiteTablesWithoutWriteTimes(of: settlements)
        try state.addSQLiteTablesWithoutWriteTimes(of: identities)
        // A settlement row carries the random identifier of its queue item. An ended row only lets the list show the
        // item until the person clears it, and a photo that the next launch finds on the remote ends without a row.
        // The comparison keeps the rows that still owe work, by their stage. As in the backup run, the manifest outcomes
        // `uploaded` and `duplicateActive` both count as on the remote, and the manifest volume is left out.
        try state.setSQLiteRows(
            of: "manual_upload_settlement", in: settlements,
            sql: "SELECT stage FROM manual_upload_settlement WHERE stage <> 'terminal';")
        try state.setSQLiteRows(
            of: "upload_identity", in: identities,
            sql: """
                SELECT source_kind, source_id, resource, filename, corrected, size, mtime, sha1_hex, name_hash,
                  content_hash, key_epoch, remote_link,
                  CASE WHEN outcome IN ('uploaded', 'duplicateActive') THEN 'on remote' ELSE outcome END
                FROM upload_identity;
                """)
        return state
    }
}

/// The backup execution lock around one backup run (`BackupExecutionLockManifestStore`), in the order of
/// `PhotoLibraryBackupController`: the lock of a run that died is recovered, the new run takes the lock, renews it and
/// releases it at its end. Every launch is a new run with its own run identifier, as in the controller. A restart after
/// a kill recovers the lock that the killed run left, because its lease has passed by then.
struct BackupExecutionLockCase: StorageFaultCase {
    let id = "backup.executionLock"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let start = Date(timeIntervalSince1970: 1_720_000_000)

    struct World {
        let store: BackupExecutionLockManifestStore
        let clock: BackupTestClock
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        XCTAssertTrue(
            world.store.acquire(owner: .iOSBackgroundTask, runID: "dead-run", phase: "uploading", processContext: nil)
                .didAcquire)
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let clock = try storageFaultLaunchClock(in: directory, from: Self.start)
        let store = try XCTUnwrap(
            BackupExecutionLockManifestStore(
                url: directory.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName),
                now: { clock.now }))
        return World(store: store, clock: clock)
    }

    func faultTargets(of world: World) -> [Any] { [world.store] }

    func run(_ world: World) async -> Bool {
        let runID = "run-at-\(Int(world.clock.now.timeIntervalSince1970))"
        _ = world.store.recoverStaleLocks(
            olderThan: world.clock.now.addingTimeInterval(-BackupExecutionLockManifestStore.defaultLeaseInterval))
        guard world.store.acquire(owner: .foreground, runID: runID, phase: "scanning", processContext: nil).didAcquire
        else { return false }
        world.clock.advance(by: 30)
        guard world.store.heartbeat(runID: runID, phase: "uploading") == .renewed else { return false }
        return world.store.release(runID: runID)
    }

    func close(_ world: World) { world.store.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        try StorageFaultState(
            tablesOf: directory.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName))
    }
}

/// A backed-up photo that the person removes from the backup, and the trash of its Proton photo that this owes
/// (`PendingBackupManifestStore`), in the order of `PendingBackupCoordinator`: the exclusion, then the due states, the
/// mark right before the trash request, the request, and its completion. A launch repeats the exclusion only while the
/// photo still shows as included; the trash request itself can repeat, because a marked request counts as possibly
/// done until its completion. The queue sync that the exclusion also owes is not part of this case.
struct PendingTrashCase: StorageFaultCase {
    struct World {
        let store: PendingBackupManifestStore
        let clock: BackupTestClock
    }

    let id = "pending.excludeAndTrash"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let start = Date(timeIntervalSince1970: 1_720_000_000)
    private static let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "removed-photo")
    private static let revision = UploadBackupRevision(rawValue: 7)
    private static let photo = PhotoUID(volumeID: "vol", nodeID: "remote-photo")

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        XCTAssertEqual(
            world.store.recordHandoff(
                PendingHandoff(
                    key: Self.key, revision: Self.revision, remote: Self.photo, kind: .uploaded,
                    createdAt: world.clock.now)),
            .recorded)
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        World(
            store: try XCTUnwrap(
                PendingBackupManifestStore(
                    url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName))),
            clock: try storageFaultLaunchClock(in: directory, from: Self.start))
    }

    func faultTargets(of world: World) -> [Any] { [world.store] }

    func run(_ world: World) async -> Bool {
        let store = world.store
        guard case .readable(let current) = store.sourceStateRead(for: Self.key) else { return false }
        if current?.desired != .excluded {
            let request = PendingExclusionRequest(
                key: Self.key, presentation: nil, remote: Self.photo, revision: Self.revision)
            guard store.exclude([request], at: world.clock.now) != nil else { return false }
        }
        let due = store.dueSourceStatesRead(by: world.clock.now)
        guard due.complete else { return false }
        let trash = due.states.filter { $0.needsRemoteTrash && $0.desired == .excluded && $0.remote != nil }
        guard let marked = store.beginRemoteOperation(.remoteTrash, for: trash) else { return false }
        for state in trash where marked.contains(state.key) {
            guard
                store.completeEffectResult(
                    .remoteTrash, for: state.key, generation: state.generation, remoteLinkID: state.remote?.nodeID,
                    at: world.clock.now) != .failed
            else { return false }
        }
        return true
    }

    func close(_ world: World) { world.store.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        var state = StorageFaultState()
        try state.addSQLiteTablesWithoutWriteTimes(of: url)
        try state.addRecords(
            "handoff", of: url, sql: "SELECT source_id || '#' || revision_us || '#' || remote_link_id FROM handoff;")
        return state
    }
}
