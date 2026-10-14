import Foundation
import PhotosCore

/// One account's GPS crawl session for the Map, shared by iOS, iPadOS and macOS. It owns the start generation, the
/// delayed start, the privacy stop, and the crawl inventory. Pause, resume and restart go through it; the hosts keep
/// the map prewarmer, the account checks and the teardown order.
@MainActor
public final class LocationCrawlSession {
    /// What differs between the platforms.
    public struct Platform: Sendable, Equatable {
        /// How long the thumbnail crawl runs alone before GPS probing starts.
        public var headStart: Duration
        /// Stops an earlier crawl and requires a current store session before the delayed start. Without it, the
        /// account configuration stops the earlier crawl.
        public var requiresStoreSession: Bool

        public init(headStart: Duration, requiresStoreSession: Bool) {
            self.headStart = headStart
            self.requiresStoreSession = requiresStoreSession
        }
    }

    /// What one start needs from the host.
    public struct Start {
        public var accountUID: String
        public var location: @Sendable (PhotoUID) async -> LocationProbeResult
        /// Whether the grid shows thumbnails that it still waits for.
        public var visibleDemand: @Sendable () async -> Bool
        /// Pauses the crawl regardless of visible demand, for example while the app is inactive.
        public var yieldsAlways: @Sendable () async -> Bool
        public var log: @Sendable (String) -> Void
        /// The host's own account check, made at every step together with the generation.
        public var isCurrent: @MainActor () -> Bool
        /// Host work that must end before the crawl starts, for example the account configuration.
        public var awaiting: Task<Void, Never>?
        /// Starts the crawl again through the host when the inventory changed after the crawl last read it. Nil
        /// leaves a finished crawl until the next start.
        public var restartForNewerInventory: (@MainActor () -> Void)?

        public init(
            accountUID: String,
            location: @escaping @Sendable (PhotoUID) async -> LocationProbeResult,
            visibleDemand: @escaping @Sendable () async -> Bool,
            yieldsAlways: @escaping @Sendable () async -> Bool = { false },
            log: @escaping @Sendable (String) -> Void = { _ in },
            isCurrent: @escaping @MainActor () -> Bool,
            awaiting: Task<Void, Never>? = nil,
            restartForNewerInventory: (@MainActor () -> Void)? = nil
        ) {
            self.accountUID = accountUID
            self.location = location
            self.visibleDemand = visibleDemand
            self.yieldsAlways = yieldsAlways
            self.log = log
            self.isCurrent = isCurrent
            self.awaiting = awaiting
            self.restartForNewerInventory = restartForNewerInventory
        }
    }

    public let crawl: LocationCrawl
    public let index: PhotoLocationIndex
    public let store: PhotoLocationStore
    /// True from a start until a pause, a restart or the retirement.
    public private(set) var isStarted = false
    private let platform: Platform
    private let isEnabled: @MainActor () -> Bool
    private var generation: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var privacyStopTask: Task<Void, Never>?
    private var inventoryTask: Task<LocationCrawlInventory, Never>?
    private var inventoryRevision: UInt64 = 0
    private var crawlInventoryRevision: UInt64 = 0

    public init(
        platform: Platform,
        index: PhotoLocationIndex = PhotoLocationIndex(),
        store: PhotoLocationStore = PhotoLocationStore(),
        crawl: LocationCrawl = LocationCrawl(),
        isEnabled: @escaping @MainActor () -> Bool = { MapAndPlacesPolicy.isEnabled() }
    ) {
        self.platform = platform
        self.index = index
        self.store = store
        self.crawl = crawl
        self.isEnabled = isEnabled
    }

    /// The task that started the crawl last, for hosts that join it.
    public var startingTask: Task<Void, Never>? { startTask }

    /// Builds the crawl inventory of `items` off the main actor. A running crawl reads it at its next checkpoint.
    public func updateInventory(_ items: [PhotoItem]) {
        inventoryTask?.cancel()
        inventoryTask = Task.detached(priority: .utility) { LocationCrawlInventory(items: items) }
        inventoryRevision &+= 1
    }

    /// The crawl ended (completed or failed) before it read the latest inventory.
    public var finishedWithOutdatedInventory: Bool {
        isStarted && crawlInventoryRevision != inventoryRevision
            && (index.scanProgress.phase == .completed || index.scanProgress.phase == .failed)
    }

    /// Starts the crawl once; repeated calls do nothing until a pause, restart or retirement. `items` builds the
    /// inventory when none exists yet.
    public func start(items: [PhotoItem], _ start: Start) {
        guard !isStarted else { return }
        isStarted = true
        generation &+= 1
        let crawlGeneration = generation
        let previousStarter = startTask
        let previousPrivacyStop = privacyStopTask
        let awaiting = start.awaiting
        previousStarter?.cancel()
        if inventoryTask == nil {
            inventoryTask = Task.detached(priority: .utility) { LocationCrawlInventory(items: items) }
        }
        let initialInventory = inventoryTask
        crawlInventoryRevision = inventoryRevision
        let index = index
        let store = store
        let crawl = crawl
        let platform = platform
        let governor = LibraryWorkloadGovernorPolicy()
        startTask = Task { [weak self, previousStarter, previousPrivacyStop, awaiting] in
            await previousPrivacyStop?.value
            await awaiting?.value
            await previousStarter?.value
            guard let self, self.admits(crawlGeneration, start) else { return }
            var sessionLease: PhotoLocationStore.SessionLease?
            if platform.requiresStoreSession {
                // Startup already restored the account's location cache. Map entry only resumes its crawl.
                await crawl.cancel()
                guard self.admits(crawlGeneration, start) else { return }
                guard let lease = store.captureSessionLease() else { return }
                sessionLease = lease
            }
            let inventory = await initialInventory?.value ?? LocationCrawlInventory()
            guard self.admits(crawlGeneration, start) else { return }
            // Give the thumbnail crawl a head start, then crawl GPS whenever the grid does not wait for visible
            // thumbnails. Do not use `hasPendingThumbnailWork()`: it includes whole-library fill and can starve
            // the Map behind a large thumbnail crawl.
            do {
                try await Task.sleep(for: platform.headStart)
            } catch {
                return
            }
            guard sessionLease.map(store.isCurrentSessionLease) ?? true, self.admits(crawlGeneration, start)
            else { return }
            await crawl.start(
                uids: inventory.uids,
                captureDates: inventory.captureDates,
                accountUID: start.accountUID,
                location: start.location,
                index: index,
                store: store,
                shouldYield: { [yieldsAlways = start.yieldsAlways, visibleDemand = start.visibleDemand] in
                    if await yieldsAlways() { return true }
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: await visibleDemand())
                    ).shouldYield
                },
                log: start.log,
                inventory: { @MainActor [weak self] in await self?.latestInventory() ?? LocationCrawlInventory() }
            )
            guard !Task.isCancelled, crawlGeneration == self.generation, start.isCurrent() else {
                await crawl.cancel()
                return
            }
            if let restart = start.restartForNewerInventory, self.crawlInventoryRevision != self.inventoryRevision {
                self.isStarted = false
                restart()
            }
        }
    }

    /// Lets the next start run again, for example after the crawl finished or the library changed.
    public func prepareRestart() {
        isStarted = false
    }

    /// Stops the crawl for privacy (Map and Places off). A later start waits until it stopped.
    public func pause() {
        generation &+= 1
        isStarted = false
        startTask?.cancel()
        let previousStop = privacyStopTask
        let crawl = crawl
        privacyStopTask = Task {
            await previousStop?.value
            await crawl.cancel()
        }
    }

    /// Rejects every admitted start of an earlier account configuration. Returns the cancelled start task, which
    /// stays the predecessor of the next start.
    @discardableResult
    public func invalidate() -> Task<Void, Never>? {
        generation &+= 1
        isStarted = false
        startTask?.cancel()
        return startTask
    }

    /// Ends the session's work for the account teardown and forgets its inventory. The caller joins the returned
    /// start task, then cancels `crawl`.
    public func retire() -> Task<Void, Never>? {
        let starter = startTask
        generation &+= 1
        starter?.cancel()
        startTask = nil
        isStarted = false
        inventoryTask?.cancel()
        inventoryTask = nil
        return starter
    }

    /// Forgets the inventory and the started state for a sign-out without cancelling the start task: the host's
    /// account check rejects it, and the teardown joins `startingTask` before it cancels `crawl`.
    public func resetForTeardown() {
        isStarted = false
        inventoryTask?.cancel()
        inventoryTask = nil
    }

    private func admits(_ crawlGeneration: UInt64, _ start: Start) -> Bool {
        !Task.isCancelled && crawlGeneration == generation && start.isCurrent() && isEnabled()
    }

    private func latestInventory() async -> LocationCrawlInventory {
        guard let task = inventoryTask else { return LocationCrawlInventory() }
        let revision = inventoryRevision
        let inventory = await task.value
        crawlInventoryRevision = max(crawlInventoryRevision, revision)
        return inventory
    }
}
