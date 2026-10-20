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
    private var runtimeObservation: Task<Void, Never>?
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

    /// The callback also runs when a runtime input of the gate changes (thermal state, Low Power Mode, visible demand,
    /// playback, search, user transfers), so a closed gate opens again without a polling loop.
    public func setIndexingWake(_ callback: @escaping @Sendable () -> Void) {
        indexingWakeLock.withLock {
            indexingWake = callback
            guard runtimeObservation == nil else { return }
            // The baseline is the state at registration, so a change before the task runs still wakes.
            let baseline = GateInputs(runtimeState.snapshot())
            let updates = runtimeState.updates()
            runtimeObservation = Task { [weak self] in
                var last = baseline
                for await snapshot in updates {
                    let inputs = GateInputs(snapshot)
                    guard inputs != last else { continue }
                    last = inputs
                    guard let self else { return }
                    let wake = self.indexingWakeLock.withLock { self.indexingWake }
                    wake?()
                }
            }
        }
    }

    deinit {
        runtimeObservation?.cancel()
    }

    public func permitsIndexing() -> Bool {
        guard hostPermitsIndexing() else { return false }

        let visibleDemand = publishCurrentVisibleDemand()
        let snapshot = runtimeState.snapshot()
        let signals = LibraryWorkloadSignals(
            thermalLevel: snapshot.thermalLevel,
            isLowPowerMode: snapshot.isLowPowerMode,
            hasVisibleMediaDemand: visibleDemand || snapshot.activeVideoPlaybackCount > 0
                || snapshot.activeSearchCount > 0,
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

    /// The runtime values that `permitsIndexing` reads. Other runtime changes, such as the network path, never wake the
    /// indexing loop.
    private struct GateInputs: Equatable {
        let thermalLevel: LibraryThermalLevel
        let isLowPowerMode: Bool
        let hasVisibleMediaDemand: Bool
        let isPlayingVideo: Bool
        let isSearching: Bool
        let hasUserTransfer: Bool

        init(_ snapshot: LibraryRuntimeSnapshot) {
            thermalLevel = snapshot.thermalLevel
            isLowPowerMode = snapshot.isLowPowerMode
            hasVisibleMediaDemand = snapshot.hasVisibleMediaDemand
            isPlayingVideo = snapshot.activeVideoPlaybackCount > 0
            isSearching = snapshot.activeSearchCount > 0
            hasUserTransfer = snapshot.activeUserTransferCount > 0
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
