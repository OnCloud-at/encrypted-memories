import Foundation
import PhotosCore
import XCTest

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
    CatalogPassCase(id: "catalog.expiredHistory", pass: .expiredHistory),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.update", seededChanges: 2),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.compact", seededChanges: 1_000),
    EditReplacementJournalCreateCase(),
    PhotoJournalCase(id: "journal.revert.save", journal: .revert, step: .save),
    PhotoJournalCase(id: "journal.revert.remove", journal: .revert, step: .remove),
    PhotoJournalCase(id: "journal.series.save", journal: .series, step: .save),
    PhotoJournalCase(id: "journal.series.remove", journal: .series, step: .remove),
    DeletionDecisionCase(keepDeleted: true, startsWithIntent: false),
    DeletionDecisionCase(keepDeleted: false, startsWithIntent: false),
    DeletionDecisionCase(keepDeleted: true, startsWithIntent: true),
    DeletionDecisionCase(keepDeleted: false, startsWithIntent: true),
    FingerprintCacheCase(id: "fingerprints.store", step: .store),
    FingerprintCacheCase(id: "fingerprints.advance", step: .advance),
    FingerprintCacheCase(id: "fingerprints.discontinuity", step: .discontinuity),
    TrashedSeriesRestoreCase(id: "trashedSeries.record", step: .record),
    TrashedSeriesRestoreCase(id: "trashedSeries.update", step: .update),
]

/// A deletion decision followed by launch replay, or launch replay of an already recorded intent. Both call the
/// production operation on the real queue and journal. The second replay also settles a best-effort settle that
/// failed after the queue committed. The separate unit test pins that retained intent before the next launch.
struct DeletionDecisionCase: StorageFaultCase {
    struct World {
        let queue: UploadBackupSyncQueueManifestStore
        let journal: EditReplacementJournalFileStore
        let files: StorageFaultFiles
    }
    let keepDeleted: Bool
    let startsWithIntent: Bool
    var id: String {
        "backup.\(startsWithIntent ? "replayRemoteDeletion" : "resolveRemoteDeletion").\(keepDeleted ? "keep" : "backUpAgain")"
    }
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
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
        if startsWithIntent {
            try world.journal.recordDeletionDecision(
                keepDeleted ? .keptDeleted : .backUpAgain(revisions[1]),
                revisions: revisions, for: source)
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
        guard await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: date) else {
            return false
        }
        do {
            let row = try world.queue.entry(for: source, revision: revisions[1])
            if row?.state == .failedPermanent {
                try await DeletionDecisionReplay.record(
                    keepDeleted ? .keptDeleted : .backUpAgain(revisions[1]),
                    revisions: revisions, for: source, queue: world.queue, journal: world.journal, at: date)
            }
            return await DeletionDecisionReplay.run(queue: world.queue, journal: world.journal, at: date)
        } catch { return false }
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
/// - `expiredHistory`: a pass whose change history expired (`runPass`). A third table holds the change token that the
///   pass moves once its snapshot is saved; it is no fault target, as the token lives outside the stores. A restart
///   whose token moved sees no expired history and must still finish the scan.
struct CatalogPassCase: StorageFaultCase {
    enum Pass: Sendable {
        case fullScan
        case changeScan([String])
        case missingSources
        case lateRenders
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

    /// The late-render pass removes the settled queue row of a re-opened revision and then queues it again, as
    /// `UploadBackupSyncEngine.reopenBackedUpRevisions` and `enqueueBatch` do. When the second write fails (the only
    /// insert of the pass), the row is missing until a restart: the state stays pending, the pass stays owed, and the
    /// restart queues the revision again (I4 holds).
    var acceptsMissingReopenedRow = true

    var acceptances: [StorageFaultAcceptance] {
        guard case .lateRenders = pass, acceptsMissingReopenedRow else { return [] }
        let point = "INSERT OR IGNORE INTO item VALUES(?,?);"
        let reason = "the re-opened row is missing until the next pass queues it again; decision on #1155"
        return [
            StorageFaultAcceptance(rule: .noLoss, phase: .failedRun, point: point, reason: reason),
            StorageFaultAcceptance(rule: .noLoss, phase: .crashImage, point: point, reason: reason),
        ]
    }
    private let libraries = catalogLibraries()
    private static let queueName = "queue.sqlite"
    private static let tokenName = "token.sqlite"
    /// The token of the expired change history, and the token that the pass stores.
    private static let expiredToken = "expired"
    private static let currentToken = "current"

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        switch pass {
        case .fullScan, .changeScan, .missingSources, .expiredHistory:
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
        case .lateRenders:
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

/// One transaction of the store under the exact duplicate details (`ExactDuplicateFingerprintStore`), each as
/// `ExactDuplicateFingerprintCache` runs it:
/// - `store`: the details of three photos saved under the cursor of the scan;
/// - `advance`: the persisted cursor recovered as after a launch, then moved on with the details of two photos dropped;
/// - `discontinuity`: the cursor of another key epoch, which drops every detail.
/// Every write of the context holds a new random generation, so the state reads the context without it, and the
/// details as text, because `JSONEncoder` writes their keys in no fixed order.
struct FingerprintCacheCase: StorageFaultCase {
    enum Step: Sendable {
        case store
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
/// - `update`: a response that settled one of the two frames of a duty.
struct TrashedSeriesRestoreCase: StorageFaultCase {
    enum Step: Sendable {
        case record
        case update
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
