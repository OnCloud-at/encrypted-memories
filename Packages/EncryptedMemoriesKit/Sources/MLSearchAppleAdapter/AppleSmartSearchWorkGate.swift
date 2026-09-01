import Foundation
import MLSearchCore
import MediaFeedCore
import PhotosCore

/// Synchronous indexing gate over the shared workload governor.
///
/// Combines current system pressure with active and recent viewport demand. The grace period keeps indexing
/// suspended until newly visible thumbnails have had time to arrive.
public final class AppleSmartSearchWorkGate: @unchecked Sendable {
    typealias DemandRefreshScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    private static let demandRefreshDelay: Duration = .seconds(2)

    private let visibleMediaDemandActive: @Sendable () -> Bool
    private let hostPermitsIndexing: @Sendable () -> Bool
    private let runtimeState: LibraryRuntimeState
    private let scheduleDemandRefresh: DemandRefreshScheduler
    private let governor = LibraryWorkloadGovernorPolicy()
    private let refreshLock = NSLock()
    private var demandRefreshScheduled = false
    private let indexingWakeLock = NSLock()
    private var indexingWake: (@Sendable () -> Void)?
    private var cacheArrivalWakeRegistration: ThumbnailFeedWakeRegistration?

    public init(
        feed: ThumbnailFeedCore,
        runtimeState: LibraryRuntimeState = .shared,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true }
    ) {
        self.visibleMediaDemandActive = {
            feed.hasActiveUserInteraction() || feed.hasRecentVisibleDemand()
        }
        self.runtimeState = runtimeState
        self.hostPermitsIndexing = hostPermitsIndexing
        self.scheduleDemandRefresh = Self.defaultDemandRefreshScheduler
        self.cacheArrivalWakeRegistration = feed.setOnCacheArrivalWake { [weak self] in
            guard let self else { return }
            let wake = self.indexingWakeLock.withLock { self.indexingWake }
            wake?()
        }
    }

    init(
        visibleMediaDemandActive: @escaping @Sendable () -> Bool,
        runtimeState: LibraryRuntimeState = .shared,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true },
        scheduleDemandRefresh: @escaping DemandRefreshScheduler = AppleSmartSearchWorkGate.defaultDemandRefreshScheduler
    ) {
        self.visibleMediaDemandActive = visibleMediaDemandActive
        self.runtimeState = runtimeState
        self.hostPermitsIndexing = hostPermitsIndexing
        self.scheduleDemandRefresh = scheduleDemandRefresh
    }

    public func setIndexingWake(_ callback: @escaping @Sendable () -> Void) {
        indexingWakeLock.withLock { indexingWake = callback }
    }

    public func permitsIndexing() -> Bool {
        guard hostPermitsIndexing() else { return false }

        let visibleDemand = publishCurrentVisibleDemand()
        let snapshot = runtimeState.snapshot()
        let signals = LibraryWorkloadSignals(
            thermalLevel: snapshot.thermalLevel,
            isLowPowerMode: snapshot.isLowPowerMode,
            hasVisibleMediaDemand: visibleDemand,
            hasActiveUserInitiatedTransfer: snapshot.activeUserTransferCount > 0
        )
        return !governor.budget(for: .backgroundSemanticIndexing, signals: signals).shouldYield
    }

    private func publishCurrentVisibleDemand() -> Bool {
        let visibleDemand = visibleMediaDemandActive()
        runtimeState.update { $0.hasVisibleMediaDemand = visibleDemand }
        if visibleDemand { scheduleRefreshIfNeeded() }
        return visibleDemand
    }

    private func scheduleRefreshIfNeeded() {
        let shouldSchedule = refreshLock.withLock {
            guard !demandRefreshScheduled else { return false }
            demandRefreshScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        scheduleDemandRefresh { [weak self] in
            guard let self else { return }
            self.refreshLock.withLock { self.demandRefreshScheduled = false }
            _ = self.publishCurrentVisibleDemand()
        }
    }

    private static let defaultDemandRefreshScheduler: DemandRefreshScheduler = { refresh in
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: demandRefreshDelay)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }
}
