import PhotoLibraryBackupAdapter
import UIKit

/// Protects an active foreground pass with the short system grace window if the app backgrounds.
/// It never owns backup state: the shared controller keeps every transition durable.
@MainActor
final class PhotoBackupBackgroundGrace {
    static let shared = PhotoBackupBackgroundGrace()

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation: UUID?

    /// Acquire the assertion while the pass is foreground-active. Waiting for `scenePhase == .background`
    /// can be too late for the system to grant it.
    func protectActiveRun(controller: PhotoLibraryBackupController) {
        guard identifier == .invalid else { return }
        guard let runID = controller.activeExecutionRunID else { return }
        let generation = UUID()
        self.generation = generation
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") {
            [weak self, weak controller] in
            controller?.stopSync(runID: runID)
            self?.end(generation: generation)
        }
        guard identifier != .invalid else {
            self.generation = nil
            return
        }
    }

    func end(generation expectedGeneration: UUID? = nil) {
        if let expectedGeneration, generation != expectedGeneration { return }
        guard identifier != .invalid else {
            generation = nil
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        generation = nil
    }
}
