import Foundation
import PhotosCore

/// Platform-neutral thermal pressure level. Platform adapters map their OS signal
/// (`ProcessInfo.thermalState` on both Apple platforms) into this so the throttle table
/// lives once in core.
public enum BackupThermalLevel: Int, Sendable, Comparable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: BackupThermalLevel, rhs: BackupThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The environment signals that throttle backup work. Platform layers fill these from
/// ProcessInfo/NWPathMonitor equivalents; core never reads OS state itself.
public struct BackupThrottleInputs: Sendable, Equatable {
    public var thermalLevel: BackupThermalLevel
    public var isLowPowerMode: Bool
    /// False when there is currently no usable network path. The runner waits without spending an
    /// item's retry budget and resumes from the durable queue as soon as the path returns.
    public var isNetworkAvailable: Bool
    /// Low Data Mode / constrained path - treat like low power.
    public var isNetworkConstrained: Bool
    /// Cellular/hotspot - keep going, but single-file, unless the person turned mobile data off.
    public var isNetworkExpensive: Bool
    /// The "Use Cellular Data" setting. When false, an expensive network holds the backup until Wi-Fi or Ethernet.
    public var usesMobileData: Bool

    public init(
        thermalLevel: BackupThermalLevel = .nominal,
        isLowPowerMode: Bool = false,
        isNetworkAvailable: Bool = true,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false,
        usesMobileData: Bool = true
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.isNetworkAvailable = isNetworkAvailable
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
        self.usesMobileData = usesMobileData
    }

    /// Maps the shared runtime snapshot of a platform adapter, so every backup upload path reads the same signals.
    public init(runtime snapshot: LibraryRuntimeSnapshot, usesMobileData: Bool) {
        let thermal: BackupThermalLevel =
            switch snapshot.thermalLevel {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            }
        self.init(
            thermalLevel: thermal,
            isLowPowerMode: snapshot.isLowPowerMode,
            isNetworkAvailable: snapshot.network.isReachable,
            isNetworkConstrained: snapshot.network.isConstrained,
            isNetworkExpensive: snapshot.network.isExpensive,
            usesMobileData: usesMobileData
        )
    }

    /// The device is online on cellular data or Personal Hotspot, and the person turned mobile data off for backups.
    /// This is never "offline": viewing and downloading keep working.
    public var waitsForWiFi: Bool {
        isNetworkAvailable && isNetworkExpensive && !usesMobileData
    }

    public static let unconstrained = BackupThrottleInputs()
}

/// One shared concurrency table for backup sync, mapping inputs to the number of in-flight items.
/// `0` means "pause until conditions improve" - the runner idles without failing anything.
public struct BackupThrottlePolicy: Sendable, Equatable {
    /// Concurrent items under unconstrained conditions. The shared workload governor reduces this
    /// value for thermal pressure, Low Power Mode, or constrained network conditions.
    public var baseConcurrency: Int
    public var governor: LibraryWorkloadGovernorPolicy

    public init(baseConcurrency: Int = 6, governor: LibraryWorkloadGovernorPolicy = LibraryWorkloadGovernorPolicy()) {
        self.baseConcurrency = max(1, baseConcurrency)
        self.governor = governor
    }

    public func maxConcurrentItems(for inputs: BackupThrottleInputs) -> Int {
        guard inputs.isNetworkAvailable, !inputs.waitsForWiFi else { return 0 }
        return governor.budget(
            for: .userInitiatedBackup,
            signals: LibraryWorkloadSignals(
                thermalLevel: inputs.thermalLevel.libraryLevel,
                isLowPowerMode: inputs.isLowPowerMode,
                isNetworkConstrained: inputs.isNetworkConstrained,
                isNetworkExpensive: inputs.isNetworkExpensive,
                hasActiveUserInitiatedTransfer: true
            ),
            baseConcurrency: baseConcurrency
        ).maxConcurrentItems
    }
}

private extension BackupThermalLevel {
    var libraryLevel: LibraryThermalLevel {
        switch self {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }
}
