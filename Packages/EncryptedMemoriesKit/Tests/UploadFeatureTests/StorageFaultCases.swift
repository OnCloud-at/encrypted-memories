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
