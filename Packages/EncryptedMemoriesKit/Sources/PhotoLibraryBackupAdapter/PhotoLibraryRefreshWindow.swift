import Foundation
import PhotosCore

/// One window of the iOS app refresh task: about 30 seconds in which the app only scans the photo library for the
/// backup, so that the next long window starts with a ready queue. It uploads nothing.
@MainActor
public enum PhotoLibraryRefreshWindow {
    /// How long the window waits for the account. The OS gives the whole window up to 30 seconds.
    public static let accountLimit: Duration = .seconds(15)
    /// The earliest start of the next refresh window, counted from the moment its request is planned.
    public static let nextRequestDelay: TimeInterval = 15 * 60

    /// Records the start of a refresh window.
    public static func begin(
        ledger: BackgroundWindowLedger = .shared, complete: @escaping (Bool) -> Void
    ) -> BackgroundWindowCompletion {
        BackgroundWindowCompletion(kind: .libraryRefresh, ledger: ledger, complete: complete)
    }

    /// Runs the window and returns how it ended. `scheduleNext` submits the next refresh request; it runs first. In Low
    /// Power Mode the window does nothing else. Then the account gets `accountLimit`. Backup off or paused ends the window
    /// through `backupStopped` or `backupPaused`, as the long window does. Then the scan runs until it ends or the
    /// window's end stops it.
    public static func run(
        scheduleNext: () -> Void,
        isLowPowerModeOn: () -> Bool,
        startAccount: () -> Void,
        waitForController: (Duration) async -> BackgroundAccountWait<PhotoLibraryBackupController>,
        didExpire: () -> Bool,
        backupStopped: () -> Void,
        backupPaused: () -> Void,
        onRunStarted: @escaping @MainActor (String) -> Void
    ) async -> BackgroundWindowOutcome {
        scheduleNext()
        guard !isLowPowerModeOn() else { return .notNeeded }
        let waitStart = ContinuousClock.now
        startAccount()
        let wait = await waitForController(accountLimit)
        BackgroundWorkLog.system.accountWait(.libraryRefresh, wait, waited: .now - waitStart)
        guard case .ready(let controller) = wait else { return wait.outcomeWithoutService(didExpire: didExpire()) }
        guard !didExpire() else { return .expired }
        guard controller.isEnabled else {
            backupStopped()
            return .notNeeded
        }
        guard !controller.isUserPaused else {
            backupPaused()
            return .notNeeded
        }
        switch await controller.backgroundRefreshScan(onRunStarted: onRunStarted) {
        case .scanned: return didExpire() ? .expired : .ran
        case .notNeeded, .yielded: return .notNeeded
        case .stopped: return didExpire() ? .expired : .failed
        case .couldNotStart, .failed: return .failed
        }
    }
}
