import PhotosCore

/// The environment signals that throttle backup work. Platform layers fill these from
/// ProcessInfo/NWPathMonitor equivalents; core never reads OS state itself.
public struct BackupThrottleInputs: Sendable, Equatable {
    public var thermalLevel: LibraryThermalLevel
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
    /// False until the platform reported its first network path since launch. The other network values are then only
    /// defaults.
    public var isNetworkDetermined: Bool
    /// True while the app runs only in an OS background window: no scene is in the foreground. Nobody then watches an
    /// automatic pass, so a background window may run it.
    public var isAppInBackground: Bool

    public init(
        thermalLevel: LibraryThermalLevel = .nominal,
        isLowPowerMode: Bool = false,
        isNetworkAvailable: Bool = true,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false,
        usesMobileData: Bool = true,
        isNetworkDetermined: Bool = true,
        isAppInBackground: Bool = false
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.isNetworkAvailable = isNetworkAvailable
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
        self.usesMobileData = usesMobileData
        self.isNetworkDetermined = isNetworkDetermined
        self.isAppInBackground = isAppInBackground
    }

    /// Maps the shared runtime snapshot of a platform adapter, so every backup upload path reads the same signals.
    /// Before the first network path, the network may be cellular: with mobile data off, the backup waits for it.
    public init(runtime snapshot: LibraryRuntimeSnapshot, usesMobileData: Bool) {
        self.init(
            thermalLevel: snapshot.thermalLevel,
            isLowPowerMode: snapshot.isLowPowerMode,
            isNetworkAvailable: snapshot.network.isReachable,
            isNetworkConstrained: snapshot.network.isConstrained,
            isNetworkExpensive: snapshot.network.isExpensive || (!snapshot.network.isDetermined && !usesMobileData),
            usesMobileData: usesMobileData,
            isNetworkDetermined: snapshot.network.isDetermined,
            isAppInBackground: snapshot.executionOpportunity >= .backgroundPermitted
        )
    }

    /// The device is online on cellular data or Personal Hotspot, and the person turned mobile data off for backups.
    /// This is never "offline": viewing and downloading keep working.
    public var waitsForWiFi: Bool {
        isNetworkAvailable && isNetworkExpensive && !usesMobileData
    }

    /// A reachable path that permits backup traffic can end a Wi-Fi wait. An offline transition keeps the wait.
    public var canEndWiFiWait: Bool {
        isNetworkAvailable && !waitsForWiFi
    }

    /// No network path has arrived yet, and mobile data is off. Uploads stay held, but a backup pass waits for the
    /// first path instead of reporting "Waiting for Wi-Fi": the network is often Wi-Fi.
    public var waitsForFirstNetworkPath: Bool {
        !isNetworkDetermined && !usesMobileData
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
                thermalLevel: inputs.thermalLevel,
                isLowPowerMode: inputs.isLowPowerMode,
                isNetworkConstrained: inputs.isNetworkConstrained,
                isNetworkExpensive: inputs.isNetworkExpensive,
                hasActiveUserInitiatedTransfer: true
            ),
            baseConcurrency: baseConcurrency
        ).maxConcurrentItems
    }
}
