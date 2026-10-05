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

/// Where a backup controller reads its runtime signals: the current throttle inputs and a stream that fires when
/// they may have changed. Production uses the one shared Apple runtime state; tests inject both.
public struct BackupRuntimeSignalSource: Sendable {
    public var current: @Sendable () -> BackupThrottleInputs
    public var updates: @Sendable () -> AsyncStream<LibraryRuntimeSnapshot>

    public init(
        current: @escaping @Sendable () -> BackupThrottleInputs,
        updates: @escaping @Sendable () -> AsyncStream<LibraryRuntimeSnapshot>
    ) {
        self.current = current
        self.updates = updates
    }

    public static let apple = BackupRuntimeSignalSource(
        current: { AppleBackupRuntimeSignals.current() },
        updates: { LibraryRuntimeState.shared.updates() }
    )
}
