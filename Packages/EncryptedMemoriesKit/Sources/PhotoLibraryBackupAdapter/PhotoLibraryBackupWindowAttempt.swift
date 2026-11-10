import Foundation
import PhotosCore
import UploadCore

/// One OS background window of the photo backup: a `BGProcessingTask` window or a continued processing task (#1108).
/// It runs the window's catch-up pass for `owner`, protects the run it carries from the short background grace, and
/// stops that run when the window expires. The platform adapter owns the OS task; the controller owns the backup.
@MainActor
public final class PhotoLibraryBackupWindowAttempt {
    public var didExpire = false
    public var runID: String?
    /// The last run that this window carried; it stays after the run ended, so its settlement can be awaited.
    public private(set) var lastRunID: String?
    /// The work of this window. Expiration cancels it, so a pass that still waits for the first network path ends.
    public var work: Task<Void, Never>?
    private let owner: BackupExecutionOwner
    private let protection: BackgroundBackupRunProtection
    /// The window carries one run at a time. After the pass it took over, it can run a pass of its own for the person's
    /// retry and holds that run instead. A new hold ends the short grace that a pass began before: the window carries the
    /// run from then on, and the grace would only warn and hold.
    private let hold: BackgroundBackupRunHold
    private weak var controller: PhotoLibraryBackupController?
    #if DEBUG
        var beforeRunAdmissionForTesting: ((String) -> Void)?
        private(set) var cancellationReleaseEndedForTesting = false
    #endif

    /// `endShortGrace` ends the platform's short background grace once the window carries a run.
    public init(
        owner: BackupExecutionOwner, protection: BackgroundBackupRunProtection = .shared,
        endShortGrace: @escaping @MainActor () -> Void
    ) {
        self.owner = owner
        self.protection = protection
        hold = BackgroundBackupRunHold(protection: protection, onHold: endShortGrace)
    }

    public func run(controller: PhotoLibraryBackupController) async -> BackgroundCatchUpEnd {
        guard !didExpire, !Task.isCancelled else { return .done }
        self.controller = controller
        defer {
            hold.release()
            runID = nil
            self.controller = nil
        }
        return await withTaskCancellationHandler {
            await controller.backgroundCatchUp(
                owner: owner,
                onRunStarted: { runID in
                    self.runID = runID
                    self.lastRunID = runID
                    #if DEBUG
                        self.beforeRunAdmissionForTesting?(runID)
                    #endif
                    if self.didExpire || Task.isCancelled {
                        self.hold.release()
                        if !self.protection.isProtected(owner: controller, runID: runID) {
                            controller.stopBackgroundWindowRun(runID: runID, for: self.owner)
                        }
                    } else {
                        self.hold.hold(owner: controller, runID: runID)
                    }
                },
                onRunAdmitted: { runID in
                    // The run starts for this window, and a waiting window resumes only later: the short grace can
                    // expire before that, so the protection begins now. `onRunStarted` decides whether the run stays.
                    guard !self.didExpire else { return }
                    self.hold.hold(owner: controller, runID: runID)
                })
        } onCancel: {
            Task { @MainActor in
                self.hold.release()
                #if DEBUG
                    self.cancellationReleaseEndedForTesting = true
                #endif
            }
        }
    }

    public func expire() {
        didExpire = true
        hold.release()
        work?.cancel()
        if let controller, let runID, !protection.isProtected(owner: controller, runID: runID) {
            controller.stopBackgroundWindowRun(runID: runID, for: owner)
        }
    }

    /// Refresh scans record their run for cancellation, but never protect an upload pass from the short grace.
    public func noteRefreshRun(controller: PhotoLibraryBackupController?, runID: String) {
        self.runID = runID
        if didExpire { controller?.stopBackgroundWindowRun(runID: runID) }
    }
}
