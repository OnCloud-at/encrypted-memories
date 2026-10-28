import BackgroundTasks
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import UIKit
import UploadCore
import os

@MainActor
private final class PhotoBackupProcessingAttempt {
    var didExpire = false
    var runID: String?
    /// The work of this window. Expiration cancels it, so a pass that still waits for the first network path ends.
    var work: Task<Void, Never>?
}

/// Owns only the iOS execution opportunities for the shared photo-backup controller.
/// Queueing, dedupe, upload, recovery, and checkpoints remain in the controller/Core.
@MainActor
final class PhotoBackupBackgroundCoordinator {
    static let shared = PhotoBackupBackgroundCoordinator()

    nonisolated static let processingTaskIdentifier = "at.oncloud.encryptedmemories.photo-backup.processing"
    /// The short app refresh task, which only scans the photo library (PhotoLibraryRefreshWindow).
    nonisolated static let refreshTaskIdentifier = "at.oncloud.encryptedmemories.photo-backup.refresh"

    private static let controllerReadyTimeout: Duration = .seconds(30)

    private let scheduler = BGTaskScheduler.shared
    private let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PhotoBackupBackground")
    private lazy var submitter = BackgroundTaskRequestSubmitter(
        cancelRequest: {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: PhotoBackupBackgroundCoordinator.processingTaskIdentifier)
        },
        onErrorAfterCancel: { [logger] error in
            logger.error(
                "Photo-backup submission failed after a cancel: \(error.localizedDescription, privacy: .public)")
        })
    private lazy var refreshSubmitter = BackgroundTaskRequestSubmitter(
        cancelRequest: {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: PhotoBackupBackgroundCoordinator.refreshTaskIdentifier)
        },
        onErrorAfterCancel: { [logger] error in
            logger.error(
                "Library-refresh submission failed after a cancel: \(error.localizedDescription, privacy: .public)")
        })
    private var didRegister = false
    private var registrationIssue: BackupExecutionOpportunityIssue?
    private var processingIssue: BackupExecutionOpportunityIssue?
    private var applicationIsForegroundActive = false
    private var backupIsActivelyProcessing = false
    private var schedulingStopped = false

    private init() {}

    /// Registration happens during app initialization, before a background launch can be delivered.
    func register() {
        guard !didRegister else { return }
        didRegister = true

        let processingRegistered = scheduler.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleProcessingTask(processingTask)
            }
        }

        let refreshRegistered = scheduler.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleRefreshTask(refreshTask)
            }
        }

        if !processingRegistered || !refreshRegistered {
            registrationIssue = .registrationFailed
            publishExecutionIssue()
            logger.error(
                "Background task registration failed: processing \(processingRegistered), refresh \(refreshRegistered)"
            )
        }
    }

    /// Connects the account-scoped shared controller to the platform runtime. No backup behavior
    /// is implemented here; the hooks only protect an already-running shared pass from suspension.
    func configure(controller: PhotoLibraryBackupController) {
        schedulingStopped = false
        PhotoLibraryBackupSharedRef.shared.controller = controller
        publishExecutionIssue(to: controller)
        applicationIsForegroundActive = UIApplication.shared.applicationState == .active
        controller.idleTimerHook = { [weak controller] isBackingUp in
            Self.shared.backupIsActivelyProcessing = isBackingUp
            Self.shared.updateIdleTimer()
            guard let controller else {
                PhotoBackupBackgroundGrace.shared.end()
                return
            }
            if isBackingUp {
                PhotoBackupBackgroundGrace.shared.protectActiveRun(controller: controller)
            } else {
                PhotoBackupBackgroundGrace.shared.end()
            }
        }
        if controller.isEnabled, !controller.isUserPaused {
            scheduleProcessingCatchUp(controller: controller)
        }
    }

    func applicationDidEnterBackground(controller: PhotoLibraryBackupController?) {
        applicationIsForegroundActive = false
        updateIdleTimer()
        guard let controller, controller.isEnabled, !controller.isUserPaused else { return }
        scheduleProcessingCatchUp(controller: controller)
    }

    /// Foreground execution no longer depends on a queued background opportunity. Clear transient
    /// scheduler issues immediately so a failed discretionary submission cannot flash as a failed
    /// backup while the shared controller is visibly running.
    func applicationDidBecomeActive(controller: PhotoLibraryBackupController?) {
        applicationIsForegroundActive = true
        updateIdleTimer()
        processingIssue = nil
        publishExecutionIssue(to: controller)
        controller?.applicationDidBecomeActive()
    }

    func backupPaused() {
        stopScheduling(detachController: false)
    }

    func backupResumed(controller: PhotoLibraryBackupController) {
        schedulingStopped = false
        PhotoLibraryBackupSharedRef.shared.controller = controller
        if controller.isEnabled, !controller.isUserPaused {
            scheduleProcessingCatchUp(controller: controller)
        }
    }

    func backupStopped() {
        stopScheduling(detachController: true)
    }

    private func stopScheduling(detachController: Bool) {
        schedulingStopped = true
        submitter.cancel()
        refreshSubmitter.cancel()
        processingIssue = nil
        publishExecutionIssue()
        PhotoBackupBackgroundGrace.shared.end()
        if detachController {
            PhotoLibraryBackupSharedRef.shared.controller = nil
        }
        backupIsActivelyProcessing = false
        updateIdleTimer()
    }

    func displayPreferenceDidChange() {
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = BackupDisplayWakePolicy.shouldKeepDisplayAwake(
            userOptedIn: UserDefaults.standard.bool(
                forKey: AppSettingsKey.keepDisplayAwakeDuringForegroundBackup
            ),
            applicationIsForegroundActive: applicationIsForegroundActive,
            backupIsActivelyProcessing: backupIsActivelyProcessing
        )
    }

    /// Keeps one future catch-up request pending. Submission replaces an existing request with the
    /// same identifier; errors are logged rather than silently turning background backup into a no-op.
    func scheduleProcessingCatchUp(controller: PhotoLibraryBackupController? = nil) {
        guard !schedulingStopped, !BackupLocalDataPurge.isPurgePending() else { return }
        var earliestBeginDate: Date?
        if let date = controller?.nextAutomaticAttemptAt, date > Date() {
            earliestBeginDate = date
        }
        submitter.submit(
            blocking: { try scheduler.submit(Self.processingRequest(earliestBeginDate: earliestBeginDate)) },
            offMainThread: Self.offMainSubmission(earliestBeginDate: earliestBeginDate),
            completion: { [weak self] error in
                guard let self else { return }
                guard let error else {
                    self.processingIssue = nil
                    self.publishExecutionIssue(to: controller)
                    return
                }
                self.processingIssue = Self.executionIssue(for: error)
                self.publishExecutionIssue(to: controller)
                self.logger.error(
                    "Photo-backup processing submission failed: \(error.localizedDescription, privacy: .public)")
            })
        scheduleLibraryRefresh()
    }

    /// Keeps one refresh request pending, `PhotoLibraryRefreshWindow.nextRequestDelay` after it is planned; a new
    /// submission replaces the pending one. Its errors are logged; the processing request reports the scheduler's state.
    func scheduleLibraryRefresh() {
        guard !schedulingStopped, !BackupLocalDataPurge.isPurgePending() else { return }
        let earliestBeginDate = Date().addingTimeInterval(PhotoLibraryRefreshWindow.nextRequestDelay)
        refreshSubmitter.submit(
            blocking: { try scheduler.submit(Self.refreshRequest(earliestBeginDate: earliestBeginDate)) },
            offMainThread: Self.offMainRefreshSubmission(earliestBeginDate: earliestBeginDate),
            completion: { [weak self] error in
                guard let error else { return }
                self?.logger.error(
                    "Library-refresh submission failed: \(error.localizedDescription, privacy: .public)")
            })
    }

    nonisolated static func refreshRequest(earliestBeginDate: Date) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        return request
    }

    /// The iOS 27 call for the refresh request, which must not run on the main thread; nil before iOS 27.
    nonisolated static func offMainRefreshSubmission(earliestBeginDate: Date) -> (@Sendable () async throws -> Void)? {
        guard #available(iOS 27.0, *) else { return nil }
        return {
            try await BGTaskScheduler.shared.submitTaskRequest(refreshRequest(earliestBeginDate: earliestBeginDate))
        }
    }

    nonisolated static func processingRequest(earliestBeginDate: Date?) -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        return request
    }

    /// The iOS 27 call, which must not run on the main thread; nil before iOS 27.
    nonisolated static func offMainSubmission(earliestBeginDate: Date?) -> (@Sendable () async throws -> Void)? {
        guard #available(iOS 27.0, *) else { return nil }
        return {
            try await BGTaskScheduler.shared.submitTaskRequest(processingRequest(earliestBeginDate: earliestBeginDate))
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        processingIssue = nil
        publishExecutionIssue()
        // The delivered request is consumed now. Replace it before doing anything that can expire,
        // fail, or wait for account restoration.
        scheduleProcessingCatchUp()

        let completion = BackgroundWindowCompletion(kind: .photoBackup) { task.setTaskCompleted(success: $0) }
        // Every end waits, bounded, until the window's requests reached the scheduler: before iOS 27 the request went
        // out at once, before the window ended.
        let pendingRequests: @Sendable () async -> Void = { [submitter] in await submitter.pendingSubmissionsEnded() }
        let attempt = PhotoBackupProcessingAttempt()
        attempt.work = Task { @MainActor [weak self] in
            guard !attempt.didExpire else {
                await completion.finish(.expired, after: pendingRequests)
                return
            }
            // A launch without a scene has not started the account yet.
            BackgroundLaunchAccountStart.shared.ensureStarted()
            let wait = await self?.waitForController() ?? .notReady
            guard let self, case .ready(let controller) = wait else {
                let outcome = wait.outcomeWithoutService(didExpire: attempt.didExpire)
                await completion.finish(outcome, after: pendingRequests)
                return
            }
            guard !attempt.didExpire else {
                await completion.finish(.expired, after: pendingRequests)
                return
            }
            guard controller.isEnabled else {
                self.backupStopped()
                await completion.finish(.notNeeded, after: pendingRequests)
                return
            }
            guard !controller.isUserPaused else {
                self.backupPaused()
                await completion.finish(.notNeeded, after: pendingRequests)
                return
            }

            defer { attempt.runID = nil }
            let catchUp = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { runID in
                attempt.runID = runID
                if attempt.didExpire {
                    controller.stopBackgroundWindowRun(runID: runID)
                }
            }
            self.scheduleProcessingCatchUp(controller: controller)
            let waitedForNetwork = catchUp == .noNetworkPath
            // The state is read when the window ends, after the wait, as before the wait existed.
            await completion.finish(after: pendingRequests) {
                let outcome = BackgroundWindowOutcome.afterWork(
                    didExpire: attempt.didExpire, didComplete: !Task.isCancelled, waitedForNetwork: waitedForNetwork)
                return (outcome, nil)
            }
        }

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                attempt.didExpire = true
                attempt.work?.cancel()
                let controller = PhotoLibraryBackupSharedRef.shared.controller
                if let runID = attempt.runID {
                    controller?.stopBackgroundWindowRun(runID: runID)
                }
                self?.scheduleProcessingCatchUp(controller: controller)
            }
        }
    }

    /// A refresh window scans the photo library and uploads nothing (PhotoLibraryRefreshWindow).
    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        let completion = PhotoLibraryRefreshWindow.begin { task.setTaskCompleted(success: $0) }
        let pendingRequests: @Sendable () async -> Void = { [refreshSubmitter] in
            await refreshSubmitter.pendingSubmissionsEnded()
        }
        let attempt = PhotoBackupProcessingAttempt()
        attempt.work = Task { @MainActor [weak self] in
            let outcome = await PhotoLibraryRefreshWindow.run(
                scheduleNext: { self?.scheduleLibraryRefresh() },
                isLowPowerModeOn: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                startAccount: { BackgroundLaunchAccountStart.shared.ensureStarted() },
                waitForController: { await PhotoLibraryBackupSharedRef.shared.controllerWhenReady(timeout: $0) },
                didExpire: { attempt.didExpire },
                backupStopped: { self?.backupStopped() },
                backupPaused: { self?.backupPaused() },
                onRunStarted: { runID in
                    attempt.runID = runID
                    if attempt.didExpire {
                        PhotoLibraryBackupSharedRef.shared.controller?.stopBackgroundWindowRun(runID: runID)
                    }
                })
            attempt.runID = nil
            await completion.finish(after: pendingRequests) {
                (outcome.afterTheEndWait(didExpire: attempt.didExpire), nil)
            }
        }
        task.expirationHandler = {
            Task { @MainActor in
                attempt.didExpire = true
                attempt.work?.cancel()
                if let runID = attempt.runID {
                    PhotoLibraryBackupSharedRef.shared.controller?.stopBackgroundWindowRun(runID: runID)
                }
            }
        }
    }

    private func waitForController() async -> BackgroundAccountWait<PhotoLibraryBackupController> {
        let wait = await PhotoLibraryBackupSharedRef.shared.controllerWhenReady(timeout: Self.controllerReadyTimeout)
        if case .notReady = wait, !Task.isCancelled {
            logger.error("Photo-backup controller was not ready during the background launch window")
        }
        return wait
    }

    private func publishExecutionIssue(to controller: PhotoLibraryBackupController? = nil) {
        let issue = registrationIssue ?? processingIssue
        (controller ?? PhotoLibraryBackupSharedRef.shared.controller)?.setExecutionOpportunityIssue(issue)
    }

    private static func executionIssue(for error: Error) -> BackupExecutionOpportunityIssue {
        let error = error as NSError
        guard error.domain == BGTaskScheduler.errorDomain,
            let code = BGTaskScheduler.Error.Code(rawValue: error.code)
        else { return .unknown }
        switch code {
        case .unavailable: return .backgroundRefreshUnavailable
        case .notPermitted: return .backgroundLaunchNotPermitted
        case .tooManyPendingTaskRequests: return .schedulerCapacity
        case .immediateRunIneligible: return .immediateRunIneligible
        @unknown default: return .unknown
        }
    }
}
