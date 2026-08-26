import Foundation
import Network
import PhotosCore

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

/// The process-wide Apple signal source for library resource policy.
///
/// Feature modules never create their own network, thermal, power or memory-pressure observers.
/// They consume `LibraryRuntimeState` or a feature-specific projection of it. UIKit/AppKit supply
/// lifecycle opportunity through `setExecutionOpportunity(_:)`.
@MainActor
public final class AppleLibraryRuntimeAdapter {
    public static let shared = AppleLibraryRuntimeAdapter()

    private static let memoryWarningLatchDuration: Duration = .seconds(20)
    private let runtimeState: LibraryRuntimeState
    private let memoryGovernor: MemoryPressureGovernor
    private let networkMonitor: NWPathMonitor
    private let networkQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.library-runtime-network", qos: .utility)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var notificationTokens: [NSObjectProtocol] = []
    private var warningDecayTask: Task<Void, Never>?
    private var installed = false
    private var dispatchPressure: MemoryConditions.Pressure = .normal
    private var memoryWarningLatched = false

    private init() {
        runtimeState = .shared
        memoryGovernor = .shared
        networkMonitor = NWPathMonitor()
    }

    /// Installs every dynamic Apple signal observer exactly once per process.
    public func install() {
        guard !installed else { return }
        installed = true

        Task {
            await LibraryResourceCoordinator.shared.startObserving()
        }
        installNetworkMonitor()
        installMemoryPressureSource()
        installProcessNotifications()
        publishMemoryConditions()
    }

    /// Platform lifecycle adapters provide opportunity; Core remains framework-free.
    public func setExecutionOpportunity(_ opportunity: LibraryExecutionOpportunity) {
        runtimeState.update { $0.executionOpportunity = opportunity }
        publishMemoryConditions()
    }

    private func installNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let state = LibraryNetworkState(
                isReachable: path.status == .satisfied,
                isConstrained: path.isConstrained,
                isExpensive: path.isExpensive
            )
            Task { @MainActor [weak self] in
                self?.runtimeState.update { $0.network = state }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let data = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                if data.contains(.critical) {
                    self.dispatchPressure = .critical
                } else if data.contains(.warning) {
                    self.dispatchPressure = .warning
                } else {
                    self.dispatchPressure = .normal
                    self.clearMemoryWarningLatch()
                }
                self.publishMemoryConditions()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func installProcessNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.publishMemoryConditions() }
            })
        notificationTokens.append(
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.publishMemoryConditions() }
            })

        #if canImport(UIKit) && !os(watchOS)
            notificationTokens.append(
                center.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.latchMemoryWarning() }
                })
        #endif
    }

    private func latchMemoryWarning() {
        memoryWarningLatched = true
        publishMemoryConditions()
        warningDecayTask?.cancel()
        warningDecayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.memoryWarningLatchDuration)
            guard !Task.isCancelled else { return }
            self?.memoryWarningLatched = false
            self?.publishMemoryConditions()
        }
    }

    private func clearMemoryWarningLatch() {
        warningDecayTask?.cancel()
        warningDecayTask = nil
        memoryWarningLatched = false
    }

    private func publishMemoryConditions() {
        let info = ProcessInfo.processInfo
        let opportunity = runtimeState.snapshot().executionOpportunity
        memoryGovernor.update(
            MemoryConditions(
                pressure: AppleRuntimeMemoryPolicy.pressure(
                    dispatchPressure: dispatchPressure,
                    memoryWarningLatched: memoryWarningLatched,
                    isBackgrounded: opportunity == .backgroundPermitted || opportunity == .suspended
                ),
                thermal: Self.thermal(info.thermalState),
                lowPowerMode: info.isLowPowerModeEnabled
            ))
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> MemoryConditions.Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}

/// Pure merger for independent memory-pressure signals. A UIKit warning is purge-now; backgrounding
/// proactively reduces future budgets but never masks a stronger Dispatch pressure event.
public enum AppleRuntimeMemoryPolicy {
    public static func pressure(
        dispatchPressure: MemoryConditions.Pressure,
        memoryWarningLatched: Bool,
        isBackgrounded: Bool
    ) -> MemoryConditions.Pressure {
        if memoryWarningLatched || dispatchPressure == .critical { return .critical }
        if dispatchPressure == .warning || isBackgrounded { return .warning }
        return .normal
    }
}
