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

    public static let apple = observing(runtime: .shared, defaults: .standard)

    /// The network of `runtime` and the saved "Use Cellular Data" setting in `defaults`.
    static func observing(runtime: LibraryRuntimeState, defaults: UserDefaults) -> BackupRuntimeSignalSource {
        let settings = BackupSettingsDefaults(defaults: defaults)
        return BackupRuntimeSignalSource(
            current: {
                BackupThrottleInputs(
                    runtime: runtime.snapshot(),
                    usesMobileData: BackupMobileDataPolicy.isEnabled(defaults: settings.defaults))
            },
            updates: { BackupRuntimeSignalSource.updates(of: runtime, mobileDataSettingIn: settings.defaults) }
        )
    }
}

/// `UserDefaults` is thread-safe; Foundation does not mark it `Sendable`.
private struct BackupSettingsDefaults: @unchecked Sendable {
    let defaults: UserDefaults
}

extension BackupRuntimeSignalSource {
    /// The runtime updates, plus the current snapshot each time the saved mobile-data setting changes. The settings
    /// toggle writes the preference in this process, which posts `UserDefaults.didChangeNotification`.
    fileprivate static func updates(
        of runtime: LibraryRuntimeState, mobileDataSettingIn defaults: UserDefaults
    ) -> AsyncStream<LibraryRuntimeSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let setting = BackupMobileDataSettingObserver(defaults: defaults) {
                continuation.yield(runtime.snapshot())
            }
            let runtimeUpdates = runtime.updates()
            let forward = Task {
                for await snapshot in runtimeUpdates { continuation.yield(snapshot) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forward.cancel()
                setting.cancel()
            }
        }
    }
}

/// Calls `onChange` when the saved mobile-data setting of `defaults` changes value. Other settings are ignored.
private final class BackupMobileDataSettingObserver: @unchecked Sendable {
    private let defaults: UserDefaults
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var lastValue: Bool
    private var token: (any NSObjectProtocol)?

    init(defaults: UserDefaults, onChange: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        lastValue = BackupMobileDataPolicy.isEnabled(defaults: defaults)
        // The notification names no key and posts on the writing thread; only a changed value counts.
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.settingsDidChange()
        }
        lock.withLock { self.token = token }
    }

    private func settingsDidChange() {
        let value = BackupMobileDataPolicy.isEnabled(defaults: defaults)
        let changed = lock.withLock {
            guard token != nil, value != lastValue else { return false }
            lastValue = value
            return true
        }
        if changed { onChange() }
    }

    func cancel() {
        let removed = lock.withLock {
            let current = token
            token = nil
            return current
        }
        if let removed { NotificationCenter.default.removeObserver(removed) }
    }

    deinit { cancel() }
}
