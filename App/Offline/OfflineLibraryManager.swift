import Foundation
import MediaByteCache
import MediaCache
import MediaLocationCore
import Observation
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import TimelineCore

/// Owns the local offline-cache roots and bridges the Settings window to the running thumbnail feed.
/// The thumbnail crawl is mandatory grid infrastructure and is independent from the Offline Library toggle.
@MainActor
@Observable
final class OfflineLibraryManager {
    static let shared = OfflineLibraryManager()

    /// Disk thumbnail cache (decoded grid previews) - shared with `MainView`'s `ThumbnailFeed`. Encrypted
    /// per-account (AES-GCM); `configure(session:)` installs a key derived from the restored Proton session.
    let cache = ThumbnailCache(
        namespace: "thumbnails",
        derivative: "thumbnail",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Larger display-preview derivatives, persisted when the viewer fetches them. Also encrypted.
    let previewCache = ThumbnailCache(
        namespace: "previews",
        derivative: "preview",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Full-resolution originals viewed in the photo viewer, persisted encrypted when the Offline Library is on
    /// and bounded by an LRU size cap.
    let originalsCache = ThumbnailCache(
        namespace: "originals",
        derivative: "original",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )

    /// Whole-library GPS index for the Map view. GPS is sensitive PII, so it is encrypted at rest
    /// (`PhotoLocationStore`, same per-account key as the media caches) and decrypted only into the in-memory
    /// `PhotoLocationIndex`. Filled by a low-priority background crawl behind the thumbnail crawl; purged on
    /// sign-out. The Map UI binds to `locationIndex`.
    let locationStore = PhotoLocationStore()
    let locationIndex = PhotoLocationIndex()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false
    private var locationCrawlGeneration: UInt64 = 0
    private var locationConfigurationGeneration: UInt64 = 0
    private var locationCrawlStartTask: Task<Void, Never>?
    private var locationConfigurationTask: Task<Void, Never>?
    private var configuredAccountUID: String?
    private var latestLocationInventoryTask: Task<LocationCrawlInventory, Never>?

    /// Persisted switch for retaining viewed originals in the encrypted cache up to the configured cap.
    /// Thumbnail crawling is independent of this setting.
    private(set) var offlineEnabled: Bool

    /// Current originals-cache byte budget, or `nil` when the user chose "unbounded".
    var originalsCapBytes: Int64? {
        let d = UserDefaults.standard
        if d.bool(forKey: AppSettingsKey.offlineOriginalsCapUnlimited) { return nil }
        let gb =
            d.object(forKey: AppSettingsKey.offlineOriginalsCapGB) as? Double
            ?? AppSettingsDefault.offlineOriginalsCapGB
        return Int64(max(0, gb) * 1_073_741_824)  // Convert GiB to bytes.
    }

    /// Latest computed status for the Developer/Cache surface (refreshed on demand).
    private(set) var status = OfflineCacheStatus()

    /// True only while thumbnails for newly discovered authoritative assets remain unresolved.
    private(set) var isLibraryActivityActive = false
    private let thumbnailUpdateCoordinator = LibraryThumbnailUpdateCoordinator()

    private var feed: ThumbnailFeed?
    private var statsProvider: (any LibraryStatsProvider)?
    /// Live count of photos currently loaded into the timeline (pushed by `MainView`).
    var liveAssetCount = 0

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled,
            AppSettingsKey.offlineOriginalsCapUnlimited: AppSettingsDefault.offlineOriginalsCapUnlimited,
            AppSettingsKey.offlineOriginalsCapGB: AppSettingsDefault.offlineOriginalsCapGB,
        ])
        offlineEnabled = defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Called by `MainView` after backend and feed creation. Thumbnail crawling is grid infrastructure
    /// and remains enabled independently of the offline-originals setting.
    func attach(feed: ThumbnailFeed, stats: any LibraryStatsProvider) {
        self.feed = feed
        self.statsProvider = stats
        Task {
            await feed.setPrefetchEnabled(OfflineLibraryPolicy.shouldCrawlThumbnails(offlineEnabled: offlineEnabled))
        }
    }

    /// Clears account-derived values from observable Settings state before asynchronous teardown begins.
    func prepareForAccountTeardown() {
        liveAssetCount = 0
        isLibraryActivityActive = false
        status = OfflineCacheStatus()
    }

    func reconcileNewAssetThumbnails(currentUIDs: [PhotoUID], addedUIDs: [PhotoUID]) {
        guard let feed else {
            thumbnailUpdateCoordinator.cancel()
            return
        }
        thumbnailUpdateCoordinator.reconcile(
            currentUIDs: currentUIDs,
            addedUIDs: addedUIDs,
            onStateChange: { [weak self] state in
                self?.isLibraryActivityActive = state.isActive
            },
            resolver: { uids, enqueueMissing in
                await feed.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
            }
        )
    }

    /// Installs the per-account encryption key for the thumbnail + preview caches. Called at sign-in,
    /// before the grid starts crawling. The key is derived from the
    /// already-unlocked session secret, so startup needs only the session Keychain item rather than a second
    /// Keychain prompt for a separate cache key item.
    func configure(session: ProtonSession) {
        let context = LocalMediaCacheContext(accountUID: session.uid, keyPassword: session.keyPassword)
        context.configure(cache, previewCache, originalsCache)
        let previousCrawlStarted = locationCrawlStarted
        let previousAccountUID = configuredAccountUID
        let accountChanged = previousAccountUID != nil && previousAccountUID != context.accountUID
        locationCrawlGeneration &+= 1
        locationConfigurationGeneration &+= 1
        let configurationGeneration = locationConfigurationGeneration
        locationCrawlStarted = false
        configuredAccountUID = context.accountUID
        let previousConfiguration = locationConfigurationTask
        let previousStarter = locationCrawlStartTask
        previousConfiguration?.cancel()
        previousStarter?.cancel()
        if accountChanged {
            locationIndex.replaceAll([])
            locationIndex.updateScanProgress(PhotoLocationScanProgress())
        }
        let accountUID = context.accountUID
        let key = context.encryptionKey
        locationConfigurationTask = Task { @MainActor [weak self, previousConfiguration, previousStarter] in
            await previousConfiguration?.value
            await previousStarter?.value
            guard let self,
                !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            if previousCrawlStarted {
                await self.locationCrawl.cancel()
            }
            guard !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            let sessionLease = self.locationStore.configure(accountUID: accountUID, key: key)
            let store = self.locationStore
            let snapshot = await Task.detached(priority: .utility) {
                store.loadSnapshot()
            }.value
            guard !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID,
                self.locationStore.isCurrentSessionLease(sessionLease)
            else { return }
            self.locationIndex.replaceAll(snapshot)
            self.locationConfigurationTask = nil
        }
        if let cap = originalsCapBytes {
            let oc = originalsCache
            Task.detached { oc.enforceByteCap(cap) }
        }
    }

    /// Stops account-bound location and activity work before any facade or cache owner is closed.
    /// Kept separate from cache deletion so the shared account teardown stages stay explicit.
    func stopForAccountTeardown() async {
        let activeLocationCrawlStarter = locationCrawlStartTask
        let activeLocationConfiguration = locationConfigurationTask
        let activeFeed = feed
        locationCrawlGeneration &+= 1
        locationConfigurationGeneration &+= 1
        activeLocationCrawlStarter?.cancel()
        activeLocationConfiguration?.cancel()
        locationCrawlStartTask = nil
        locationConfigurationTask = nil
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        locationCrawlStarted = false
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        feed = nil
        statsProvider = nil
        liveAssetCount = 0
        configuredAccountUID = nil
        latestLocationInventoryTask?.cancel()
        latestLocationInventoryTask = nil
        await activeLocationConfiguration?.value
        await activeLocationCrawlStarter?.value
        await activeThumbnailUpdateTask?.value
        await activeFeed?.stopPrefetch()
        await locationCrawl.cancel()
        // A non-cooperative metadata probe can return after the eager UI clear above but before the
        // joined Core cancellation completes. Clear once more at the retirement barrier.
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
    }

    /// Erases encrypted thumbnail/preview blobs, their account keys, location data, and streamed
    /// video blocks after account-owned workers and stores have stopped.
    func purgeCachesForAccountTeardown() async {
        let cache = cache
        let previewCache = previewCache
        let originalsCache = originalsCache
        let locationStore = locationStore
        await Task.detached(priority: .utility) {
            cache.clearForSignOut()
            previewCache.clearForSignOut()
            originalsCache.clearForSignOut()
            VideoByteRangeCache.shared.clearAll()
            locationStore.clear()
        }.value
    }

    /// Starts one resumable, throttled GPS crawl for the Map view. It yields to visible thumbnail work and
    /// persists the encrypted index periodically. Repeated calls are safe.
    func startLocationCrawl(items: [PhotoItem], metadata: any PhotoMetadataProvider) {
        let inventoryTask = Task.detached(priority: .utility) {
            LocationCrawlInventory(items: items)
        }
        latestLocationInventoryTask?.cancel()
        latestLocationInventoryTask = inventoryTask
        if locationCrawlStarted,
            locationIndex.scanProgress.phase == .completed || locationIndex.scanProgress.phase == .failed
        {
            locationCrawlStarted = false
        }
        guard !locationCrawlStarted, !items.isEmpty else { return }
        locationCrawlStarted = true
        locationCrawlGeneration &+= 1
        let crawlGeneration = locationCrawlGeneration
        let accountUID = configuredAccountUID ?? ""
        let previousStarter = locationCrawlStartTask
        let previousConfiguration = locationConfigurationTask
        previousStarter?.cancel()
        let index = locationIndex
        let store = locationStore
        let feed = self.feed
        let governor = LibraryWorkloadGovernorPolicy()
        locationCrawlStartTask = Task { @MainActor [weak self, previousStarter, previousConfiguration] in
            await previousConfiguration?.value
            await previousStarter?.value
            guard let self,
                !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            let initialInventory = await inventoryTask.value
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            // Give the thumbnail crawl a head start, then crawl GPS whenever the grid isn't actively
            // demanding on-screen thumbnails - so the Map crawl shares the rate-limit budget as P2 and
            // never stalls scrolling (thumbnails are P1).
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            await self.locationCrawl.start(
                uids: initialInventory.uids,
                captureDates: initialInventory.captureDates,
                accountUID: accountUID,
                location: LocationCrawl.metadataProbe(metadata),
                index: index,
                store: store,
                // P2: back off while the grid has visible demand (scrolling or queued visible-priority
                // thumbnails). Do not use `hasPendingThumbnailWork()`: it includes whole-library fill and can
                // starve the Map behind a large thumbnail crawl.
                shouldYield: {
                    let visibleDemand = await feed?.hasVisibleThumbnailPressure() ?? false
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: visibleDemand)
                    ).shouldYield
                },
                log: { DebugLog.log($0) },
                inventory: { @MainActor [weak self] in
                    guard let task = self?.latestLocationInventoryTask else {
                        return LocationCrawlInventory()
                    }
                    return await task.value
                }
            )
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                self.configuredAccountUID == accountUID
            else {
                await self.locationCrawl.cancel()
                return
            }
        }
    }

    func restartLocationCrawl(items: [PhotoItem], metadata: any PhotoMetadataProvider) {
        guard !items.isEmpty else { return }
        locationCrawlStarted = false
        startLocationCrawl(items: items, metadata: metadata)
    }

    /// Keeps map pins and the encrypted snapshot aligned with a successful library mutation. A restore only
    /// restarts GPS probing when the user already activated Map work this session.
    func reconcileLocations(
        items: [PhotoItem],
        metadata: any PhotoMetadataProvider,
        recrawlRestoredItems: Bool
    ) async {
        let uids = await Task.detached(priority: .userInitiated) { Set(items.map(\.uid)) }.value
        await locationIndex.retainOnly(uids, persistTo: locationStore)
        guard recrawlRestoredItems, locationCrawlStarted else { return }
        locationCrawlStarted = false
        startLocationCrawl(items: items, metadata: metadata)
    }

    /// Persists the Offline Photo Library setting. Enabled mode stores viewed originals in the encrypted
    /// `originals` cache; disabled mode stops retention and lets Settings purge existing originals.
    /// Thumbnail crawling remains enabled by `OfflineLibraryPolicy`.
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Persists the originals-cache cap and enforces it immediately - lowering it (or switching from unbounded to
    /// bounded) purges the least-recently-used originals down to the new budget right away.
    func setOriginalsCap(unlimited: Bool, gigabytes: Double) {
        let d = UserDefaults.standard
        d.set(unlimited, forKey: AppSettingsKey.offlineOriginalsCapUnlimited)
        d.set(gigabytes, forKey: AppSettingsKey.offlineOriginalsCapGB)
        guard let cap = originalsCapBytes else { return }  // An unbounded cache needs no cap enforcement.
        let oc = originalsCache
        Task {
            await Task.detached { oc.enforceByteCap(cap) }.value  // file I/O off the main actor
            await refreshStatus()
        }
    }

    /// Clears the full-resolution originals cache when retention is disabled. Thumbnail and preview caches
    /// and the account key remain available to the grid.
    func purgeOriginalsCache() async {
        await originalsCache.clear()
        await refreshStatus()
    }

    /// Erases all account media caches and streamed video blocks while retaining the account key. The grid
    /// repopulates them on its next crawl. Callers invoke this only from the explicit cache-delete action.
    func deleteOfflineCache() async {
        if let feed {
            await feed.clearCacheAndRestartPrefetch()
        } else {
            await cache.clear()
        }
        await previewCache.clear()
        await originalsCache.clear()
        await VideoByteRangeCache.shared.clearAllAsync()  // also drop streamed video blocks
        await refreshStatus()
    }

    /// Recomputes `status` from the cache actors, the feed, and the diagnostics counters.
    @discardableResult
    func refreshStatus() async -> OfflineCacheStatus {
        let prefetch = await feed?.prefetchStatus()
        let metadataRows = await statsProvider?.metadataRowCount() ?? 0
        let totalAssets = max(liveAssetCount, metadataRows)
        // Source-aware feeds report coverage for the primary projection only. Physical cache bytes still
        // include authorized analysis-only derivatives and remain reflected in `cacheSizeBytes` below.
        let onDisk = prefetch?.diskFileCount ?? cache.diskFileCount()

        var s = OfflineCacheStatus()
        s.offlineEnabled = offlineEnabled
        s.totalAssets = totalAssets
        s.metadataRows = metadataRows
        s.thumbnailsOnDisk = onDisk
        s.thumbnailsMissing = max(0, totalAssets - onDisk)
        s.ramDecodedEstimate = prefetch?.ramDecodedCount ?? 0
        s.prefetchQueueDepth = prefetch?.currentQueueLength ?? 0
        s.activePrefetchJobs = prefetch?.activeJobs ?? 0
        // Thumbnails always crawl, so the offline toggle never reports "disabled" here.
        s.prefetchPausedReason = prefetch?.pausedReason ?? "none"
        s.failedThumbnailCount = prefetch?.failed ?? 0
        s.cacheSizeBytes = cache.diskSizeBytes()
        s.previewCacheSizeBytes = previewCache.diskSizeBytes()
        s.originalsCacheSizeBytes = originalsCache.diskSizeBytes()
        s.lastError = prefetch?.lastErrors.last
        status = s
        return s
    }
}
