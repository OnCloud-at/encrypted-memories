import Foundation
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Every storage-changing operation in the fault-injection sweep (#1141). Add a new operation here once; the sweep
/// covers it from then on.
let storageFaultCases: [any StorageFaultCase] = [
    CatalogUpsertBatchCase(),
    CatalogScanCase(id: "catalog.fullScan", identifiers: nil),
    CatalogScanCase(id: "catalog.changeScan", identifiers: ["asset-2", "asset-3", "asset-4"]),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.update", seededChanges: 2),
    EditReplacementJournalUpdateCase(id: "journal.editReplacement.compact", seededChanges: 1_000),
    EditReplacementJournalCreateCase(),
    PhotoJournalCase(id: "journal.revert.save", journal: .revert, step: .save),
    PhotoJournalCase(id: "journal.revert.remove", journal: .revert, step: .remove),
    PhotoJournalCase(id: "journal.series.save", journal: .series, step: .save),
    PhotoJournalCase(id: "journal.series.remove", journal: .series, step: .remove),
]

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

/// A catalog scan (`PhotoLibraryCatalogSync.run`) over several chunks: the full scan with its snapshot and removal
/// sweep when `identifiers` is nil, otherwise the targeted scan of the changed photos. A table next to the catalog
/// models the queue, so the sweep fails and crashes the queue writes too, and a crash image holds both stores at one
/// moment.
struct CatalogScanCase: StorageFaultCase {
    struct World {
        let store: PhotoLibraryCatalogManifestStore
        let queueTable: StorageFaultTable
        let queue: RecordingEnqueuer
    }

    let id: String
    let identifiers: [String]?
    let atomicity = StorageFaultAtomicity.convergesAfterRestart
    private let libraries = catalogLibraries()
    private static let queueName = "queue.sqlite"

    init(id: String, identifiers: [String]?) {
        self.id = id
        self.identifiers = identifiers
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        try await sync(libraries.seed, at: 100, store: world.store).run(engine: world.queue)
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let queueTable = try StorageFaultTable(url: directory.appendingPathComponent(Self.queueName))
        return World(
            store: try catalogStore(in: directory), queueTable: queueTable, queue: RecordingEnqueuer(ledger: queueTable)
        )
    }

    func faultTargets(of world: World) -> [Any] { [world.store, world.queueTable] }

    func run(_ world: World) async -> Bool {
        do {
            try await sync(libraries.current, at: 200, store: world.store).run(
                engine: world.queue, identifiers: identifiers)
            return true
        } catch {
            return false
        }
    }

    func close(_ world: World) {
        world.store.close()
        world.queueTable.close()
    }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = try catalogState(in: directory)
        let queue = directory.appendingPathComponent(Self.queueName)
        try state.addSQLiteTables(of: queue)
        // One record per photo revision, as `RecordingEnqueuer` keys the ledger.
        try state.addRecords("queued photo revision", of: queue, sql: "SELECT key FROM item;")
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
