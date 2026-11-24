import DeviceRootCore
import Foundation
import PhotosCore
import XCTest

@testable import AlbumSyncCore
@testable import DeviceRootAppleAdapter
@testable import PhotoLibraryBackupAdapter
@testable import ProtonDriveBackend
@testable import UploadCore

/// Every storage-changing operation in the fault-injection sweep (#1141). Add a new operation here once; the sweep
/// covers it from then on.
let storageFaultCases: [any StorageFaultCase] = [
    CatalogUpsertBatchCase(),
    CatalogPassCase(id: "catalog.fullScan", pass: .fullScan),
    CatalogPassCase(id: "catalog.changeScan", pass: .changeScan(["asset-2", "asset-3", "asset-4"])),
    CatalogPassCase(id: "catalog.missingSources", pass: .missingSources),
    CatalogPassCase(id: "catalog.lateRenders", pass: .lateRenders),
    CatalogPassCase(id: "catalog.lateRenderScan", pass: .lateRenderScan),
    CatalogPassCase(id: "catalog.expiredHistory", pass: .expiredHistory),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.update", seededChanges: 2),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.compact", seededChanges: 1_000),
    EditReplacementJournalCreateCase(),
    PhotoJournalCase(id: "journal.revert.save", journal: .revert, step: .save),
    PhotoJournalCase(id: "journal.revert.remove", journal: .revert, step: .remove),
    PhotoJournalCase(id: "journal.series.save", journal: .series, step: .save),
    PhotoJournalCase(id: "journal.series.remove", journal: .series, step: .remove),
    ExactDuplicateMergeJournalCase(id: "journal.exactDuplicateMerge.record", step: .record),
    ExactDuplicateMergeJournalCase(id: "journal.exactDuplicateMerge.clear", step: .clear),
    DeletionDecisionCase(keepDeleted: true, start: .noIntent),
    DeletionDecisionCase(keepDeleted: false, start: .noIntent),
    DeletionDecisionCase(keepDeleted: true, start: .ownIntent),
    DeletionDecisionCase(keepDeleted: false, start: .ownIntent),
    DeletionDecisionCase(keepDeleted: true, start: .stuckOppositeIntent),
    DeletionDecisionCase(keepDeleted: false, start: .stuckOppositeIntent),
    DeletionDecisionCase(keepDeleted: true, start: .appliedOppositeIntent),
    DeletionDecisionCase(keepDeleted: false, start: .appliedOppositeIntent),
    FingerprintCacheCase(id: "fingerprints.store", step: .store),
    FingerprintCacheCase(id: "fingerprints.storeSizes", step: .storeSizes),
    FingerprintCacheCase(id: "fingerprints.advance", step: .advance),
    FingerprintCacheCase(id: "fingerprints.discontinuity", step: .discontinuity),
    TrashedSeriesRestoreCase(id: "trashedSeries.record", step: .record),
    TrashedSeriesRestoreCase(id: "trashedSeries.update", step: .update),
    TrashedSeriesRestoreCase(id: "trashedSeries.finish", step: .finish),
    LocalReadFailureHintCase(id: "localReadFailureHints.insert", step: .insert),
    LocalReadFailureHintCase(id: "localReadFailureHints.remove", step: .remove),
    LocalReadFailureHintCase(id: "localReadFailureHints.saveSweepCursor", step: .saveSweepCursor),
    DeviceRootEnrollmentCase(id: "deviceRoot.beginCreate", step: .beginCreate),
    DeviceRootEnrollmentCase(id: "deviceRoot.markDispatchAttempted", step: .markDispatchAttempted),
    DeviceRootEnrollmentCase(id: "deviceRoot.finishCreate", step: .finishCreate),
    BackupRunCase(),
    BackupExecutionLockCase(),
    ManualUploadCase(),
    PendingTrashCase(),
    AlbumSyncRefusalWriteBackCase(),
    AlbumSyncMappingUpsertCase(),
    AlbumSyncSelectionWriteCase(),
    AlbumSyncLastRunWriteCase(),
]

/// A deletion decision on the real queue and journal, by its production operations. By `start`:
/// - `noIntent`: launch replay, then the decision, then launch replay again. The second replay also settles a
///   best-effort settle that failed after the queue committed. The separate unit test pins that retained intent before
///   the next launch.
/// - `ownIntent`: launch replay of this choice's recorded intent.
/// - `stuckOppositeIntent`: the opposite choice is recorded and its rows still wait (its queue write failed). The
///   person's tap runs as `PhotoLibraryBackupController.resolveRemoteDeletion` does: `prepareLatestChoice`, then
///   `record` (#1482). The next launch's replay follows, without another tap. A tap that reached `record` must be the
///   choice that this replay applies, even when `record` failed: a take-back would bring the opposite choice back.
///   The tap is a model of the controller: it reads the row with `entry`, while the controller reads it with
///   `decisionEntry` and `decisionRows`. Check the pinned points again when the controller's tap changes.
///   Scope: a restart here taps again before its replay, while a real launch replays first. When one of the four
///   reads of the tap before `record` fails (points 1 to 4), or its journal append (point 5, accepted below), nothing
///   durable records the new choice. A real launch then applies the earlier choice, which the person recorded
///   durably before; the sweep checks this outcome only at point 5. The two reads of `prepareLatestChoice` share one
///   SQL text, so one acceptance per point cannot name them.
/// - `appliedOppositeIntent`: the opposite choice moved the rows, but its clear failed. The tap's `prepareLatestChoice`
///   settles that intent, and the rows no longer wait, so the tap records nothing.
struct DeletionDecisionCase: StorageFaultCase {
    enum Start: Sendable {
        case noIntent, ownIntent, stuckOppositeIntent, appliedOppositeIntent
    }

    struct World {
        let queue: UploadBackupSyncQueueManifestStore
        let journal: EditReplacementJournalFileStore
        let files: StorageFaultFiles
    }
    let keepDeleted: Bool
    let start: Start
    var id: String {
        let operation =
            switch start {
            case .noIntent: "resolveRemoteDeletion"
            case .ownIntent: "replayRemoteDeletion"
            case .stuckOppositeIntent: "replaceRemoteDeletion"
            case .appliedOppositeIntent: "settleRemoteDeletion"
            }
        return "backup.\(operation).\(keepDeleted ? "keep" : "backUpAgain")"
    }
    let atomicity = StorageFaultAtomicity.convergesAfterRestart

    /// An inherent limit, not a defect: when the journal append of the new choice itself fails, nothing durable
    /// records it. The person sees the local-state error, and the last durably recorded choice stands at the next
    /// launch; the rows then no longer wait, so the tap cannot repeat it. A retry in the same session can still
    /// succeed.
    var acceptances: [StorageFaultAcceptance] {
        guard start == .stuckOppositeIntent else { return [] }
        let point = "append \(EditReplacementJournalFileStore.logFileName)"
        let reason =
            "nothing durable records a new choice whose journal append failed; the person sees the error, and the "
            + "last durably recorded choice stands at the next launch"
        return [
            StorageFaultAcceptance(rule: .honestOutcome, phase: .failedRun, point: point, reason: reason),
            StorageFaultAcceptance(rule: .restartConverges, phase: .restartAfterFailure, point: point, reason: reason),
        ]
    }
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "decision-photo")
    private let revisions = [UploadBackupRevision(rawValue: 1), UploadBackupRevision(rawValue: 2)]
    private let date = Date(timeIntervalSince1970: 1_720_000_001)

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        for revision in revisions {
            XCTAssertTrue(
                world.queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source, revision: revision,
                        originalFilename: "photo.heic", state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)))
        }
        try world.journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "gone"), for: source)
        switch start {
        case .noIntent: break
        case .ownIntent:
            try world.journal.recordDeletionDecision(choice(keepDeleted), revisions: revisions, for: source)
        case .stuckOppositeIntent, .appliedOppositeIntent:
            try world.journal.recordDeletionDecision(choice(!keepDeleted), revisions: revisions, for: source)
            if start == .appliedOppositeIntent {
                let rows = try world.journal.pendingDeletionDecision(for: source)
                XCTAssertTrue(world.queue.updateStates(of: source, rows.map(\.update), updatedAt: date))
            }
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(
            queue: try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName))),
            journal: try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files)),
            files: files)
    }

    func faultTargets(of world: World) -> [Any] { [world.queue, world.files] }

    func run(_ world: World) async -> Bool {
        switch start {
        case .noIntent, .ownIntent: await decideAfterReplay(world)
        case .stuckOppositeIntent, .appliedOppositeIntent: await tapThenNextLaunch(world)
        }
    }

    private func choice(_ keep: Bool) -> EditReplacementDeletionChoice {
        keep ? .keptDeleted : .backUpAgain(revisions[1])
    }

    private func decideAfterReplay(_ world: World) async -> Bool {
        guard await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: date) else {
            return false
        }
        do {
            let row = try world.queue.entry(for: source, revision: revisions[1])
            if row?.state == .failedPermanent {
                try await DeletionDecisionReplay.record(
                    choice(keepDeleted), revisions: revisions, for: source, queue: world.queue,
                    journal: world.journal, at: date)
            }
            return await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: date)
        } catch { return false }
    }

    /// The tap as the controller runs it, then the next launch's replay. A tap that fails before `record` reports the
    /// failure. A tap whose `record` fails also shows the person the error, but its choice stays recorded, so the
    /// outcome is the next launch's replay.
    private func tapThenNextLaunch(_ world: World) async -> Bool {
        var reachedRecord = false
        do {
            _ = try await DeletionDecisionReplay.prepareLatestChoice(
                for: source, queue: world.queue, journal: world.journal)
            let row = try world.queue.entry(for: source, revision: revisions[1])
            if let row, row.state == .failedPermanent,
                BackupIssueRecord.decode(row.lastError)?.kind == .deletedElsewhere
            {
                reachedRecord = true
                try await DeletionDecisionReplay.record(
                    choice(keepDeleted), revisions: revisions, for: source, queue: world.queue,
                    journal: world.journal, at: date)
            }
        } catch {
            guard reachedRecord else { return false }
        }
        return await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: date)
    }

    func close(_ world: World) { world.queue.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        let url = directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        var state = StorageFaultState()
        try state.addSQLiteTables(of: url)
        try state.addRecords("queue revision", of: url, sql: "SELECT revision_us FROM backup_sync_queue;")
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        state.tables["decision journal"] = [
            canonicalJSON(
                String(
                    decoding:
                        try JSONEncoder().encode(journal.entry(for: source)), as: UTF8.self))
        ]
        state.records["superseded link"] = Set(journal.entry(for: source).superseded.map(\.nodeID))
        return state
    }
}

/// The photo library before the operation (`seed`) and when it runs: asset-2 is edited, asset-3 is deleted, asset-4
/// and asset-5 are new, asset-1 is unchanged.
private func catalogLibraries() -> (seed: EditScenarioLibrary, current: EditScenarioLibrary) {
    let scratch = FileManager.default.temporaryDirectory
    let seed = EditScenarioLibrary(directory: scratch)
    let current = EditScenarioLibrary(directory: scratch)
    for identifier in ["asset-1", "asset-2", "asset-3"] { seed.add(identifier, basename: identifier) }
    for identifier in ["asset-1", "asset-2", "asset-3", "asset-4", "asset-5"] {
        current.add(identifier, basename: identifier)
    }
    current.edit("render-2", identifier: "asset-2", at: Date(timeIntervalSince1970: 1_720_000_500))
    current.delete("asset-3")
    return (seed, current)
}

/// The seed library of `catalogLibraries`, where Photos now lists the rendered file of asset-2 and leaves its dates
/// alone, so its revision stays the one that an earlier build backed up.
private func lateRenderLibrary() -> EditScenarioLibrary {
    let library = EditScenarioLibrary(directory: FileManager.default.temporaryDirectory)
    for identifier in ["asset-1", "asset-2", "asset-3"] { library.add(identifier, basename: identifier) }
    library.publishRender("render-2", identifier: "asset-2")
    return library
}

private func catalogStore(in directory: URL) throws -> PhotoLibraryCatalogManifestStore {
    try XCTUnwrap(
        PhotoLibraryCatalogManifestStore(
            url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
}

private func catalogState(in directory: URL) throws -> StorageFaultState {
    let url = directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
    var state = StorageFaultState()
    try state.addSQLiteTables(of: url)
    // A row marked removed is no present photo; marking a present photo removed loses it.
    try state.addRecords("catalog photo", of: url, sql: "SELECT local_id FROM photo_catalog WHERE is_removed=0;")
    return state
}

/// One catalog transaction that changes one photo and adds two (`PhotoLibraryCatalogManifestStore.upsertBatch`).
struct CatalogUpsertBatchCase: StorageFaultCase {
    let id = "catalog.upsertBatch"
    let atomicity = StorageFaultAtomicity.allOrNothing
    private let libraries = catalogLibraries()

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let store = try catalogStore(in: directory)
        defer { store.close() }
        XCTAssertTrue(store.upsertBatch(entries(of: libraries.seed, ["asset-1", "asset-2"], at: 100)))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> PhotoLibraryCatalogManifestStore {
        try catalogStore(in: directory)
    }

    func faultTargets(of world: PhotoLibraryCatalogManifestStore) -> [Any] { [world] }

    func run(_ world: PhotoLibraryCatalogManifestStore) async -> Bool {
        world.upsertBatch(entries(of: libraries.current, ["asset-2", "asset-4", "asset-5"], at: 200))
    }

    func close(_ world: PhotoLibraryCatalogManifestStore) { world.close() }

    func state(in directory: URL) throws -> StorageFaultState { try catalogState(in: directory) }

    private func entries(
        of library: EditScenarioLibrary, _ identifiers: [String], at seconds: TimeInterval
    ) -> [PhotoLibraryCatalogEntry] {
        library.snapshot.filter { identifiers.contains($0.identifier) }.map {
            PhotoLibraryCatalogMapper.entry(for: $0.info, observedAt: Date(timeIntervalSince1970: seconds))
        }
    }
}

/// A catalog pass of `PhotoLibraryCatalogSync` over chunks of two photos. A table next to the catalog models the queue,
/// so the sweep fails and crashes the queue writes too, and a crash image holds both stores at one moment.
/// - `fullScan`: the full scan with its snapshot and removal sweep (`run`).
/// - `changeScan`: the targeted scan of the changed photos (`run(identifiers:)`).
/// - `missingSources`: the recovery of the photos whose queue rows an earlier build dropped (`reconcileMissingSources`).
/// - `lateRenders`: the one-time pass that re-opens stored edits that list their rendered file
///   (`reconcileLateRendersOnce`).
/// - `lateRenderScan`: a targeted scan of asset-2, whose rendered file Photos lists only now with unchanged dates. Its
///   revision was backed up, so the scan re-opens it before it records the render (`run(identifiers:)`).
/// - `expiredHistory`: a pass whose change history expired (`runPass`). A third table holds the change token that the
///   pass moves once its snapshot is saved; it is no fault target, as the token lives outside the stores. A restart
///   whose token moved sees no expired history and must still finish the scan.
struct CatalogPassCase: StorageFaultCase {
    enum Pass: Sendable {
        case fullScan
        case changeScan([String])
        case missingSources
        case lateRenders
        case lateRenderScan
        case expiredHistory
    }

    struct World {
        let store: PhotoLibraryCatalogManifestStore
        let queueTable: StorageFaultTable
        let queue: RecordingEnqueuer
        let tokenTable: StorageFaultTable
    }

    let id: String
    let pass: Pass
    let atomicity = StorageFaultAtomicity.convergesAfterRestart

    /// The late-render pass and the late-render scan remove the settled queue row of a re-opened revision and then
    /// queue it again, as `UploadBackupSyncEngine.reopenBackedUpRevisions` and `enqueueBatch` do. When the second write
    /// fails (the only insert of the pass), the row is missing until a restart: the state stays pending, the render
    /// stays unrecorded or the pass owed, and the restart queues the revision again (I4 holds).
    var acceptsMissingReopenedRow = true

    var acceptances: [StorageFaultAcceptance] {
        switch pass {
        case .lateRenders, .lateRenderScan: break
        case .fullScan, .changeScan, .missingSources, .expiredHistory: return []
        }
        guard acceptsMissingReopenedRow else { return [] }
        let point = "INSERT OR IGNORE INTO item VALUES(?,?);"
        let reason =
            if case .lateRenderScan = pass {
                "the re-opened row is missing and the render stays unrecorded until the next scan re-opens and queues "
                    + "it again"
            } else {
                "the re-opened row is missing until the next pass queues it again; decision on #1155"
            }
        return [
            StorageFaultAcceptance(rule: .noLoss, phase: .failedRun, point: point, reason: reason),
            StorageFaultAcceptance(rule: .noLoss, phase: .crashImage, point: point, reason: reason),
        ]
    }
    private let libraries = catalogLibraries()
    private let lateRender = lateRenderLibrary()
    private static let queueName = "queue.sqlite"
    private static let tokenName = "token.sqlite"
    /// The token of the expired change history, and the token that the pass stores.
    private static let expiredToken = "expired"
    private static let currentToken = "current"

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        switch pass {
        case .fullScan, .changeScan, .missingSources, .expiredHistory, .lateRenderScan:
            try await sync(libraries.seed, at: 100, store: world.store).run(engine: world.queue)
        case .lateRenders:
            // An earlier build stored asset-2 with its rendered file listed next to the original.
            try await sync(libraries.current, at: 100, store: world.store).run(engine: world.queue)
        }
        switch pass {
        case .missingSources:
            // An earlier build dropped the queue rows of two photos that the catalog keeps.
            XCTAssertTrue(
                world.queueTable.execute("DELETE FROM item WHERE key LIKE 'asset-2#%' OR key LIKE 'asset-3#%';"))
        case .lateRenders, .lateRenderScan:
            // The earlier build finished the backup of every photo: its queue row is settled, and its state complete.
            let settled = RecordingEnqueuer.settled
            XCTAssertTrue(
                world.queueTable.execute(
                    "UPDATE item SET value='\(settled)'; "
                        + "INSERT INTO item SELECT '\(RecordingEnqueuer.statePrefix)' || key, '\(settled)' FROM item;"))
        case .expiredHistory:
            XCTAssertEqual(world.tokenTable.insertIfAbsent("token", value: Self.expiredToken), true)
        case .fullScan, .changeScan:
            break
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let queueTable = try StorageFaultTable(url: directory.appendingPathComponent(Self.queueName))
        return World(
            store: try catalogStore(in: directory), queueTable: queueTable,
            queue: RecordingEnqueuer(ledger: queueTable),
            tokenTable: try StorageFaultTable(url: directory.appendingPathComponent(Self.tokenName)))
    }

    func faultTargets(of world: World) -> [Any] { [world.store, world.queueTable] }

    func run(_ world: World) async -> Bool {
        do {
            switch pass {
            case .fullScan:
                try await sync(libraries.current, at: 200, store: world.store).run(engine: world.queue)
            case .changeScan(let identifiers):
                try await sync(libraries.current, at: 200, store: world.store).run(
                    engine: world.queue, identifiers: identifiers)
            case .missingSources:
                try await sync(libraries.seed, at: 200, store: world.store).reconcileMissingSources(engine: world.queue)
            case .lateRenders:
                try await sync(libraries.current, at: 200, store: world.store).reconcileLateRendersOnce(
                    engine: world.queue)
            case .lateRenderScan:
                try await sync(lateRender, at: 200, store: world.store).run(
                    engine: world.queue, identifiers: ["asset-2"])
            case .expiredHistory:
                let token = world.tokenTable
                let expired = try token.value(of: "token") == Self.expiredToken
                try await sync(libraries.current, at: 200, store: world.store).runPass(
                    engine: world.queue,
                    changes: .init(changedIdentifiers: [], deletedIdentifiers: [], requiresFullRescan: expired),
                    commitChanges: { _ = token.execute("UPDATE item SET value='\(Self.currentToken)';") })
            }
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {
        world.store.close()
        world.queueTable.close()
        world.tokenTable.close()
    }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = try catalogState(in: directory)
        let queue = directory.appendingPathComponent(Self.queueName)
        try state.addSQLiteTables(of: queue)
        // One record per photo revision, as `RecordingEnqueuer` keys the ledger; the modeled backup states are no queue
        // rows.
        try state.addRecords(
            "queued photo revision", of: queue,
            sql: "SELECT key FROM item WHERE substr(key, 1, \(RecordingEnqueuer.statePrefix.count)) "
                + "!= '\(RecordingEnqueuer.statePrefix)';")
        try state.addSQLiteTables(of: directory.appendingPathComponent(Self.tokenName))
        return state
    }

    private func sync(
        _ library: EditScenarioLibrary, at seconds: TimeInterval, store: PhotoLibraryCatalogManifestStore
    ) -> PhotoLibraryCatalogSync {
        PhotoLibraryCatalogSync(
            store: store, enumerator: library, chunkSize: 2, now: { Date(timeIntervalSince1970: seconds) })
    }
}

/// One change of the edit replacement journal (`EditReplacementJournalFileStore.addSuperseded`): one line appended to
/// its log through the durable file writer (#1149). With 1,000 seeded changes the run's change crosses the line limit,
/// and its compaction runs at once after the change, so its replacement is a point too. The state is the journal as a
/// new store reads it, so a log that a compaction or a restart rewrote compares by its entries, not by its lines.
struct EditReplacementJournalUpdateCase: StorageFaultCase {
    struct World {
        let journal: EditReplacementJournalFileStore
        let files: StorageFaultFiles
    }

    let id: String
    /// The changes before the run: one of the second photo, the others of the first.
    let seededChanges: Int
    let atomicity = StorageFaultAtomicity.allOrNothing
    private static let sources = ["asset-1", "asset-2"].map {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: $0)
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        try journal.recordUpload(edited: true, for: Self.sources[1])
        for index in 0..<(seededChanges - 1) {
            try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a\(index)"), for: Self.sources[0])
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(
            journal: try XCTUnwrap(
                EditReplacementJournalFileStore(
                    accountDataDirectory: directory, fileSystem: files, scheduleCompaction: { $0() })),
            files: files)
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    func run(_ world: World) async -> Bool {
        do {
            try world.journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: Self.sources[0])
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        guard let journal = EditReplacementJournalFileStore(accountDataDirectory: directory) else {
            state.tables["journal"] = ["unreadable"]
            return state
        }
        let entries = try Self.sources.map { source -> String in
            let entry = String(decoding: try JSONEncoder().encode(journal.entry(for: source)), as: UTF8.self)
            return "\(source.identifier): \(canonicalJSON(entry))"
        }
        state.tables["journal"] = entries
        state.records["superseded link"] = Set(
            Self.sources.flatMap { source in
                journal.entry(for: source).superseded.map { "\(source.identifier)#\($0.nodeID)" }
            })
        return state
    }
}

/// The first change of a new edit replacement journal: the log is created with its first line in one atomic
/// replacement, then the barrier for earlier builds is written. Two files, so a restart must complete what a crash
/// between them leaves. The state reads the barrier file before a new store opens the journal and places it.
///
/// Accepted (`acceptsIgnoredBarrierFailure`): today the journal ignores a failed barrier write after the first line, so
/// the change reports success without a barrier (I5 at that write); an earlier app build could read "no journal" until
/// the next launch places the barrier. Whether this should throw is an owner decision, kept open on #1149.
struct EditReplacementJournalCreateCase: StorageFaultCase {
    struct World {
        let journal: EditReplacementJournalFileStore
        let files: StorageFaultFiles
    }

    let id = "journal.editReplacement.create"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    /// False only in the self-test that shows the acceptance is needed.
    var acceptsIgnoredBarrierFailure = true
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1")

    var acceptances: [StorageFaultAcceptance] {
        guard acceptsIgnoredBarrierFailure else { return [] }
        return [
            StorageFaultAcceptance(
                rule: .honestOutcome, phase: .failedRun,
                point: "replace \(EditReplacementJournalFileStore.fileName)",
                reason: "A failed barrier write after the first line is ignored today; owner decision on #1149.")
        ]
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {}

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(
            journal: try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory, fileSystem: files)),
            files: files)
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    func run(_ world: World) async -> Bool {
        do {
            try world.journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: source)
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        let barrier = try? Data(contentsOf: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName))
        var state = StorageFaultState()
        state.tables["barrier"] = [
            barrier == nil
                ? "absent" : barrier == EditReplacementJournalFileStore.earlierBuildBarrier ? "barrier" : "other"
        ]
        guard let journal = EditReplacementJournalFileStore(accountDataDirectory: directory) else {
            state.tables["journal"] = ["unreadable"]
            return state
        }
        let entry = journal.entry(for: source)
        state.tables["journal"] = [canonicalJSON(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self))]
        state.records["superseded link"] = Set(entry.superseded.map(\.nodeID))
        return state
    }
}

/// One write of a per-photo journal through the file-system seam (#1149): `save` replaces the file of a photo whose
/// revert or series dissolution moves on, `remove` deletes the file of a finished one. Two photos have a journal before
/// the run. The state is every file of the journal directory with its content, compared by JSON content.
struct PhotoJournalCase: StorageFaultCase {
    enum Journal: Sendable {
        case revert
        case series
    }

    enum Step: Sendable {
        case save
        case remove
    }

    struct World {
        let directory: URL
        let files: StorageFaultFiles
    }

    let id: String
    let journal: Journal
    let step: Step
    let atomicity = StorageFaultAtomicity.allOrNothing
    private static let photos = ["first", "second"].map { PhotoUID(volumeID: "volume", nodeID: $0) }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        for photo in Self.photos {
            try save(photo, advanced: false, in: directory, fileSystem: LocalDurableFileSystem())
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        World(directory: directory, files: StorageFaultFiles())
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    func run(_ world: World) async -> Bool {
        do {
            switch step {
            case .save: try save(Self.photos[0], advanced: true, in: world.directory, fileSystem: world.files)
            case .remove: try remove(Self.photos[0], in: world.directory, fileSystem: world.files)
            }
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        let folder = directory.appendingPathComponent(
            journal == .revert
                ? EditedOriginalRevertJournalFileStore.directoryName : SeriesDissolutionJournalFileStore.directoryName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var state = StorageFaultState()
        state.tables["journal files"] = try names.sorted().map { name in
            let text = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
            return "\(name): \(canonicalJSON(text))"
        }
        state.records["journal file"] = Set(names)
        return state
    }

    private func save(
        _ photo: PhotoUID, advanced: Bool, in directory: URL, fileSystem: any DurableFileSystem
    ) throws {
        switch journal {
        case .revert:
            try EditedOriginalRevertJournalFileStore(accountDataDirectory: directory, fileSystem: fileSystem).save(
                EditedOriginalRevertJournal(
                    editedMainUID: photo, originalLinkID: "original", phase: advanced ? .trashingEdit : .copying))
        case .series:
            try SeriesDissolutionJournalFileStore(accountDataDirectory: directory, fileSystem: fileSystem).save(
                SeriesDissolutionJournal(
                    seriesMainUID: photo, seriesUIDs: [photo], favorites: [],
                    phase: advanced ? .trashingSeries : .copyingFavorites))
        }
    }

    private func remove(_ photo: PhotoUID, in directory: URL, fileSystem: any DurableFileSystem) throws {
        switch journal {
        case .revert:
            try EditedOriginalRevertJournalFileStore(accountDataDirectory: directory, fileSystem: fileSystem).remove(
                forEditedMain: photo)
        case .series:
            try SeriesDissolutionJournalFileStore(accountDataDirectory: directory, fileSystem: fileSystem).remove(
                forSeries: photo)
        }
    }
}

/// One change of the exact duplicate merge journal through the file-system seam (#1149): `record` replaces its file
/// with one more intent, `clear` removes the file with its last intent. The state is the file as JSON content, and the
/// keys of the intents that a new store reads.
struct ExactDuplicateMergeJournalCase: StorageFaultCase {
    enum Step: Sendable {
        case record
        case clear
    }

    struct World {
        let directory: URL
        let files: StorageFaultFiles
    }

    let id: String
    let step: Step
    let atomicity = StorageFaultAtomicity.allOrNothing

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let journal = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory)
        XCTAssertTrue(journal.record([Self.intent("kept")]))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        World(directory: directory, files: StorageFaultFiles())
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    func run(_ world: World) async -> Bool {
        let store = ExactDuplicateMergeJournalFileStore(accountDataDirectory: world.directory, fileSystem: world.files)
        switch step {
        case .record: return store.record([Self.intent("second")])
        case .clear: return store.clear([Self.intent("kept")])
        }
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        let file = directory.appendingPathComponent(ExactDuplicateMergeJournalFileStore.fileName)
        var state = StorageFaultState()
        state.tables["merge journal"] =
            FileManager.default.fileExists(atPath: file.path)
            ? [canonicalJSON(String(decoding: try Data(contentsOf: file), as: UTF8.self))] : ["absent"]
        let intents = ExactDuplicateMergeJournalFileStore(accountDataDirectory: directory).pendingMerges() ?? []
        state.records["merge intent"] = Set(intents.map(\.kept))
        return state
    }

    private static func intent(_ kept: String) -> ExactDuplicateMergeIntent {
        ExactDuplicateMergeIntent(
            volumeID: "volume", kept: kept, contentHash: "main-hash", hashKeyEpoch: "epoch",
            members: [.init(link: "duplicate-of-\(kept)", moves: [])], trashedAt: 1_720_000_000)
    }
}

/// One step of the device root enrollment journal through the file-system seam (#1149). Each step replaces the journal
/// file, then syncs the file and its directory. A failed sync throws after the replacement, so the failed step leaves
/// its record written, as the journal does today; a restart must reach the state of the fault-free run.
struct DeviceRootEnrollmentCase: StorageFaultCase {
    enum Step: Sendable {
        case beginCreate
        case markDispatchAttempted
        case finishCreate
    }

    struct World {
        let journal: DeviceRootEnrollmentFileJournal
        let files: StorageFaultFiles
    }

    let id: String
    let step: Step
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let identity = DeviceRootIdentity(deviceUID: "device", rootFolderUID: "folder", incarnation: "claim")

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let journal = DeviceRootEnrollmentFileJournal(accountDataDirectory: directory)
        switch step {
        case .beginCreate:
            break
        case .markDispatchAttempted:
            _ = try await journal.beginCreateIfAbsent(incarnation: "claim")
        case .finishCreate:
            _ = try await journal.beginCreateIfAbsent(incarnation: "claim")
            _ = try await journal.markCreateDispatchAttempted(location: .computer, incarnation: "claim")
            try await journal.recordCreatedDevice(.init(deviceUID: "device", rootFolderUID: "folder"))
            try await journal.select(Self.identity)
        }
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(
            journal: DeviceRootEnrollmentFileJournal(
                accountDataDirectory: directory, onBeforeFileLock: nil, fileSystem: files),
            files: files)
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    func run(_ world: World) async -> Bool {
        do {
            switch step {
            case .beginCreate: _ = try await world.journal.beginCreateIfAbsent(incarnation: "claim")
            case .markDispatchAttempted:
                _ = try await world.journal.markCreateDispatchAttempted(location: .computer, incarnation: "claim")
            case .finishCreate: try await world.journal.finishCreate()
            }
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        let file = directory.appendingPathComponent("device-root-enrollment.json")
        var state = StorageFaultState()
        var records: Set<String> = []
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            state.tables["device root journal"] = [canonicalJSON(String(decoding: data, as: UTF8.self))]
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let pending = record["pendingIncarnation"] as? String {
                records.insert("pending:\(pending)")
            }
            if let device = record["selectedDeviceUID"] as? String,
                let folder = record["selectedRootFolderUID"] as? String,
                let incarnation = record["selectedIncarnation"] as? String
            {
                let location = record["selectedLocation"] as? String ?? DeviceRootLocation.computer.rawValue
                records.insert("selected:\(location)#\(device)#\(folder)#\(incarnation)")
            }
        } else {
            state.tables["device root journal"] = ["absent"]
        }
        state.records["device root intent"] = records
        return state
    }
}

/// One transaction of the store under the exact duplicate details (`ExactDuplicateFingerprintStore`), each as
/// `ExactDuplicateFingerprintCache` runs it:
/// - `store`: the details of three photos saved under the cursor of the scan;
/// - `storeSizes`: the same with the file size of each photo, as the check of possibly identical photos saves them;
/// - `advance`: the persisted cursor recovered as after a launch, then moved on with the details of two photos dropped;
/// - `discontinuity`: the cursor of another key epoch, which drops every detail.
/// Every write of the context holds a new random generation, so the state reads the context without it, and the
/// details as text, because `JSONEncoder` writes their keys in no fixed order.
struct FingerprintCacheCase: StorageFaultCase {
    enum Step: Sendable {
        case store
        case storeSizes
        case advance
        case discontinuity
    }

    let id: String
    let step: Step
    let atomicity = StorageFaultAtomicity.allOrNothing
    private static let scope = ExactDuplicateFingerprintStore.Scope(
        accountID: "account", volumeID: "volume", hashKeyEpoch: "epoch-1")

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let store = try open(directory, remote: remote)
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: Self.scope, eventID: "event-1"))
        if case .store = step { return }
        if case .storeSizes = step { return }
        XCTAssertTrue(store.store(Self.details(of: ["a", "b", "c"]), for: snapshot))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> ExactDuplicateFingerprintStore {
        try XCTUnwrap(
            ExactDuplicateFingerprintStore(
                url: directory.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName),
                cacheDirectory: directory))
    }

    func faultTargets(of world: ExactDuplicateFingerprintStore) -> [Any] { [world] }

    func run(_ store: ExactDuplicateFingerprintStore) async -> Bool {
        switch step {
        case .store:
            guard let snapshot = store.prepare(scope: Self.scope, eventID: "event-1") else { return false }
            return store.store(Self.details(of: ["a", "b", "c"]), for: snapshot)
        case .storeSizes:
            guard let snapshot = store.prepare(scope: Self.scope, eventID: "event-1") else { return false }
            let sizes = Dictionary(
                uniqueKeysWithValues: ["a", "b", "c"].enumerated().map {
                    (PhotoUID(volumeID: "volume", nodeID: $1), Int64($0 + 1) * 1_000)
                })
            return store.store(Self.details(of: ["a", "b", "c"]), byteSizes: sizes, for: snapshot)
        case .advance:
            guard let snapshot = store.prepare(scope: Self.scope, eventID: "event-1") else { return false }
            return store.advance(from: snapshot, to: "event-2", invalidating: ["a", "b"]) != nil
        case .discontinuity:
            let epoch = ExactDuplicateFingerprintStore.Scope(
                accountID: "account", volumeID: "volume", hashKeyEpoch: "epoch-2")
            return store.prepare(scope: epoch, eventID: "event-2") != nil
        }
    }

    func close(_ world: ExactDuplicateFingerprintStore) { world.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        let url = directory.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName)
        var state = StorageFaultState()
        try state.addSQLiteTables(of: url)
        try state.setSQLiteRows(
            of: "fingerprint", in: url, sql: "SELECT link_id, CAST(payload AS TEXT) FROM fingerprint;")
        try state.setSQLiteRows(
            of: "fingerprint_context", in: url,
            sql: "SELECT json_remove(CAST(payload AS TEXT), '$.generation') FROM fingerprint_context;")
        return state
    }

    private static func details(of nodes: [String]) -> [PhotoUID: ExactDuplicateFingerprint] {
        Dictionary(
            uniqueKeysWithValues: nodes.map {
                (
                    PhotoUID(volumeID: "volume", nodeID: $0),
                    ExactDuplicateFingerprint(
                        captureTime: Date(timeIntervalSince1970: 1_700_000_000), device: "camera-\($0)",
                        pixelWidth: 100, pixelHeight: 100)
                )
            })
    }
}

/// One transaction of the journal that restores the frames of a trashed series (`TrashedSeriesRestoreJournal`):
/// - `record`: one duty replaced, a new one added, and the duty of a main photo that was trashed again dropped;
/// - `update`: a response that settled one of the two frames of a duty;
/// - `finish`: a response that settled the last frame of a duty, which removes the duty.
struct TrashedSeriesRestoreCase: StorageFaultCase {
    enum Step: Sendable {
        case record
        case update
        case finish
    }

    let id: String
    let step: Step
    let atomicity = StorageFaultAtomicity.allOrNothing

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let journal = try open(directory, remote: remote)
        defer { journal.close() }
        try journal.record([Self.duty(1, frames: ["f1", "f2"]), Self.duty(2, frames: ["f3"])])
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> TrashedSeriesRestoreJournal {
        try XCTUnwrap(
            TrashedSeriesRestoreJournal(url: directory.appendingPathComponent(TrashedSeriesRestoreJournal.fileName)))
    }

    func faultTargets(of world: TrashedSeriesRestoreJournal) -> [Any] { [world] }

    func run(_ journal: TrashedSeriesRestoreJournal) async -> Bool {
        do {
            switch step {
            case .record:
                var later = Self.duty(1, frames: ["f1", "f2"])
                later.attempts = 1
                try journal.record(
                    [later, Self.duty(3, frames: ["f4"])],
                    mainTrashTimes: [PhotoUID(volumeID: "volume", nodeID: "main-2"): 2_000])
            case .update:
                try journal.update(Self.duty(1, frames: ["f2"]))
            case .finish:
                try journal.update(Self.duty(2, frames: []))
            }
            return true
        } catch {
            return false
        }
    }

    func close(_ world: TrashedSeriesRestoreJournal) { world.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        let url = directory.appendingPathComponent(TrashedSeriesRestoreJournal.fileName)
        var state = StorageFaultState()
        try state.addSQLiteTables(of: url)
        // The payload is the JSON of the duty; compared as text, because `JSONEncoder` writes keys in no fixed order.
        try state.setSQLiteRows(
            of: "restore_duties", in: url,
            sql: "SELECT volume, main, generation, CAST(payload AS TEXT) FROM restore_duties;")
        return state
    }

    /// The duty of main photo `index`, with a fixed generation, so two runs write the same rows.
    private static func duty(_ index: Int, frames: [String]) -> TrashedSeriesRestoreRecord {
        let main = "main-\(index)"
        return TrashedSeriesRestoreRecord(
            generation: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
            main: PhotoUID(volumeID: "volume", nodeID: main), mainTrashTime: 1_000,
            frames: frames.map {
                .init(uid: PhotoUID(volumeID: "volume", nodeID: $0), mainPhotoLinkID: main, trashTime: 1_001)
            },
            retryAt: Date(timeIntervalSince1970: 100))
    }
}

/// One transaction of the rebuildable list of photos whose local read failed (`BackupLocalReadFailureHintStore`), as the
/// backup runner runs it:
/// - `insert`: a new hint in a full list, which drops the oldest hint;
/// - `remove`: the hints of two photos whose work is done;
/// - `saveSweepCursor`: the position of the next sweep page.
struct LocalReadFailureHintCase: StorageFaultCase {
    enum Step: Sendable {
        case insert
        case remove
        case saveSweepCursor
    }

    let id: String
    let step: Step
    let atomicity = StorageFaultAtomicity.allOrNothing
    /// Small enough that the seeded list is full, so the insert also drops a hint.
    private static let capacity = 2

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let store = try open(directory, remote: remote)
        defer { store.close() }
        XCTAssertTrue(store.insert(photoLibrarySource("a")))
        XCTAssertTrue(store.insert(photoLibrarySource("b")))
        XCTAssertTrue(store.saveSweepCursor(1))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> BackupLocalReadFailureHintStore {
        try XCTUnwrap(
            BackupLocalReadFailureHintStore(
                url: directory.appendingPathComponent(BackupLocalReadFailureHintStore.databaseFileName),
                capacity: Self.capacity))
    }

    func faultTargets(of world: BackupLocalReadFailureHintStore) -> [Any] { [world] }

    func run(_ store: BackupLocalReadFailureHintStore) async -> Bool {
        switch step {
        case .insert: store.insert(photoLibrarySource("c"))
        case .remove: store.remove([photoLibrarySource("a"), photoLibrarySource("b")])
        case .saveSweepCursor: store.saveSweepCursor(2)
        }
    }

    func close(_ world: BackupLocalReadFailureHintStore) { world.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        let url = directory.appendingPathComponent(BackupLocalReadFailureHintStore.databaseFileName)
        var state = StorageFaultState()
        try state.addSQLiteTables(of: url)
        try state.addRecords(
            "local read failure hint", of: url,
            sql: "SELECT source_kind || '/' || source_id FROM local_read_failure_hint;")
        return state
    }
}

/// Album Sync's refusal rounds (#884), in the order of one album run after its queue reset: the scan, the carry onto
/// the album queue, the run, and the write-back into the refusal file through the file-system seam. The scan and the run
/// write through a second store object on the same queue file, which is no fault target: they stand for the runner,
/// which has its own sweep case. The scan leaves a photo that Proton refused until the backup stopped, a photo that
/// Proton refuses in this run, and a photo that ended backed up. The run refuses every photo that still waits. The file
/// holds the stopped photo, the backed-up photo and a photo of another album. The file is a cache: losing a write loses
/// only rounds, and the next run writes it again.
struct AlbumSyncRefusalWriteBackCase: StorageFaultCase {
    struct World {
        let directory: URL
        let queue: UploadBackupSyncQueueManifestStore
        let files: StorageFaultFiles
        let executor: PhotoAlbumBackupExecutor
    }

    let id = "albumSync.refusals.writeBack"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let build = "7"
    private static let revision = UploadBackupRevision(rawValue: 1_700_000_000_000_000)
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let photos = ["stopped", "refused", "backed-up"]

    private static func queueURL(in directory: URL) -> URL {
        directory.appendingPathComponent(PhotoAlbumBackupExecutor.queueDatabaseFileName)
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: Self.queueURL(in: directory)))
        defer { queue.close() }
        for (identifier, state) in [
            ("stopped", UploadBackupSyncQueueState.discovered), ("refused", .discovered), ("backed-up", .completed),
        ] {
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: photoLibrarySource(identifier), revision: Self.revision,
                        originalFilename: "\(identifier).heic", byteCount: 4, state: state, attempts: 0,
                        updatedAt: Self.date)))
        }
        let stopped = serviceRefusalRecord(
            rounds: 3, firstRoundAt: Self.date.addingTimeInterval(-80 * 3600), lastRoundAt: Self.date)
        try AlbumSyncRefusalStore(accountDataDirectory: directory).replace(
            with: ["another-album", "backed-up", "stopped"].map {
                .init(
                    source: photoLibrarySource($0), revision: Self.revision, lastError: stopped,
                    roundBuild: Self.build)
            })
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(
            directory: directory,
            queue: try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: Self.queueURL(in: directory))),
            files: files,
            executor: PhotoAlbumBackupExecutor(
                accountDataDirectory: directory, databasePolicy: .conservative,
                identityResolver: FakeIdentityResolver(), uploader: MockUploader(),
                resourceResolver: ScriptedBackupResolver(defaultModified: Self.date), appBuild: Self.build,
                refusalFileSystem: files, log: BackgroundWorkLog { _, _ in }))
    }

    func faultTargets(of world: World) -> [Any] { [world.queue, world.files] }

    func run(_ world: World) async -> Bool {
        guard let runner = UploadBackupSyncQueueManifestStore(url: Self.queueURL(in: world.directory)) else {
            return false
        }
        defer { runner.close() }
        // The scan of a reset queue: the two photos wait for their upload again.
        for identifier in ["stopped", "refused"] {
            guard
                runner.updateState(
                    source: photoLibrarySource(identifier), revision: Self.revision, state: .discovered, attempts: 0,
                    lastError: nil, updatedAt: Self.date)
            else { return false }
        }
        let refusals = AlbumSyncRefusalStore(accountDataDirectory: world.directory).read()
        let carry = world.executor.carry(refusals, into: world.queue)
        // The run: Proton refuses every photo that still waits, as a first round.
        let firstRound = serviceRefusalRecord(rounds: 1, firstRoundAt: Self.date, lastRoundAt: Self.date)
        for identifier in ["stopped", "refused"] {
            let lookup: StoreLookup<UploadBackupSyncQueueEntry>
            do {
                lookup = try runner.decisionEntry(for: photoLibrarySource(identifier), revision: Self.revision)
            } catch {
                return false
            }
            guard case .found(let row) = lookup else { return false }
            guard row.state == .discovered else { continue }
            guard
                runner.updateState(
                    source: row.source, revision: row.revision, state: .failed, attempts: 8, lastError: firstRound,
                    updatedAt: Self.date)
            else { return false }
        }
        let saved = world.executor.writeBack(
            refusals, carry: carry, from: world.queue, localIdentifiers: Self.photos)
        return carry.isComplete && saved
    }

    func close(_ world: World) { world.queue.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        try state.addSQLiteTables(of: Self.queueURL(in: directory))
        switch AlbumSyncRefusalStore(accountDataDirectory: directory).read() {
        case .found(let entries):
            // The stored record is encoded JSON in no fixed key order; `canonicalJSON` compares it by content.
            state.tables["refusals"] = entries.map {
                "\($0.source.identifier)#\($0.revision.rawValue) build=\($0.roundBuild ?? "none") "
                    + canonicalJSON($0.lastError)
            }.sorted()
            state.records["refusal entry"] = Set(entries.map { $0.source.identifier })
        case .absent: state.tables["refusals"] = ["absent"]
        case .unknown(let replaceable): state.tables["refusals"] = ["unknown replaceable=\(replaceable)"]
        }
        return state
    }
}

/// The runner's persistence of one synced album (`AlbumSyncRunner.sync`): it reads the stored mapping row, moves the
/// synced-at time and the run's counts onto it, and writes the row back with one upsert. The mapping store is
/// authoritative, not a rebuildable cache: a lost mapping sends the next sync through the name-conflict flow again.
/// A faulted read (point 1) still reports success: the fresh-mapping fallback writes the row, and the state converges
/// exactly, because the conflict clause never updates `created_at` and every other written field takes the same
/// value. A faulted upsert (point 2) fails and leaves the row unchanged; the next sync's read-plus-upsert writes the
/// row again (converging restart). A maintainer who adds a conflict-updated field that differs between the stored and
/// the fresh mapping (for example a fresh `createdAt`) turns point 1 into an honest-outcome failure on purpose: the
/// sweep then demands a real refusal or an unchanged convergence.
struct AlbumSyncMappingUpsertCase: StorageFaultCase {
    struct World {
        let url: URL
        let store: AlbumSyncMappingStore
    }

    let id = "albumSync.mapping.upsert"
    let atomicity = StorageFaultAtomicity.allOrNothing
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let localID = "album-trip"
    private static let remoteID = "remote-trip"

    private static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let store = try XCTUnwrap(AlbumSyncMappingStore(url: Self.url(in: directory)))
        defer { store.close() }
        XCTAssertTrue(
            store.upsert(
                AlbumSyncMapping(
                    localAlbumID: Self.localID, remoteAlbumID: Self.remoteID, title: "Trip", mode: .additive,
                    createdAt: Self.date, lastSyncedAt: Self.date.addingTimeInterval(-3_600),
                    lastAttachedCount: 2, lastFailedCount: 1)))
        XCTAssertTrue(
            store.addSelection(
                AlbumSyncSelection(localAlbumID: Self.localID, title: "Trip", addedAt: Self.date)))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        World(
            url: Self.url(in: directory),
            store: try XCTUnwrap(AlbumSyncMappingStore(url: Self.url(in: directory))))
    }

    func faultTargets(of world: World) -> [Any] { [world.store] }

    func run(_ world: World) async -> Bool {
        // The runner's own shape: the stored row, or a fresh mapping when none answers, then one upsert.
        var mapping =
            world.store.mapping(localAlbumID: Self.localID)
            ?? AlbumSyncMapping(
                localAlbumID: Self.localID, remoteAlbumID: Self.remoteID, title: "Trip",
                createdAt: Self.date)
        mapping.title = "Trip"
        mapping.lastSyncedAt = Self.date
        mapping.lastAttachedCount = 5
        mapping.lastFailedCount = 0
        return world.store.upsert(mapping)
    }

    func close(_ world: World) { world.store.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        try state.addSQLiteTables(of: Self.url(in: directory))
        try state.addRecords(
            "mapping", of: Self.url(in: directory), sql: "SELECT local_album_id FROM album_sync_mapping;")
        try state.addRecords(
            "selection", of: Self.url(in: directory), sql: "SELECT local_album_id FROM album_sync_selection;")
        return state
    }
}

/// The controller's application of one picker result (`AlbumSyncController.applySelection`): the availability probe,
/// then one `addSelection` per added album, then one `removeSelection` per deselected album — and, exactly as
/// production, a failed add breaks only the adds loop, so the removals still run. Deselecting keeps the mapping row,
/// so a later re-selection reuses the same Proton album without a name-conflict round. The writes are separate
/// transactions: a fault between them leaves a partially applied selection, and applying the picker again completes it
/// (both writes are idempotent), so the restart converges. A faulted probe stops every write: the controller reports
/// the store unavailable, which is the fail-closed answer the store documents.
struct AlbumSyncSelectionWriteCase: StorageFaultCase {
    struct World {
        let url: URL
        let store: AlbumSyncMappingStore
    }

    let id = "albumSync.selections.write"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let deselected = "album-trip"
    private static let added = "album-sun"

    private static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let store = try XCTUnwrap(AlbumSyncMappingStore(url: Self.url(in: directory)))
        defer { store.close() }
        XCTAssertTrue(
            store.upsert(
                AlbumSyncMapping(
                    localAlbumID: Self.deselected, remoteAlbumID: "remote-trip", title: "Trip",
                    createdAt: Self.date)))
        XCTAssertTrue(
            store.addSelection(
                AlbumSyncSelection(localAlbumID: Self.deselected, title: "Trip", addedAt: Self.date)))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        World(
            url: Self.url(in: directory),
            store: try XCTUnwrap(AlbumSyncMappingStore(url: Self.url(in: directory))))
    }

    func faultTargets(of world: World) -> [Any] { [world.store] }

    func run(_ world: World) async -> Bool {
        guard world.store.isOperational() else { return false }
        var added = true
        let selection =
            AlbumSyncSelection(localAlbumID: Self.added, title: "Sunny", addedAt: Self.date)
        if !world.store.addSelection(selection) {
            added = false
            // Production keeps going after a failed add: `applySelection` breaks only the adds loop.
        }
        if !world.store.removeSelection(localAlbumID: Self.deselected) {
            return false
        }
        return added
    }

    func close(_ world: World) { world.store.close() }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        try state.addSQLiteTables(of: Self.url(in: directory))
        try state.addRecords(
            "mapping", of: Self.url(in: directory), sql: "SELECT local_album_id FROM album_sync_mapping;")
        try state.addRecords(
            "selection", of: Self.url(in: directory), sql: "SELECT local_album_id FROM album_sync_selection;")
        return state
    }
}

/// The last finished run's per-photo list file (`album-sync-last-run-v1.json`): after each finished sync the runner
/// rewrites one album's list through the last-run store. The file is a rebuildable cache: a missing, unreadable or
/// failed file keeps the previous lists, and the next finished run writes again. The case drives the store's file
/// actor (`AlbumSyncLastRunFile.write`) through the `DurableFileSystem` seam (#1149); the store's `record`/`load`
/// gating above the file is covered by the last-run store's own tests. The one acceptance is the honest-outcome
/// violation of the write: the write tolerates its own failure on purpose, so the operation reports success while
/// the file keeps the previous lists until the next finished run rewrites them (#1155).
struct AlbumSyncLastRunWriteCase: StorageFaultCase {
    struct World {
        let files: StorageFaultFiles
        let file: AlbumSyncLastRunFile
    }

    let id = "albumSync.lastRun.write"
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    /// `AlbumSyncLastRunStore.fileName`; the store's own constant is main-actor isolated, so the case keeps its
    /// own copy of the stable name.
    private static let fileName = "album-sync-last-run-v1.json"

    private static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.fileName)
    }

    private static func item(_ identifier: String, reason: String) -> BackupFailedItem {
        BackupFailedItem(
            id: "album/\(identifier)", filename: "\(identifier).heic", reason: reason, isPermanent: false,
            isRetryable: true,
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier),
            category: .userResolvable)
    }

    private static var seededLists: [String: [BackupFailedItem]] {
        ["album-trip": [item("asset-1", reason: "Not backed up.")]]
    }

    /// The finished run that this case writes: one album's changed list plus a newly finished album's list.
    private static var writtenLists: [String: [BackupFailedItem]] {
        [
            "album-trip": [item("asset-1", reason: "Not backed up."), item("asset-2", reason: "Too large.")],
            "album-sun": [item("asset-3", reason: "Not backed up.")],
        ]
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        await AlbumSyncLastRunFile(url: Self.url(in: directory)).write(Self.seededLists)
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let files = StorageFaultFiles()
        return World(files: files, file: AlbumSyncLastRunFile(url: Self.url(in: directory), fileSystem: files))
    }

    func faultTargets(of world: World) -> [Any] { [world.files] }

    /// True: a failed write is tolerated on purpose; the case reports the violation through its acceptance.
    func run(_ world: World) async -> Bool {
        await world.file.write(Self.writtenLists)
        return true
    }

    func close(_ world: World) {}

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        state.tables["last-run"] = try Self.readLists(at: Self.url(in: directory))
        state.records["last-run album"] = Set(try Self.readRawLists(at: Self.url(in: directory)).keys)
        return state
    }

    /// The stored rows of one state, decoded and canonicalized by the test; `JSONEncoder` writes keys in no fixed
    /// order, so the file itself does not compare byte-wise.
    private static func readLists(at url: URL) throws -> [String] {
        let lists = try readRawLists(at: url)
        let rendered: [String] = lists.map { album, items in
            let rows = items.map { item in
                "\(item.id)#\(item.filename)#\(item.reason)#\(item.isPermanent)#\(item.isRetryable)#"
                    + "\(item.category ?? "-")"
            }.sorted().joined(separator: "|")
            return album + ": " + rows
        }
        return rendered.sorted()
    }

    private static func readRawLists(at url: URL) throws -> [String: [StoredLastRunItem]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try JSONDecoder().decode([String: [StoredLastRunItem]].self, from: data)
    }

    /// The read side of the state comparison; a missing or unreadable file reads as an empty state, as the store
    /// itself reads it.
    private struct StoredLastRunItem: Codable {
        let id: String
        let filename: String
        let reason: String
        let category: String?
        let isPermanent: Bool
        let isRetryable: Bool
    }

    var acceptances: [StorageFaultAcceptance] {
        [
            StorageFaultAcceptance(
                rule: .honestOutcome, phase: .failedRun,
                point: "replace album-sync-last-run-v1.json",
                reason:
                    "a failed write keeps the previous lists on purpose; the file is a rebuildable cache and the "
                    + "next finished run writes again (#1155)")
        ]
    }
}
