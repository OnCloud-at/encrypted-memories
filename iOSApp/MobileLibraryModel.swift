import AlbumCore
import AlbumsFeature
import Foundation
import LibrarySourceRuntime
import MLSearchAppleAdapter
import MLSearchCore
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaFeedCore
import MediaLocationCore
import Observation
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import UIKit

struct MobileRetryOwnerGraph {
    typealias Shutdown = @MainActor @Sendable () async -> Void

    static func makeCoordinator(
        platformTasks: @escaping Shutdown,
        smartSearch: @escaping Shutdown,
        locationCrawl: @escaping Shutdown,
        photoBackup: @escaping Shutdown,
        albumSync: @escaping Shutdown,
        facade: @escaping Shutdown
    ) throws -> AccountTeardownCoordinator {
        try AccountTeardownCoordinator(owners: [
            AccountTeardownOwner(id: "mobile.retry.platform-tasks", stage: .platformTasks, shutdown: platformTasks),
            AccountTeardownOwner(id: "mobile.retry.smart-search", stage: .smartSearch, shutdown: smartSearch),
            AccountTeardownOwner(id: "mobile.retry.location-crawl", stage: .locationCrawl, shutdown: locationCrawl),
            AccountTeardownOwner(id: "mobile.retry.photo-backup", stage: .photoBackup, shutdown: photoBackup),
            AccountTeardownOwner(id: "mobile.retry.album-sync", stage: .albumSync, shutdown: albumSync),
            AccountTeardownOwner(id: "mobile.retry.facade", stage: .facade, shutdown: facade),
        ])
    }
}

/// Captures the account/load generation that owns one user-initiated library mutation. Backend calls may ignore
/// cooperative cancellation, so every continuation must validate this lease before it publishes local state.
struct MobileLibraryMutationLease: Equatable, Sendable {
    let loadToken: Int
    let sessionUID: String

    func isCurrent(loadToken: Int, sessionUID: String?) -> Bool {
        self.loadToken == loadToken && self.sessionUID == sessionUID
    }
}

struct MobileScopeRecoveryIdentity: Equatable, Sendable {
    let failedSession: ProtonSession
    let failedLoadGeneration: Int
    let requestID: UInt64

    func matches(
        session: ProtonSession?,
        loadGeneration: Int,
        activeIdentity: MobileScopeRecoveryIdentity?
    ) -> Bool {
        session == failedSession
            && loadGeneration == failedLoadGeneration &+ 1
            && activeIdentity == self
    }
}

private struct MobileLibraryRefreshResult: Sendable {
    let outcome: LibraryChangeRefreshOutcome
    let failureReason: TimelineRefreshFailureReason?
}

/// Owns the single terminal-recovery task. Scheduling is synchronous on the main actor, so retry, sign-out, and
/// session replacement can observe and join the task before any recovery suspension occurs.
@MainActor
final class MobileScopeRecoveryCoordinator {
    private(set) var activeIdentity: MobileScopeRecoveryIdentity?
    private(set) var task: Task<Void, Never>?

    var isActive: Bool { task != nil }

    @discardableResult
    func schedule(
        identity: MobileScopeRecoveryIdentity,
        prepare: @MainActor @Sendable () -> Void,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) -> Bool {
        guard task == nil, activeIdentity == nil else { return false }
        activeIdentity = identity
        prepare()
        let scheduled = Task { @MainActor [weak self] in
            await operation()
            self?.finish(identity: identity)
        }
        task = scheduled
        return true
    }

    func isCurrent(_ identity: MobileScopeRecoveryIdentity) -> Bool {
        activeIdentity == identity
    }

    @discardableResult
    func joinIfActive() async -> Bool {
        guard let task else { return false }
        await task.value
        return true
    }

    /// Invalidates the identity before cancellation. A late completion from this task cannot clear a newer task.
    func cancel() -> Task<Void, Never>? {
        let activeTask = task
        activeIdentity = nil
        task = nil
        activeTask?.cancel()
        return activeTask
    }

    private func finish(identity: MobileScopeRecoveryIdentity) {
        guard activeIdentity == identity else { return }
        activeIdentity = nil
        task = nil
    }
}

/// Runs the ordered asynchronous half of terminal scope recovery. The identity gate is checked after every
/// suspension, so an old session cannot purge or rebuild a replacement session.
@MainActor
struct MobileScopeRecoveryDriver {
    let isCurrent: @MainActor @Sendable () -> Bool
    let joinRetry: @MainActor @Sendable () async -> Void
    let retireOwners: @MainActor @Sendable () async -> Void
    let purgeLostScope: @MainActor @Sendable () async -> Void
    let rebuild: @MainActor @Sendable () -> Void

    func run() async {
        guard !Task.isCancelled, isCurrent() else { return }
        await joinRetry()
        guard !Task.isCancelled, isCurrent() else { return }
        await retireOwners()
        guard !Task.isCancelled, isCurrent() else { return }
        await purgeLostScope()
        guard !Task.isCancelled, isCurrent() else { return }
        rebuild()
    }
}

enum MobileFavoriteFilterAvailability: Equatable, Sendable {
    case loading
    case available
    case unavailable
}

/// Owns signed-in iOS/iPadOS library state and composes the shared backend and thumbnail feed.
/// Core owns loading; this model sequences cached data, authoritative data, and crawling.
/// `@Observable` invalidates views per property, so non-grid tabs do not observe timeline snapshots.
@MainActor
@Observable
final class MobileLibraryModel {
    private enum TeardownFailure: Error {
        case purgeFailed
    }

    /// Shared onboarding and loading policy. See `LibraryLoadState`.
    private(set) var loadState: LibraryLoadState = .initial
    /// Immutable timeline snapshot prepared off the main actor. Its index provides O(1) and O(k) lookups
    /// for viewer, share, and trash actions without scanning the library.
    private(set) var snapshot = TimelineSnapshot()
    /// Changes only when a new canonical snapshot is published. Secondary grids use it to refresh their one
    /// indexed projection without recomputing it for unrelated SwiftUI state changes.
    private(set) var timelineRevision: UInt64 = 0
    /// The ordered items, for the grid and callers that pass the whole list (e.g. the viewer pager). Reads
    /// register a dependency on `snapshot`, so a timeline change invalidates only views that read items.
    var items: [PhotoItem] { snapshot.items }
    /// Timeline sections retained for the shared section-based `TimelineSearch` filter.
    private(set) var sections: [TimelineSection] = []
    /// Authoritative server favorite identities used by shared search semantics. Loading is independent of the
    /// timeline so a slow favorite endpoint never delays first thumbnails.
    private(set) var favoriteUIDs: Set<PhotoUID> = []
    /// Favorites cannot be filtered honestly until the independent authoritative endpoint has settled.
    private(set) var favoriteFilterAvailability: MobileFavoriteFilterAvailability = .loading
    /// Viewer and grid favorite buttons share one authoritative in-flight set. A repeated tap for the same
    /// identity cannot issue a second write while the first partial-success contract is still settling.
    private(set) var favoriteMutationsInFlight: Set<PhotoUID> = []
    private(set) var thumbnailFeed: UIKitThumbnailFeed?
    /// Indicates that thumbnails for newly discovered authoritative assets remain unresolved.
    private(set) var isBackgroundLoading = false
    /// Indicates that explicit sign-out is closing account owners and deleting account data.
    /// Transient session replacement does not set this flag.
    private(set) var isSigningOut = false
    /// Indicates that explicit sign-out closed every account owner but could not finish the local-data purge.
    /// The durable purge marker remains armed, so retry or the next process launch must finish cleanup.
    private(set) var signOutCleanupFailed = false
    /// Invalidates every presentation that can retain providers or rows from a lost Drive scope. Recovery keeps
    /// this state active until the replacement backend exists.
    private(set) var isRecoveringScope = false
    private(set) var scopePresentationRevision: UInt64 = 0
    private let thumbnailUpdateCoordinator = LibraryThumbnailUpdateCoordinator()

    /// The shared backend, exposed so the Albums / Map / Viewer tabs can reuse it without re-building anything.
    private(set) var backend: (any PhotosBackend)?
    private(set) var facade: ProtonClientFacade?
    /// Shared create/list/add state machine used by every native album presentation in this session.
    private(set) var albumActions: AlbumActionCoordinator?
    /// Account-scoped Photos-library backup controller shared with macOS.
    private(set) var photoBackup: PhotoLibraryBackupController?
    /// Account-scoped local-album sync controller shared with macOS.
    private(set) var albumSync: AlbumSyncController?
    /// Bumped by the shared album-sync controller after remote album mutations so Collections can
    /// refresh without reloading the whole timeline.
    private(set) var albumCatalogRevision = 0
    /// Account-scoped Smart Search lifecycle. MLSearchCore owns lifecycle decisions.
    private(set) var smartSearch: MLSmartSearchController?

    /// Encrypted GPS index shared with the Map tab. The per-account key protects it at rest.
    let locationIndex = PhotoLocationIndex()
    private let locationStore = PhotoLocationStore()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false
    private var locationCrawlGeneration: UInt64 = 0
    private var locationCrawlStartTask: Task<Void, Never>?
    private var locationInventoryRevision: UInt64 = 0
    private var locationCrawlInventoryRevision: UInt64 = 0
    private var locationInventoryTask: Task<LocationCrawlInventory, Never>?

    /// Encrypted thumbnail cache retained for Settings diagnostics and clear actions. Decoded previews remain
    /// in RAM, while video bytes are managed by the backend.
    private var thumbnailCache: ThumbnailCache?

    /// Encrypted on-disk cache for decrypted originals. The viewer seeds it; fullscreen opens and share/export
    /// reuse it before the network. Plaintext originals stay inside this AES-GCM store.
    private(set) var originalsCache: ThumbnailCache?

    /// LRU byte ceiling for `originalsCache`, enforced after each viewer store so a long session of large
    /// HEIC/video originals can't grow the on-disk cache without bound.
    let originalsCacheCapBytes: Int64 = 512 * 1024 * 1024

    private var configuredUID: String?
    private var store: SessionKeychainStore?
    private var session: ProtonSession?
    private var cacheContext: LocalMediaCacheContext?
    private var loadTask: Task<Void, Never>?
    /// Serializes account replacement: a newly authenticated session never opens SQLite stores
    /// until the previous facade has closed every handle and completed an explicit sign-out purge.
    private var teardownTask: Task<Void, Never>?
    /// Retains the already-claimed idempotent purge after a failure so the user can retry without reopening
    /// account owners. Process termination drops this value, but the durable marker recreates it at launch.
    @ObservationIgnored private var pendingSignOutPurgeClaim: BackupLocalDataPurge.Claim?
    private var transitionTask: Task<Void, Never>?
    private var prefetchStartTask: Task<Void, Never>?
    /// Lifecycle callbacks may arrive while the backend is still validating its cache. They record foreground
    /// state immediately, but monitoring is gated until this launch has one stable result or a handled failure.
    private var initialLibraryLoadSettled = false
    private var favoriteLoadTask: Task<Void, Never>?
    /// Mutations newer than the in-flight authoritative favorite read. The loader merges this journal before
    /// publishing, so a slow response cannot erase a newer heart tap.
    @ObservationIgnored private var favoriteLoadOverrides: [PhotoUID: Bool] = [:]
    @ObservationIgnored private var favoriteLoadSettled = false
    /// Generation token used to reject off-main snapshot results from superseded loads or teardown.
    private var loadToken = 0
    private let libraryChangeMonitor = LibraryChangeMonitor()
    private let libraryRefreshCoalescer = LibraryRefreshCoalescer()
    private let uploadRefreshCoordinator = TimelineUploadRefreshCoordinator()
    private var applicationIsActive = true
    private(set) var isRefreshingLibrary = false
    /// Wakes analysis-only presentation after a source inventory becomes readable.
    private(set) var sourceAnalysisRevision: UInt64 = 0
    @ObservationIgnored private var smartSearchMemoryRegistration: MemoryPressureRegistration?
    @ObservationIgnored private let smartSearchAssets = MLAssetUniverse()
    @ObservationIgnored private var primaryInventoryAuthority: SourceInventoryAuthority = .hydrating
    @ObservationIgnored private var pendingTimelineRemovals = Set<PhotoUID>()
    @ObservationIgnored private var timelineMutationGeneration = 0
    /// The most recent ordered Smart Search shutdown; teardown awaits it before the sign-out purge.
    @ObservationIgnored private var smartSearchShutdownTask: Task<Void, Never>?
    @ObservationIgnored private var sourceAnalysisRuntime: LibrarySourceAnalysisRuntime?
    @ObservationIgnored private var sourceAnalysisStartupTask: Task<Void, Never>?
    @ObservationIgnored private var sourceAnalysisActivityTask: Task<Void, Never>?
    @ObservationIgnored private var sourceAnalysisShutdownTask: Task<Void, Never>?
    @ObservationIgnored private var sourcePrimaryInventoryGeneration: UInt64 = 0
    /// Coalesces repeated retry taps into one ordered transient retirement and one replacement load.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Coalesces terminal Drive scope recovery. This path keeps authentication but purges all lost-scope data.
    @ObservationIgnored private let scopeRecoveryCoordinator = MobileScopeRecoveryCoordinator()
    @ObservationIgnored private var nextScopeRecoveryID: UInt64 = 0

    func configure(session: ProtonSession?, store: SessionKeychainStore) {
        guard let session else {
            self.store = store
            teardown()
            return
        }
        guard !scopeRecoveryCoordinator.isActive, !isRecoveringScope else { return }
        self.store = store
        // Reuse the configured account on relaunch or route changes without restarting the crawl.
        guard configuredUID != session.uid || backend == nil else { return }
        self.session = session
        if let teardownTask {
            configuredUID = session.uid
            loadState = .preparingInventory
            transitionTask?.cancel()
            transitionTask = Task { @MainActor [weak self] in
                await teardownTask.value
                guard let self,
                    !Task.isCancelled,
                    self.session == session,
                    !self.isSigningOut,
                    !BackupLocalDataPurge.isPurgePending()
                else { return }
                self.teardownTask = nil
                self.transitionTask = nil
                self.start(session: session, store: store)
            }
            return
        }
        start(session: session, store: store)
    }

    /// Moves items to Trash through the shared backend. The move is recoverable, not permanent.
    /// On success, the items leave the visible library. Errors propagate to the caller.
    func trashItems(_ uids: Set<PhotoUID>) async throws {
        guard let backend, let mutationLease = currentMutationLease(), !uids.isEmpty else { return }
        try Task.checkCancellation()
        let locationStoreLease = locationStore.captureSessionLease()
        try await backend.trash(Array(uids))
        try requireCurrentMutation(mutationLease)
        pendingTimelineRemovals.formUnion(uids)
        timelineMutationGeneration &+= 1
        let generation = timelineMutationGeneration
        let currentSections = sections
        let allRemovals = pendingTimelineRemovals
        let result = await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: currentSections).removing(allRemovals)
            return (projection, Set(projection.snapshot.items.map(\.uid)))
        }.value
        try requireCurrentMutation(mutationLease)
        guard generation == timelineMutationGeneration else { return }
        publish(result.0, locationInventoryChanged: true)
        apply(.inventoryResolved(count: result.0.snapshot.count, cached: false))
        await locationIndex.retainOnly(
            result.1,
            persistTo: locationStoreLease == nil ? nil : locationStore,
            sessionLease: locationStoreLease
        )
        try requireCurrentMutation(mutationLease)
    }

    func restoreItems(_ items: [PhotoItem]) async throws {
        guard let backend, let mutationLease = currentMutationLease(), !items.isEmpty else { return }
        try Task.checkCancellation()
        let locationStoreLease = locationStore.captureSessionLease()
        let uids = Set(items.map(\.uid))
        try await backend.restore(Array(uids))
        try requireCurrentMutation(mutationLease)
        pendingTimelineRemovals.subtract(uids)
        timelineMutationGeneration &+= 1
        let generation = timelineMutationGeneration
        let currentSections = sections
        let remainingRemovals = pendingTimelineRemovals
        let result = await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: currentSections)
                .inserting(items)
                .removing(remainingRemovals)
            return (projection, Set(projection.snapshot.items.map(\.uid)))
        }.value
        try requireCurrentMutation(mutationLease)
        guard generation == timelineMutationGeneration else { return }
        let shouldRestartLocationCrawl = locationCrawlStarted
        publish(result.0, locationInventoryChanged: true)
        apply(.inventoryResolved(count: result.0.snapshot.count, cached: false))
        await locationIndex.retainOnly(
            result.1,
            persistTo: locationStoreLease == nil ? nil : locationStore,
            sessionLease: locationStoreLease
        )
        try requireCurrentMutation(mutationLease)
        if shouldRestartLocationCrawl {
            locationCrawlStarted = false
            startLocationCrawlIfNeeded()
        }
    }

    /// Optimistically toggles selected favorites through the shared Core projection, then rolls back only identities
    /// that the backend reports as failed. The return value lets the native host present a concise error.
    @discardableResult
    func toggleFavorite(_ selection: Set<PhotoUID>) async -> Bool {
        guard let backend, let activeSession = session else { return false }
        guard favoriteMutationsInFlight.isDisjoint(with: selection) else { return true }
        let mutationGeneration = loadToken
        guard let target = FavoriteMutationPolicy.target(for: selection, current: favoriteUIDs) else { return true }
        let requested = FavoriteMutationPolicy.requestedUIDs(
            selection: selection,
            current: favoriteUIDs,
            target: target
        )
        guard !requested.isEmpty else { return true }
        if !favoriteLoadSettled {
            for requestedUID in requested {
                favoriteLoadOverrides[requestedUID] = target
            }
        }
        favoriteMutationsInFlight.formUnion(requested)
        favoriteUIDs = FavoriteMutationPolicy.optimisticState(
            current: favoriteUIDs,
            requested: requested,
            target: target
        )
        defer {
            if mutationGeneration == loadToken, session == activeSession {
                favoriteMutationsInFlight.subtract(requested)
            }
        }
        do {
            try await backend.setFavorites(Array(requested), target)
            guard mutationGeneration == loadToken, session == activeSession else { return true }
            return true
        } catch let partial as FavoriteMutationError {
            guard mutationGeneration == loadToken, session == activeSession else { return true }
            if !favoriteLoadSettled {
                for failedUID in partial.failed {
                    favoriteLoadOverrides.removeValue(forKey: failedUID)
                }
            }
            favoriteUIDs = FavoriteMutationPolicy.rollbackState(
                current: favoriteUIDs,
                failed: partial.failed,
                target: target
            )
            return partial.failed.isDisjoint(with: requested)
        } catch {
            guard mutationGeneration == loadToken, session == activeSession else { return true }
            if !favoriteLoadSettled {
                for failedUID in requested {
                    favoriteLoadOverrides.removeValue(forKey: failedUID)
                }
            }
            favoriteUIDs = FavoriteMutationPolicy.rollbackState(
                current: favoriteUIDs,
                failed: requested,
                target: target
            )
            return false
        }
    }

    @discardableResult
    func toggleFavorite(_ uid: PhotoUID) async -> Bool {
        await toggleFavorite([uid])
    }

    private func currentMutationLease() -> MobileLibraryMutationLease? {
        guard let session else { return nil }
        return MobileLibraryMutationLease(loadToken: loadToken, sessionUID: session.uid)
    }

    private func requireCurrentMutation(_ lease: MobileLibraryMutationLease) throws {
        guard lease.isCurrent(loadToken: loadToken, sessionUID: session?.uid) else {
            throw CancellationError()
        }
    }

    func emptyTrash() async throws {
        guard let backend else { return }
        try await backend.emptyTrash()
    }

    /// Deletes only the album container through the shared AlbumCore facade. The backend deliberately uses
    /// Proton's safe `DeleteAlbumPhotos=0` contract, so photos that exist only in the album cause an honest
    /// failure instead of being permanently deleted. The revision refreshes every album presentation on success.
    func deleteAlbum(_ albumID: String) async throws {
        guard let facade else { return }
        try await facade.albums.deleteAlbum(albumID: albumID)
        albumCatalogRevision &+= 1
    }

    func removeItems(_ uids: [PhotoUID], fromAlbum albumID: String) async throws {
        guard let facade else { return }
        try await facade.albums.removePhotos(uids, from: albumID)
        albumCatalogRevision &+= 1
    }

    func noteAlbumsChanged() {
        albumCatalogRevision &+= 1
    }

    /// Returns the position of `uid` through the snapshot index.
    func index(of uid: PhotoUID) -> Int? { snapshot.index(of: uid) }

    /// Returns selected items in timeline order through the snapshot index.
    func selectedItems(_ uids: Set<PhotoUID>) -> [PhotoItem] { snapshot.items(withUIDs: uids) }

    /// ID-only server actions retain every selected identity even if a concurrent timeline refresh replaced
    /// the projection between the tap and presentation of the destination sheet.
    func selectedUIDs(_ uids: Set<PhotoUID>) -> [PhotoUID] { snapshot.orderedUIDs(including: uids) }

    /// Returns the encrypted thumbnail-cache size without blocking the main actor on file I/O.
    func cacheDiskSizeBytes() async -> Int64 {
        guard let cache = thumbnailCache else { return 0 }
        return await Task.detached { cache.diskSizeBytes() }.value
    }

    /// Clears the thumbnail cache and restarts prefetch. The feed keeps decoded thumbnails, and only the
    /// cache-owned directory is removed.
    func clearCache() async {
        guard let cache = thumbnailCache else { return }
        if let feed = thumbnailFeed {
            await feed.clearCacheAndRestartPrefetch()
        } else {
            await cache.clear()
        }
    }

    /// Retires account owners before starting a replacement load after failure.
    func retry() async {
        guard let session, let store else { return }
        if await scopeRecoveryCoordinator.joinIfActive() { return }
        if let retryTask {
            await retryTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryTask = nil }
            await self.retireForRetry()
            guard !Task.isCancelled, self.session == session else { return }
            self.configuredUID = nil
            self.start(session: session, store: store, preserveVisibleSnapshot: true)
        }
        retryTask = task
        await task.value
    }

    /// Schedules a Drive-scope recovery for the exact session and load that observed the terminal result. The
    /// synchronous preparation fences old publishers and removes inaccessible content before the task can run.
    private func scheduleScopeRecovery(
        failedSession: ProtonSession,
        failedStore: SessionKeychainStore,
        failedLoadGeneration: Int
    ) {
        guard !scopeRecoveryCoordinator.isActive,
            session == failedSession,
            loadToken == failedLoadGeneration
        else { return }

        nextScopeRecoveryID &+= 1
        let identity = MobileScopeRecoveryIdentity(
            failedSession: failedSession,
            failedLoadGeneration: failedLoadGeneration,
            requestID: nextScopeRecoveryID
        )
        let activeRetry = retryTask
        let activeThumbnailCache = thumbnailCache
        let activeOriginalsCache = originalsCache
        let locationStore = locationStore
        let locationIndex = locationIndex
        let policy = ProtonDriveBackendPolicy.standard(
            libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
            videoCacheBudgetBytes: 128 * 1024 * 1024
        )

        let driver = MobileScopeRecoveryDriver(
            isCurrent: { [weak self] in
                self?.scopeRecoveryIsCurrent(identity) == true
            },
            joinRetry: {
                await activeRetry?.value
            },
            retireOwners: { [weak self] in
                await self?.retireForRetry(advanceLoadToken: false)
            },
            purgeLostScope: { [weak self] in
                guard let self else { return }
                self.cacheContext = nil
                self.thumbnailCache = nil
                self.originalsCache = nil
                await Task.detached(priority: .utility) {
                    activeThumbnailCache?.clearForSignOut()
                    activeOriginalsCache?.clearForSignOut()
                    locationStore.clear()
                    ProtonDriveBackendFactory.purgeLocalAccountData(uid: failedSession.uid, policy: policy)
                }.value
            },
            rebuild: { [weak self] in
                guard let self else { return }
                self.configuredUID = nil
                self.start(session: failedSession, store: failedStore, preserveVisibleSnapshot: false)
            }
        )

        let scheduled = scopeRecoveryCoordinator.schedule(
            identity: identity,
            prepare: { [weak self] in
                guard let self else { return }
                // Never leave inaccessible rows or provider-backed presentations visible during teardown.
                self.isRecoveringScope = true
                self.scopePresentationRevision &+= 1
                self.loadToken &+= 1
                activeRetry?.cancel()
                self.prefetchStartTask?.cancel()
                self.favoriteLoadTask?.cancel()
                self.snapshot = TimelineSnapshot()
                self.sections = []
                self.favoriteUIDs = []
                self.favoriteMutationsInFlight = []
                self.favoriteLoadOverrides.removeAll(keepingCapacity: false)
                self.favoriteLoadSettled = false
                self.favoriteFilterAvailability = .loading
                self.pendingTimelineRemovals.removeAll(keepingCapacity: false)
                self.timelineMutationGeneration &+= 1
                self.timelineRevision &+= 1
                self.initialLibraryLoadSettled = false
                self.loadState = .preparingInventory
                locationIndex.replaceAll([])
                locationIndex.updateScanProgress(PhotoLocationScanProgress())
            },
            operation: {
                await driver.run()
            }
        )
        precondition(scheduled, "Scope recovery changed during synchronous scheduling")
    }

    /// Removes a Drive scope only after every owner has stopped. Authentication remains valid, and a clean
    /// facade resolves or recreates the Photos volume after SDK, timeline, media, and location data is purged.
    private func recoverAfterScopeAccessLoss(
        expectedSession: ProtonSession? = nil,
        expectedLoadGeneration: Int? = nil
    ) async {
        guard let currentSession = session, let store else { return }
        scheduleScopeRecovery(
            failedSession: expectedSession ?? currentSession,
            failedStore: store,
            failedLoadGeneration: expectedLoadGeneration ?? loadToken
        )
        _ = await scopeRecoveryCoordinator.joinIfActive()
    }

    private func scopeRecoveryIsCurrent(_ identity: MobileScopeRecoveryIdentity) -> Bool {
        identity.matches(
            session: session,
            loadGeneration: loadToken,
            activeIdentity: scopeRecoveryCoordinator.activeIdentity
        )
    }

    /// Lifecycle-only platform seam. Detection cadence and failure backoff remain shared TimelineCore policy.
    func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        if active, initialLibraryLoadSettled {
            startLibraryChangeMonitorIfPossible()
        } else {
            Task { await libraryChangeMonitor.stop() }
        }
        if let sourceAnalysisRuntime {
            let previous = sourceAnalysisActivityTask
            let task = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await sourceAnalysisRuntime.setActive(active)
            }
            sourceAnalysisActivityTask = task
        }
    }

    /// Local upload completion is authoritative enough to refresh immediately; repeated signals coalesce.
    func refreshAfterLocalUpload() {
        guard let recoverySession = session, let refreshLease = currentMutationLease() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.uploadRefreshCoordinator.request(
                refresh: { [weak self] _ in
                    guard let self else { return .cancelled }
                    return await self.performLibraryRefresh(lease: refreshLease).failureReason
                },
                observer: { [weak self] attempt in
                    guard attempt.failureReason == .scopeAccessLost else { return }
                    await self?.recoverAfterScopeAccessLoss(
                        expectedSession: recoverySession,
                        expectedLoadGeneration: refreshLease.loadToken
                    )
                }
            )
        }
    }

    /// Best-effort settings metadata refresh. A failed foreground refresh keeps the last encrypted-cache value
    /// visible instead of turning a temporary network problem into an app-level error.
    func refreshAccountInfo() async {
        try? await facade?.refreshAccountInfo()
        await sourceAnalysisRuntime?.refresh()
    }

    /// Coalesces source discovery with any active refresh. Callers use this after connectivity or
    /// catalog change signals and do not delay the primary timeline refresh on secondary metadata.
    func refreshLibrarySources() {
        guard let sourceAnalysisRuntime else { return }
        Task { await sourceAnalysisRuntime.refresh() }
    }

    /// Called when the grid first draws a fully populated frame to lift the loading UI.
    func markFirstContentReady() {
        apply(.firstContentReady)
    }

    private func scheduleThumbnailPrefetch(using feed: UIKitThumbnailFeed) {
        prefetchStartTask?.cancel()
        let crawlItems = items
        let token = loadToken
        prefetchStartTask = Task { [weak self] in
            let uids = await Task.detached(priority: .utility) {
                ThumbnailCrawlOrder.newestToOldestFromChronological(crawlItems)
            }.value
            guard let self, !Task.isCancelled, token == self.loadToken else { return }
            await feed.startPrefetch(uids)
        }
    }

    private func reconcileNewAssetThumbnails(
        previousUIDs: [PhotoUID],
        using feed: UIKitThumbnailFeed
    ) {
        let currentUIDs = items.map(\.uid)
        thumbnailUpdateCoordinator.reconcile(
            currentUIDs: currentUIDs,
            addedUIDs: LibraryInventoryDelta.addedUIDs(
                previous: previousUIDs,
                current: currentUIDs
            ),
            onStateChange: { [weak self] state in
                self?.isBackgroundLoading = state.isActive
            },
            resolver: { uids, enqueueMissing in
                await feed.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
            }
        )
    }

    /// Starts one resumable, low-priority GPS crawl when the Map first opens.
    func startLocationCrawlIfNeeded() {
        guard !locationCrawlStarted, let backend, let cacheContext, !items.isEmpty else { return }
        locationCrawlStarted = true
        locationCrawlGeneration &+= 1
        let crawlGeneration = locationCrawlGeneration
        let loadGeneration = loadToken
        let accountUID = cacheContext.accountUID
        let previousStarter = locationCrawlStartTask
        previousStarter?.cancel()
        let locationKey = cacheContext.encryptionKey

        // Reuse the latest off-actor projection when available. The fallback covers tests or an early Map open.
        let initialItems = items
        let inventoryTask =
            locationInventoryTask
            ?? Task.detached(priority: .utility) {
                LocationCrawlInventory(items: initialItems)
            }
        locationInventoryTask = inventoryTask
        locationCrawlInventoryRevision = locationInventoryRevision
        let index = locationIndex
        let store = locationStore
        let crawl = locationCrawl
        let feed = thumbnailFeed
        let governor = LibraryWorkloadGovernorPolicy()
        locationCrawlStartTask = Task { @MainActor [weak self, previousStarter] in
            await previousStarter?.value
            guard let self,
                !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            // Await the previous crawl before replacing the store lease. Delayed persistence could otherwise
            // race the new account generation.
            await crawl.cancel()
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            let sessionLease = store.configure(accountUID: accountUID, key: locationKey)
            let locationLoad = Task.detached(priority: .utility) {
                store.loadSnapshot()
            }
            let initialInventory = await inventoryTask.value
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            let snapshot = await locationLoad.value
            guard !Task.isCancelled,
                store.isCurrentSessionLease(sessionLease),
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            self.locationIndex.replaceAll(snapshot)  // Decrypted data stays off the UI actor.
            // Give thumbnail crawling a head start, then yield to visible demand. Do not use
            // `hasPendingThumbnailWork()` because it includes whole-library fill and can starve map indexing.
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else { return }
            await crawl.start(
                uids: initialInventory.uids,
                captureDates: initialInventory.captureDates,
                accountUID: accountUID,
                location: LocationCrawl.metadataProbe(backend),
                index: index,
                store: store,
                shouldYield: {
                    let applicationIsActive = await MainActor.run { self.applicationIsActive }
                    guard applicationIsActive else { return true }
                    let visibleDemand = await feed?.hasVisibleThumbnailPressure() ?? false
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: visibleDemand)
                    ).shouldYield
                },
                log: { DebugLog.log($0) },
                inventory: { @MainActor [weak self] in
                    guard let self, let task = self.locationInventoryTask else {
                        return LocationCrawlInventory()
                    }
                    let revision = self.locationInventoryRevision
                    let inventory = await task.value
                    self.locationCrawlInventoryRevision = max(
                        self.locationCrawlInventoryRevision,
                        revision
                    )
                    return inventory
                }
            )
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else {
                await crawl.cancel()
                return
            }
            if self.locationCrawlInventoryRevision != self.locationInventoryRevision {
                self.locationCrawlStarted = false
                self.startLocationCrawlIfNeeded()
            }
        }
    }

    func restartLocationCrawlIfNeeded() {
        guard !items.isEmpty else { return }
        locationCrawlStarted = false
        startLocationCrawlIfNeeded()
    }

    /// Builds the account-scoped Smart Search lifecycle. MLSearchCore owns lifecycle decisions.
    private func configureSmartSearch(session: ProtonSession, client: ProtonClientFacade, feed: UIKitThumbnailFeed) {
        guard AppleSmartSearchBootstrap.featureAvailability() == .available else {
            smartSearch = nil
            return
        }
        #if DEBUG
            let allowsDeveloperModels = true
        #else
            let allowsDeveloperModels = false
        #endif
        #if DEBUG
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.debugEndpoint(
                environment: ProcessInfo.processInfo.environment
            )
        #else
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.production
        #endif
        smartSearchAssets.beginHydration()
        let lifecycle = AppleSmartSearchBootstrap.makeLifecycle(
            accountDirectory: client.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feed.feedCore,
            assetsProvider: { [smartSearchAssets] in smartSearchAssets.snapshot() },
            allowsDeveloperModels: allowsDeveloperModels,
            databasePolicy: client.accountDatabasePolicy,
            catalogEndpoint: catalogEndpoint
        )
        smartSearch = MLSmartSearchController(lifecycle: lifecycle)
        // Under memory pressure the search stack drops cached vector blocks and unloads the
        // CoreML model; both rebuild on demand.
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = MemoryPressureGovernor.shared.register { tier in
            guard tier.requiresImmediatePurge else { return }
            Task { await lifecycle.releaseMemory() }
        }
    }

    private func configureSourceAnalysis(client: ProtonClientFacade, feed: UIKitThumbnailFeed) {
        guard sourceAnalysisRuntime == nil else { return }
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: client.librarySources,
            feed: feed.feedCore,
            assets: smartSearchAssets,
            initiallyActive: applicationIsActive,
            onAssetsChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceAnalysisRevision &+= 1
                    self.smartSearch?.noteLibraryChanged()
                }
            }
        )
        sourceAnalysisRuntime = runtime
        let previousShutdown = sourceAnalysisShutdownTask
        sourceAnalysisStartupTask = Task {
            await previousShutdown?.value
            _ = await runtime.start()
        }
    }

    /// Stops Smart Search and returns a task that completes after all prior shutdowns and the current
    /// lifecycle shutdown finish.
    @discardableResult
    private func stopSmartSearch() -> Task<Void, Never>? {
        let lifecycle = smartSearch?.lifecycleActor
        smartSearch = nil
        smartSearchAssets.beginHydration()
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = nil
        guard let lifecycle else { return smartSearchShutdownTask }
        let previous = smartSearchShutdownTask
        let task = Task {
            await previous?.value
            await lifecycle.shutdown()
        }
        smartSearchShutdownTask = task
        return task
    }

    @discardableResult
    private func stopSourceAnalysis() -> Task<Void, Never>? {
        smartSearchAssets.invalidateSourceSession()
        let runtime = sourceAnalysisRuntime
        sourceAnalysisRuntime = nil
        let startup = sourceAnalysisStartupTask
        sourceAnalysisStartupTask = nil
        let activity = sourceAnalysisActivityTask
        sourceAnalysisActivityTask = nil
        guard runtime != nil || startup != nil || activity != nil else { return sourceAnalysisShutdownTask }
        startup?.cancel()
        activity?.cancel()
        let previous = sourceAnalysisShutdownTask
        let task = Task {
            await previous?.value
            await activity?.value
            await startup?.value
            await runtime?.shutdown()
        }
        sourceAnalysisShutdownTask = task
        return task
    }

    /// Retires transient retry owners without deleting account data. Every replacement load waits for this
    /// barrier, so a retry never opens a second owner graph while the previous graph still owns SQLite handles.
    private func retireForRetry(advanceLoadToken: Bool = true) async {
        let previousTeardown = teardownTask
        let activeFacade = facade
        let activeLoadTask = loadTask
        let activeTransitionTask = transitionTask
        let activePrefetchStartTask = prefetchStartTask
        let activeFavoriteLoadTask = favoriteLoadTask
        let activePhotoBackup = photoBackup
        let activeAlbumSync = albumSync
        let activeThumbnailFeed = thumbnailFeed
        let activeRefreshCoalescer = libraryRefreshCoalescer
        let activeUploadRefreshCoordinator = uploadRefreshCoordinator
        let activeChangeMonitor = libraryChangeMonitor
        let activeLocationCrawl = locationCrawl
        let activeLocationCrawlStarter = locationCrawlStartTask
        let smartSearchShutdown = stopSmartSearch()
        let sourceAnalysisShutdown = stopSourceAnalysis()

        if advanceLoadToken { loadToken &+= 1 }
        activeLoadTask?.cancel()
        loadTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        favoriteMutationsInFlight = []
        favoriteLoadOverrides.removeAll(keepingCapacity: false)
        favoriteLoadSettled = false
        favoriteFilterAvailability = .loading
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        locationCrawlGeneration &+= 1
        activeLocationCrawlStarter?.cancel()
        locationCrawlStartTask = nil
        locationCrawlStarted = false
        locationInventoryTask?.cancel()
        locationInventoryTask = nil
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        backend = nil
        facade = nil
        albumActions = nil
        PhotoBackupBackgroundCoordinator.shared.backupStopped()
        photoBackup = nil
        albumSync = nil
        thumbnailFeed = nil

        let coordinator: AccountTeardownCoordinator
        do {
            coordinator = try MobileRetryOwnerGraph.makeCoordinator(
                platformTasks: {
                    await previousTeardown?.value
                    await activeTransitionTask?.value
                    await activeLoadTask?.value
                    await activePrefetchStartTask?.value
                    await activeFavoriteLoadTask?.value
                    await activeThumbnailUpdateTask?.value
                    await activeRefreshCoalescer.cancel()
                    await activeUploadRefreshCoordinator.cancel()
                    await activeChangeMonitor.reset()
                    await activeThumbnailFeed?.stopPrefetch()
                },
                smartSearch: {
                    await smartSearchShutdown?.value
                    await sourceAnalysisShutdown?.value
                },
                locationCrawl: {
                    await activeLocationCrawlStarter?.value
                    await activeLocationCrawl.cancel()
                },
                photoBackup: {
                    await activePhotoBackup?.shutdown()
                },
                albumSync: {
                    await activeAlbumSync?.shutdown()
                },
                facade: {
                    await activeFacade?.shutdown()
                }
            )
        } catch {
            preconditionFailure("Duplicate transient retry owner identifier")
        }
        _ = await coordinator.teardown()
    }

    private func teardown() {
        LibraryRuntimeState.shared.beginNewGeneration()
        let previousTeardown = teardownTask
        let activeFacade = facade
        let activeLoadTask = loadTask
        let activeTransitionTask = transitionTask
        let activePrefetchStartTask = prefetchStartTask
        let activeFavoriteLoadTask = favoriteLoadTask
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        isSigningOut = purgeClaim != nil
        pendingSignOutPurgeClaim = purgeClaim
        signOutCleanupFailed = false
        let activePhotoBackup = photoBackup
        let activeAlbumSync = albumSync
        let activeThumbnailFeed = thumbnailFeed
        let activeOriginalsCache = originalsCache
        let activeRefreshCoalescer = libraryRefreshCoalescer
        let activeUploadRefreshCoordinator = uploadRefreshCoordinator
        let activeChangeMonitor = libraryChangeMonitor
        let activeLocationCrawl = locationCrawl
        let activeLocationCrawlStarter = locationCrawlStartTask
        let activeLocationIndex = locationIndex
        let activeRetry = retryTask
        let activeScopeRecovery = scopeRecoveryCoordinator.cancel()

        loadToken &+= 1  // supersede any in-flight snapshot sort
        activeRetry?.cancel()
        retryTask = nil
        isRecoveringScope = false
        activeLoadTask?.cancel()
        loadTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        favoriteMutationsInFlight = []
        favoriteLoadOverrides.removeAll(keepingCapacity: false)
        favoriteLoadSettled = false
        favoriteFilterAvailability = .loading
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        configuredUID = nil
        session = nil
        cacheContext = nil
        backend = nil
        facade = nil
        albumActions = nil
        PhotoBackupBackgroundCoordinator.shared.backupStopped()
        photoBackup = nil
        albumSync = nil
        albumCatalogRevision = 0
        pendingTimelineRemovals.removeAll(keepingCapacity: false)
        timelineMutationGeneration &+= 1
        snapshot = TimelineSnapshot()
        sections = []
        favoriteUIDs = []
        favoriteMutationsInFlight = []
        timelineRevision &+= 1
        thumbnailFeed = nil
        let smartSearchShutdown = stopSmartSearch()
        let sourceAnalysisShutdown = stopSourceAnalysis()
        thumbnailCache = nil
        originalsCache = nil
        loadState = .initial
        locationCrawlStarted = false
        locationInventoryTask?.cancel()
        locationInventoryTask = nil
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        var teardownOwners = [
            AccountTeardownOwner(id: "mobile.platform-tasks", stage: .platformTasks) {
                await previousTeardown?.value
                await activeRetry?.value
                await activeScopeRecovery?.value
                await activeTransitionTask?.value
                await activeLoadTask?.value
                await activePrefetchStartTask?.value
                await activeFavoriteLoadTask?.value
                await activeThumbnailUpdateTask?.value
                await activeRefreshCoalescer.cancel()
                await activeUploadRefreshCoordinator.cancel()
                await activeChangeMonitor.reset()
                await activeThumbnailFeed?.stopPrefetch()
            },
            AccountTeardownOwner(id: "shared.smart-search", stage: .smartSearch) {
                await smartSearchShutdown?.value
                await sourceAnalysisShutdown?.value
            },
            AccountTeardownOwner(id: "mobile.location-crawl", stage: .locationCrawl) {
                await activeLocationCrawlStarter?.value
                await activeLocationCrawl.cancel()
                activeLocationIndex.replaceAll([])
                activeLocationIndex.updateScanProgress(PhotoLocationScanProgress())
            },
            AccountTeardownOwner(id: "shared.photo-backup", stage: .photoBackup) {
                await activePhotoBackup?.shutdown()
            },
            AccountTeardownOwner(id: "shared.album-sync", stage: .albumSync) {
                await activeAlbumSync?.shutdown()
            },
            AccountTeardownOwner(id: "shared.proton-facade", stage: .facade) {
                await activeFacade?.shutdown()
            },
            AccountTeardownOwner(id: "mobile.originals-cache", stage: .caches) {
                guard let activeOriginalsCache else { return }
                await Task.detached(priority: .utility) {
                    activeOriginalsCache.clearForSignOut()
                }.value
            },
            AccountTeardownOwner(id: "shared.debug-log", stage: .logs) {
                await DebugLog.flush()
            },
        ]
        // Transient teardown must not delete account data. Only a claimed sign-out purge may do so.
        if let purgeClaim {
            teardownOwners.append(
                AccountTeardownOwner(id: "shared.local-data-claim", stage: .purgeClaims) {
                    let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: purgeClaim)
                    guard succeeded else { throw TeardownFailure.purgeFailed }
                }
            )
        }

        let teardownCoordinator: AccountTeardownCoordinator
        do {
            teardownCoordinator = try AccountTeardownCoordinator(owners: teardownOwners)
        } catch {
            preconditionFailure("Duplicate account teardown owner identifier")
        }
        teardownTask = Task { @MainActor in
            let report = await teardownCoordinator.teardown()
            guard purgeClaim != nil else { return }
            if report.succeeded {
                self.pendingSignOutPurgeClaim = nil
                self.isSigningOut = false
            } else {
                self.signOutCleanupFailed = true
            }
        }
    }

    /// Retries only the idempotent purge. The first teardown already joined every account-scoped owner.
    /// A failed retry keeps the durable marker and returns to the finite error presentation.
    func retrySignOutCleanup() {
        guard signOutCleanupFailed, let claim = pendingSignOutPurgeClaim else { return }
        signOutCleanupFailed = false
        teardownTask = Task { @MainActor in
            let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: claim)
            if succeeded {
                self.pendingSignOutPurgeClaim = nil
                self.isSigningOut = false
            } else {
                self.signOutCleanupFailed = true
            }
        }
    }

    private func start(
        session: ProtonSession,
        store: SessionKeychainStore,
        preserveVisibleSnapshot: Bool = false
    ) {
        LibraryRuntimeState.shared.beginNewGeneration()
        isSigningOut = false
        signOutCleanupFailed = false
        pendingSignOutPurgeClaim = nil
        loadToken &+= 1  // this load supersedes any older in-flight snapshot sort
        let loadGeneration = loadToken
        loadTask?.cancel()
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        favoriteLoadOverrides.removeAll(keepingCapacity: false)
        favoriteLoadSettled = false
        favoriteFilterAvailability = .loading
        thumbnailUpdateCoordinator.cancel()
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        configuredUID = session.uid
        backend = nil
        facade = nil
        albumActions = nil
        photoBackup = nil
        albumSync = nil
        pendingTimelineRemovals.removeAll(keepingCapacity: false)
        timelineMutationGeneration &+= 1
        if !preserveVisibleSnapshot {
            snapshot = TimelineSnapshot()
            sections = []
            favoriteUIDs = []
            favoriteMutationsInFlight = []
            timelineRevision &+= 1
        }
        thumbnailFeed = nil
        stopSmartSearch()
        stopSourceAnalysis()
        loadState = .preparingInventory

        let cacheContext = LocalMediaCacheContext(accountUID: session.uid, keyPassword: session.keyPassword)
        self.cacheContext = cacheContext
        let cache = ThumbnailCache(
            namespace: "mobile-thumbnails",
            derivative: "thumbnail",
            configuration: UIKitMediaCachePolicy.thumbnailByteCacheConfiguration()
        )
        thumbnailCache = cache

        // Separate encrypted store for decrypted originals, keyed to the account and isolated from thumbnails.
        // The viewer seeds it; share and export reuse it.
        let originals = ThumbnailCache(namespace: "mobile-originals", derivative: "original")
        cacheContext.configure(cache, originals)
        let originalsCap = originalsCacheCapBytes
        Task.detached(priority: .utility) {
            originals.enforceByteCap(originalsCap)
        }
        originalsCache = originals

        // Register UIKit pressure and lifecycle signals with the shared governor. Cache registrations are
        // identity-keyed, so a new session replaces the previous cache and feed.
        UIKitMemoryPressureCoordinator.shared.install()
        UIKitMemoryPressureCoordinator.shared.attachByteCache(cache)

        loadTask = Task { [weak self] in
            guard let self else { return }
            var hadCachedInventory = false
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: store,
                    policy: .standard(
                        libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
                        videoCacheBudgetBytes: 128 * 1024 * 1024
                    )
                )
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else {
                    await client.shutdown()
                    return
                }
                let backend = client.backend
                let feed = UIKitThumbnailFeed(
                    cache: cache,
                    loader: client.librarySources,
                    dimensions: PhotoDimensionCoalescer(store: backend),
                    targetPixels: 288
                )
                let photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader
                )
                let albumSync = AlbumSyncController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    remoteOps: client.albumSyncRemoteOps
                )
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    guard let self,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    self.albumCatalogRevision &+= 1
                }
                await client.uploadCoordinator.start()
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else {
                    await photoBackup.shutdown()
                    await albumSync.shutdown()
                    await client.shutdown()
                    return
                }
                self.facade = client
                self.albumActions = AlbumActionCoordinator(repository: client.albums)
                self.photoBackup = photoBackup
                PhotoBackupBackgroundCoordinator.shared.configure(controller: photoBackup)
                self.albumSync = albumSync
                self.backend = backend
                self.thumbnailFeed = feed
                if self.isRecoveringScope {
                    self.isRecoveringScope = false
                }
                self.favoriteLoadTask = Task { [weak self, backend] in
                    let loaded: Set<PhotoUID>?
                    do {
                        loaded = try await backend.favoriteUIDs()
                    } catch {
                        loaded = nil
                    }
                    guard let self,
                        !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    if let loaded {
                        self.favoriteUIDs = FavoriteMutationPolicy.reconciling(
                            authoritative: loaded,
                            newerTargets: self.favoriteLoadOverrides
                        )
                    }
                    self.favoriteFilterAvailability = loaded == nil ? .unavailable : .available
                    self.favoriteLoadOverrides.removeAll(keepingCapacity: false)
                    self.favoriteLoadSettled = true
                }
                // The live feed's RAM tiers (UIImage wrappers + decoded core) respond to pressure tiers.
                UIKitMemoryPressureCoordinator.shared.attachFeed(feed)
                self.configureSourceAnalysis(client: client, feed: feed)
                self.configureSmartSearch(session: session, client: client, feed: feed)
                // Show the persisted snapshot while Core validates its event token. A match avoids row
                // enumeration; a mismatch falls back to the authoritative load.
                var cacheValidation = TimelineCacheValidation.refreshRequired(monitorBaseline: nil)
                if let cached = await backend.cachedTimelineSnapshot() {
                    hadCachedInventory = true
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    let appliedCachedItems = await applyItems(cached.sections, cached: true)
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    if appliedCachedItems {
                        scheduleThumbnailPrefetch(using: feed)
                    }
                    cacheValidation = await TimelineCacheValidationPolicy.validate(
                        snapshot: cached,
                        repository: backend
                    )
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    if case .terminalFailure = cacheValidation {
                        throw TimelineCacheValidationTerminalError()
                    }
                    if case .validated(let token) = cacheValidation {
                        publishSmartSearchInventory(
                            snapshot.items,
                            authority: .authoritative
                        )
                        apply(.authoritativeInventoryResolved(count: items.count, requiresNewFrame: false))
                        initialLibraryLoadSettled = true
                        startLibraryChangeMonitorIfPossible(
                            resetBaseline: true,
                            initialToken: token
                        )
                        return
                    }
                }

                let refreshed = try await backend.loadTimelineSnapshot()
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else { return }
                let previousUIDs = items.map(\.uid)
                let changed = await applyItems(refreshed.sections, cached: false, authoritative: true)
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else { return }
                if changed {
                    scheduleThumbnailPrefetch(using: feed)
                }
                if hadCachedInventory {
                    reconcileNewAssetThumbnails(previousUIDs: previousUIDs, using: feed)
                }
                initialLibraryLoadSettled = true
                self.startLibraryChangeMonitorIfPossible(
                    resetBaseline: true,
                    initialToken: refreshed.validationToken ?? cacheValidation.monitorBaseline
                )
            } catch is CancellationError {
                // A newer session/configuration replaced this task.
            } catch let error as any LibraryChangeTerminalError {
                guard loadGeneration == self.loadToken, self.session == session else { return }
                DebugLog.log("timeline: terminal scope failure during initial load - \(error)")
                // The recovery task must not join the load task that schedules it. Remove this completed owner
                // first, then synchronously register recovery before this main-actor turn ends.
                self.loadTask = nil
                self.scheduleScopeRecovery(
                    failedSession: session,
                    failedStore: store,
                    failedLoadGeneration: loadGeneration
                )
            } catch {
                guard loadGeneration == self.loadToken, self.session == session else { return }
                if self.isRecoveringScope {
                    self.isRecoveringScope = false
                }
                apply(.failed(message: Self.message(for: error), retryable: true))
                initialLibraryLoadSettled = true
                if hadCachedInventory {
                    // The cached frame remains usable. Seed below each validation token so the first successful
                    // foreground probe retries the authoritative load after connectivity/API recovery.
                    startLibraryChangeMonitorIfPossible(resetBaseline: true, initialToken: "")
                }
            }
        }
    }

    /// Builds an immutable `TimelineSnapshot` off the main actor and publishes it only for the current load.
    @discardableResult
    private func applyItems(
        _ sections: [TimelineSection],
        cached: Bool,
        authoritative: Bool = false
    ) async -> Bool {
        let token = loadToken
        let mutationGeneration = timelineMutationGeneration
        let removals = pendingTimelineRemovals
        let prepared = await Task.detached(priority: .userInitiated) {
            TimelineContentProjection(sections: sections).removing(removals)
        }.value
        // The generation token rejects results from cancelled or superseded loads.
        guard !Task.isCancelled,
            token == loadToken,
            mutationGeneration == timelineMutationGeneration
        else { return false }
        let requiresNewFrame =
            prepared.snapshot.items.lazy.map(\.uid).elementsEqual(snapshot.items.lazy.map(\.uid)) == false
        let changed = prepared.snapshot != snapshot
        if authoritative {
            primaryInventoryAuthority = .authoritative
        } else if cached, primaryInventoryAuthority != .authoritative {
            primaryInventoryAuthority = .cached
        }
        if changed {
            publish(prepared, locationInventoryChanged: requiresNewFrame)
        } else {
            // An empty complete timeline is still authoritative. Publish readiness even when its
            // value equals the launch placeholder so Smart Search can distinguish it from hydration.
            publishSmartSearchInventory(prepared.snapshot.items)
        }
        if authoritative {
            apply(
                .authoritativeInventoryResolved(
                    count: prepared.snapshot.count,
                    requiresNewFrame: requiresNewFrame
                ))
        } else {
            apply(.inventoryResolved(count: prepared.snapshot.count, cached: cached))
        }
        return changed
    }

    private func publish(
        _ projection: TimelineContentProjection,
        locationInventoryChanged: Bool
    ) {
        if locationInventoryChanged {
            let locationItems = projection.snapshot.items
            locationInventoryTask?.cancel()
            locationInventoryTask = Task.detached(priority: .utility) {
                LocationCrawlInventory(items: locationItems)
            }
        }
        snapshot = projection.snapshot
        sections = projection.sections
        timelineRevision &+= 1
        if locationInventoryChanged {
            locationInventoryRevision &+= 1
        }
        publishSmartSearchInventory(projection.snapshot.items)
        if locationCrawlStarted,
            locationCrawlInventoryRevision != locationInventoryRevision,
            locationIndex.scanProgress.phase == .completed || locationIndex.scanProgress.phase == .failed
        {
            locationCrawlStarted = false
            startLocationCrawlIfNeeded()
        }
    }

    private func publishSmartSearchInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority? = nil
    ) {
        if let authority,
            primaryInventoryAuthority != .authoritative || authority == .authoritative
        {
            primaryInventoryAuthority = authority
        }
        guard let sourceAnalysisRuntime else { return }
        let primaryInventoryAuthority = self.primaryInventoryAuthority
        sourcePrimaryInventoryGeneration &+= 1
        let primaryGeneration = sourcePrimaryInventoryGeneration
        Task {
            await sourceAnalysisRuntime.replacePrimaryInventory(
                items,
                authority: primaryInventoryAuthority,
                generation: primaryGeneration
            )
        }
    }

    private func startLibraryChangeMonitorIfPossible(
        resetBaseline: Bool = false,
        initialToken: String? = nil
    ) {
        guard applicationIsActive,
            initialLibraryLoadSettled,
            let provider = backend as? any LibraryChangeTokenProvider,
            let recoverySession = session,
            let refreshLease = currentMutationLease()
        else { return }
        Task { [weak self] in
            guard let self,
                !self.isRecoveringScope,
                refreshLease.isCurrent(loadToken: self.loadToken, sessionUID: self.session?.uid)
            else { return }
            await self.libraryChangeMonitor.restart(
                provider: provider,
                resetBaseline: resetBaseline,
                initialToken: initialToken,
                onTerminal: { [weak self] _ in
                    await self?.recoverAfterScopeAccessLoss(
                        expectedSession: recoverySession,
                        expectedLoadGeneration: refreshLease.loadToken
                    )
                },
                onChange: { [weak self] in
                    guard let self else { return .retry }
                    return await self.libraryRefreshCoalescer.request { [weak self] in
                        await self?.performLibraryRefresh(lease: refreshLease).outcome ?? .retry
                    }
                }
            )
        }
    }

    private func requestLibraryRefresh() {
        guard let recoverySession = session, let refreshLease = currentMutationLease() else { return }
        let coalescer = libraryRefreshCoalescer
        Task { [weak self] in
            let outcome = await coalescer.request { [weak self] in
                await self?.performLibraryRefresh(lease: refreshLease).outcome ?? .retry
            }
            if outcome == .terminal {
                await self?.recoverAfterScopeAccessLoss(
                    expectedSession: recoverySession,
                    expectedLoadGeneration: refreshLease.loadToken
                )
            }
        }
    }

    private func performLibraryRefresh(
        lease refreshLease: MobileLibraryMutationLease
    ) async -> MobileLibraryRefreshResult {
        guard !isRecoveringScope,
            refreshLease.isCurrent(loadToken: loadToken, sessionUID: session?.uid),
            let backend
        else { return .init(outcome: .retry, failureReason: .cancelled) }
        isRefreshingLibrary = true
        defer { isRefreshingLibrary = false }
        do {
            let refreshed = try await backend.loadTimeline()
            try Task.checkCancellation()
            try requireCurrentMutation(refreshLease)
            let previousUIDs = items.map(\.uid)
            let changed = await applyItems(refreshed, cached: false, authoritative: true)
            try requireCurrentMutation(refreshLease)
            if let thumbnailFeed {
                if changed {
                    scheduleThumbnailPrefetch(using: thumbnailFeed)
                }
                reconcileNewAssetThumbnails(previousUIDs: previousUIDs, using: thumbnailFeed)
            }
            // The same opaque server event token covers album mutations. Reuse this central foreground
            // refresh instead of adding a second poller; Collections reloads through its existing revision key.
            albumCatalogRevision &+= 1
            refreshLibrarySources()
            return .init(outcome: .refreshed, failureReason: nil)
        } catch is CancellationError {
            return .init(outcome: .retry, failureReason: .cancelled)
        } catch is any LibraryChangeTerminalError {
            return .init(outcome: .terminal, failureReason: .scopeAccessLost)
        } catch is any TimelineInventoryConvergenceError {
            return .init(outcome: .retry, failureReason: .pendingInventoryVisibility)
        } catch {
            DebugLog.log("timeline: foreground refresh failed - \(error)")
            return .init(outcome: .retry, failureReason: .other)
        }
    }

    private func apply(_ event: LibraryLoadEvent) {
        loadState = LibraryLoadPolicy.reduce(loadState, event)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
