import Foundation
import PhotosCore
import UploadCore

/// Carries the photo backup for one continued processing task that the person accepted (#1108). The platform adapter
/// owns only the OS task; this session owns the passes, the goal, the card and the one result.
///
/// - Each round runs the shared window attempt with owner `.iOSContinuedTask`: it carries the running pass of any owner,
///   or starts one, and protects it from the short background grace. A next round starts only while the backup runs,
///   work is owed and the last pass backed up photos.
/// - The result is chosen once, after the last carried pass settled (`waitUntilRunSettled`), from the settled state
///   first and the expiry second. After an expiry the wait for the settlement ends at `settlementWait` at the latest;
///   the durable state at that moment decides.
/// - `continued.end` is logged before the OS hears the result, so a missing line after `window.expirationReceived` shows
///   that the system ended the app.
@MainActor
public final class PhotoLibraryContinuedBackupSession {
    /// What the system card shows.
    public struct Card: Sendable, Equatable {
        public let progress: BackupExecutionProgress
        public let title: String
        public let subtitle: String
    }

    /// The longest wait for the carried pass to settle after an expiry. Measured stops took up to 5.6 s (#1108).
    public static let settlementWaitAfterExpiry: Duration = .seconds(5)
    public static let progressInterval: Duration = .seconds(1)
    static let progressLogInterval: Duration = .seconds(30)

    private let controller: PhotoLibraryBackupController
    private let attempt: PhotoLibraryBackupWindowAttempt
    private let completion: BackgroundWindowCompletion
    private let report: @MainActor (Card) -> Void
    private let log: BackgroundWorkLog
    private let settlementWait: Duration
    private let progressInterval: Duration
    private var goal = PhotoLibraryContinuedBackupGoal()
    private var expiredAt: ContinuousClock.Instant?
    private var endWaiter: CheckedContinuation<Void, Never>?
    private var didEndWait = false
    /// The last carried run has settled; nil while no run was carried.
    private var carriedRunSettled: Bool?

    public init(
        controller: PhotoLibraryBackupController,
        completion: BackgroundWindowCompletion,
        protection: BackgroundBackupRunProtection = .shared,
        endShortGrace: @escaping @MainActor () -> Void,
        log: BackgroundWorkLog = .system,
        settlementWait: Duration = PhotoLibraryContinuedBackupSession.settlementWaitAfterExpiry,
        progressInterval: Duration = PhotoLibraryContinuedBackupSession.progressInterval,
        report: @escaping @MainActor (Card) -> Void
    ) {
        self.controller = controller
        self.completion = completion
        attempt = PhotoLibraryBackupWindowAttempt(
            owner: .iOSContinuedTask, protection: protection, endShortGrace: endShortGrace)
        self.log = log
        self.settlementWait = settlementWait
        self.progressInterval = progressInterval
        self.report = report
    }

    /// Runs the task to its one end.
    public func run() async {
        let reporter = Task { [weak self] in await self?.reportProgress() }
        attempt.work = Task { [weak self] in
            await self?.carryPasses()
            self?.endWait()
        }
        await withCheckedContinuation { continuation in
            if didEndWait { continuation.resume() } else { endWaiter = continuation }
        }
        // The running card stops before the final card, so no later tick can show "Backing up" over the end.
        reporter.cancel()
        // A pass that did not settle within the wait goes on; its rows are checkpointed and the next pass resumes them.
        let settled = controller.status
        let end = PhotoLibraryContinuedBackupEnd.after(
            goal: goal, settled: settled, didExpire: expiredAt != nil, backupRuns: backupRuns)
        let progress = goal.update(status: settled, catalog: controller.lastCatalogProgress)
        // A completed goal fills the ring, also when some of its photos ended as respected remote deletions.
        let units =
            end == .completed
            ? BackupExecutionProgress(
                completedUnitCount: PhotoLibraryContinuedBackupGoal.scale,
                totalUnitCount: PhotoLibraryContinuedBackupGoal.scale) : progress.units
        report(
            Card(
                progress: units,
                title: PhotoLibraryContinuedBackupCard.finalTitle(after: end, settled: settled),
                subtitle: PhotoLibraryContinuedBackupCard.subtitle(for: settled, goal: goal)))
        log.notice(
            .photoBackup, "continued.end",
            [
                (.init("end"), .name(end)), (.init("success"), .flag(end.reportsSuccess)),
                (.init("expired"), .flag(expiredAt != nil)),
                (.init("waitMs"), expiredAt.map { .milliseconds(ContinuousClock.now - $0) } ?? .word("none")),
                (.init("settled"), carriedRunSettled.map { .flag($0) } ?? .word("none")),
            ])
        await completion.finish(after: {}, deciding: { (end.windowOutcome, end.reportsSuccess) })
    }

    /// The OS expired the task, or the person stopped it on the system card. A pass that the person watches in the app
    /// keeps going; the end still waits, bounded, for the carried pass to settle.
    public func expire() {
        guard expiredAt == nil else { return }
        expiredAt = .now
        completion.markExpired()
        attempt.expire()
        Task { [weak self, settlementWait] in
            try? await Task.sleep(for: settlementWait)
            self?.endWait()
        }
    }

    /// The backup may run: it is on, not paused, has photo access, and its controller did not shut down for a sign-out.
    private var backupRuns: Bool {
        !controller.isShutDown && controller.isEnabled && !controller.isUserPaused
            && controller.accessState.allowsBackup
    }

    private func carryPasses() async {
        while expiredAt == nil {
            let carriedBefore = attempt.lastRunID
            let backedUpBefore = controller.status.backedUp
            _ = await attempt.run(controller: controller)
            if let runID = attempt.lastRunID, runID != carriedBefore {
                carriedRunSettled = false
                await controller.waitUntilRunSettled(runID)
                carriedRunSettled = true
            }
            _ = goal.update(status: controller.status, catalog: controller.lastCatalogProgress)
            guard expiredAt == nil, attempt.lastRunID != carriedBefore, backupRuns,
                !goal.isReached(by: controller.status), controller.status.backedUp > backedUpBefore
            else { return }
            log.notice(.photoBackup, "continued.nextPass")
        }
    }

    private func reportProgress() async {
        var lastLog: ContinuousClock.Instant?
        while !Task.isCancelled, !didEndWait {
            let status = controller.status
            let progress = goal.update(status: status, catalog: controller.lastCatalogProgress)
            report(
                Card(
                    progress: progress.units, title: PhotoLibraryContinuedBackupCard.title,
                    subtitle: PhotoLibraryContinuedBackupCard.subtitle(for: status, goal: goal)))
            if lastLog.map({ ContinuousClock.now - $0 >= Self.progressLogInterval }) ?? true {
                lastLog = .now
                log.notice(
                    .photoBackup, "continued.progress",
                    [
                        (.init("completedUnits"), .count(progress.units.completedUnitCount)),
                        (.init("backedUp"), progress.backedUp.map { .count($0) } ?? .word("none")),
                        (.init("goal"), progress.total.map { .count($0) } ?? .word("none")),
                    ])
            }
            try? await Task.sleep(for: progressInterval)
        }
    }

    private func endWait() {
        guard !didEndWait else { return }
        didEndWait = true
        endWaiter?.resume()
        endWaiter = nil
    }
}
