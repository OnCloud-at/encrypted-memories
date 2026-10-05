import Foundation
import PhotosCore
import UploadCore

/// Shared Apple runtime signals for every backup upload flow, including the Mac folder backup. The policy stays in
/// Core; this adapter only translates public OS state and the mobile-data setting into its platform-neutral input.
public enum AppleBackupRuntimeSignals {
    public static func current() -> BackupThrottleInputs {
        BackupThrottleInputs(
            runtime: LibraryRuntimeState.shared.snapshot(),
            usesMobileData: BackupMobileDataPolicy.isEnabled()
        )
    }
}
