import Foundation
import PhotosCore
import UploadCore

/// Shared Apple runtime signals for every PhotoKit-backed upload flow. The policy stays in Core;
/// this adapter only translates public OS state into its platform-neutral input.
enum AppleBackupRuntimeSignals {
    static func current() -> BackupThrottleInputs {
        let snapshot = LibraryRuntimeState.shared.snapshot()
        let thermal: BackupThermalLevel =
            switch snapshot.thermalLevel {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            }
        return BackupThrottleInputs(
            thermalLevel: thermal,
            isLowPowerMode: snapshot.isLowPowerMode,
            isNetworkAvailable: snapshot.network.isReachable,
            isNetworkConstrained: snapshot.network.isConstrained,
            isNetworkExpensive: snapshot.network.isExpensive
        )
    }
}
