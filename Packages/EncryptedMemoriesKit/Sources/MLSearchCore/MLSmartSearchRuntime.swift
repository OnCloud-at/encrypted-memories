import Foundation
import PhotosCore

/// One atomic view of the host's library identities.
///
/// `isAuthoritative` distinguishes a genuinely empty library from the transient empty state while
/// a persisted/server timeline is still hydrating. Destructive index reconciliation may only use
/// authoritative snapshots.
public struct MLAssetInventorySnapshot: Sendable, Equatable {
    public let uids: [PhotoUID]
    public let isAuthoritative: Bool

    public init(uids: [PhotoUID], isAuthoritative: Bool) {
        self.uids = uids
        self.isAuthoritative = isAuthoritative
    }

    public static let hydrating = MLAssetInventorySnapshot(uids: [], isAuthoritative: false)

    public static func authoritative(_ uids: [PhotoUID]) -> MLAssetInventorySnapshot {
        MLAssetInventorySnapshot(uids: uids, isAuthoritative: true)
    }
}

/// Current library identities, published by a host when its complete timeline changes.
/// Index retries read the copy-on-write snapshot without hopping to a UI actor.
public final class MLAssetUniverse: @unchecked Sendable {
    private let lock = NSLock()
    private var inventory: MLAssetInventorySnapshot

    public init() {
        inventory = .hydrating
    }

    public init(authoritative uids: [PhotoUID]) {
        inventory = .authoritative(uids)
    }

    /// Marks a new host/session hydration boundary. This never publishes an authoritative empty
    /// library and therefore cannot trigger destructive reconciliation.
    public func beginHydration() {
        lock.withLock { inventory = .hydrating }
    }

    /// Publishes one complete inventory. Repeating the same snapshot is a no-op so duplicate host
    /// notifications cannot create another indexing generation.
    @discardableResult
    public func publishAuthoritative(_ uids: [PhotoUID]) -> Bool {
        lock.withLock {
            let next = MLAssetInventorySnapshot.authoritative(uids)
            guard inventory != next else { return false }
            inventory = next
            return true
        }
    }

    public func snapshot() -> MLAssetInventorySnapshot {
        lock.withLock { inventory }
    }
}

/// One live inference+index session bound to exactly one installed model epoch.
///
/// `MLSearchService` is the canonical implementation; tests inject fakes. A session owns its
/// model residency: `shutdown()` must release every model and cached vector block so a switch
/// or purge can never leak the previous epoch's memory.
public protocol MLSmartSearchSession: Sendable {
    var descriptor: MLModelDescriptor { get }
    func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome
    func indexQuantum(
        _ assets: [PhotoUID],
        maximumAssets: Int,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome
    func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome
    func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome
    func permanentlyUnavailableAssetUIDs(_ assets: [PhotoUID]) async -> Set<PhotoUID>
    func search(_ text: String, limit: Int) async throws -> MLSearchResults
    func releaseMemory() async
    func shutdown() async
}

public extension MLSmartSearchSession {
    func indexQuantum(
        _ assets: [PhotoUID],
        maximumAssets: Int,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        await index(assets, observer: observer)
    }

    func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        await indexQuantum(
            assets,
            maximumAssets: maximumAssets,
            observer: observer
        )
    }

    func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        guard shouldContinue() else {
            return MLIndexPassOutcome(
                report: MLIndexBatchReport(),
                ranToCompletion: false,
                newPermanentFailures: [],
                progress: MLIndexProgress(
                    phase: .idle,
                    descriptor: descriptor,
                    totalAssets: assets.count
                )
            )
        }
        return await indexQuantum(
            assets,
            libraryGeneration: libraryGeneration,
            maximumAssets: maximumAssets,
            observer: observer
        )
    }

    func permanentlyUnavailableAssetUIDs(_ assets: [PhotoUID]) async -> Set<PhotoUID> { [] }
}

/// Builds a runtime session for a verified installation. The Apple adapter compiles/loads the
/// CoreML package here (ANE-first compute policy); Core never sees CoreML.
public protocol MLSmartSearchRuntimeProvider: Sendable {
    /// May perform expensive one-time preparation (model compilation). Must throw rather than
    /// return a session whose encoder does not match `model.entry.descriptor`.
    ///
    /// - Parameters:
    ///   - shouldContinueIndexing: consulted at asset boundaries; indexing passes stop promptly
    ///     (after the current durable chunk) when it returns `false`.
    func makeSession(
        model: MLInstalledModel,
        store: any MLIndexStore,
        shouldContinueIndexing: @escaping @Sendable () -> Bool
    ) async throws -> any MLSmartSearchSession
}

/// Owns the persistent index store handle so the lifecycle can close it before purging files.
public protocol MLIndexStoreProvider: Sendable {
    /// Open (or return the already-open) store. Idempotent.
    func openStore() -> (any MLIndexStore)?
    /// Close the underlying handle so database files can be deleted safely.
    func closeStore()
}

/// Host-injected scheduling gate for background indexing. Capability-based: the platform maps
/// thermal state, low power, visible thumbnail demand and lifecycle phase into one answer.
public protocol MLIndexingGovernor: Sendable {
    func permitsIndexing() -> Bool
}

/// Trivially permissive governor for tests and previews.
public struct MLAlwaysPermitsIndexing: MLIndexingGovernor {
    public init() {}
    public func permitsIndexing() -> Bool { true }
}

/// Closure-backed governor so hosts can compose existing workload signals (thermal, low
/// power, visible thumbnail demand, app lifecycle) without a new type per platform.
public struct MLClosureIndexingGovernor: MLIndexingGovernor {
    private let permits: @Sendable () -> Bool

    public init(_ permits: @escaping @Sendable () -> Bool) {
        self.permits = permits
    }

    public func permitsIndexing() -> Bool { permits() }
}

// Search and indexing are satisfied by MLSearchService's existing API; only shutdown is new.
extension MLSearchService: MLSmartSearchSession {
    public func shutdown() async {
        await releaseMemory()
    }
}

/// Lazily opened, closable handle around the persistent SQLite index store.
public final class SQLiteMLIndexStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
    private let url: URL
    private let policy: LibraryDatabasePolicy
    private let cipher: any MLVectorCipher
    private let lock = NSLock()
    private var store: SQLiteMLIndexStore?

    public init(url: URL, policy: LibraryDatabasePolicy = .conservative, cipher: any MLVectorCipher) {
        self.url = url
        self.policy = policy
        self.cipher = cipher
    }

    public func openStore() -> (any MLIndexStore)? {
        lock.withLock {
            if let store { return store }
            let opened = SQLiteMLIndexStore(url: url, policy: policy, cipher: cipher)
            store = opened
            return opened
        }
    }

    public func closeStore() {
        lock.withLock {
            store?.close()
            store = nil
        }
    }
}
