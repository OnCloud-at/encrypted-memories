import BackgroundTasks
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import UIKit
import UploadCore

/// The iOS scheduler of the continued backup task (#1108): the request, the registration of its launch handler and the
/// system card. The shared submission decides when to submit; the shared session owns the passes, the goal, the card
/// texts and the one result.
@MainActor
final class PhotoBackupContinuedTask {
    static let shared = PhotoBackupContinuedTask()

    /// Every request's identifier starts with this prefix; Info.plist permits `<prefix>*`.
    nonisolated static let identifierPrefix = "at.oncloud.encryptedmemories.photo-backup.continued."

    private(set) lazy var submission = PhotoLibraryContinuedBackupSubmission(
        isSceneActive: { UIApplication.shared.applicationState == .active },
        makeIdentifier: { Self.identifierPrefix + UUID().uuidString },
        register: { identifier in
            // Continued processing registrations are exempt from the rule to register before the launch ends.
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                Task { @MainActor in PhotoBackupContinuedTask.shared.launch(task, identifier: identifier) }
            }
        },
        blocking: { try BGTaskScheduler.shared.submit(Self.request(identifier: $0)) },
        offMainThread: { identifier in
            guard #available(iOS 27.0, *) else { return nil }
            return { try await BGTaskScheduler.shared.submitTaskRequest(Self.request(identifier: identifier)) }
        })

    private init() {}

    /// The person chose "Continue" in the continued-backup prompt.
    func personAccepted(controller: PhotoLibraryBackupController) {
        submission.submitIfAllowed(owesWork: controller.status.hasOutstandingWork)
    }

    /// The request for one answer: it runs now or fails now, so it never starts later without the person.
    nonisolated static func request(identifier: String) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: PhotoLibraryContinuedBackupCard.title,
            subtitle: PhotoLibraryContinuedBackupCard.preparingSubtitle)
        request.strategy = .fail
        request.requiredResources = []
        return request
    }

    private func launch(_ task: BGTask, identifier: String) {
        guard submission.isCurrent(identifier), let task = task as? BGContinuedProcessingTask,
            let controller = PhotoLibraryBackupSharedRef.shared.controller
        else {
            task.setTaskCompleted(success: false)
            submission.taskEnded(identifier)
            return
        }
        let completion = BackgroundWindowCompletion(kind: .continuedBackup) { [weak self] success in
            task.setTaskCompleted(success: success)
            MainActor.assumeIsolated { self?.submission.taskEnded(identifier) }
        }
        var shown: PhotoLibraryContinuedBackupSession.Card?
        let session = PhotoLibraryContinuedBackupSession(
            controller: controller, completion: completion,
            endShortGrace: { PhotoBackupBackgroundGrace.shared.end() },
            report: { card in
                task.progress.totalUnitCount = card.progress.totalUnitCount
                task.progress.completedUnitCount = card.progress.completedUnitCount
                if shown?.title != card.title || shown?.subtitle != card.subtitle {
                    task.updateTitle(card.title, subtitle: card.subtitle)
                }
                shown = card
            })
        task.expirationHandler = {
            BackgroundWorkLog.system.expirationReceived(.continuedBackup)
            Task { @MainActor in session.expire() }
        }
        Task { await session.run() }
    }
}
