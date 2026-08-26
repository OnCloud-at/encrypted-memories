import Foundation
import PhotoLibraryBackupAdapter

/// The BGProcessingTask handler outlives every SwiftUI scene, so the current account's backup
/// controller registers itself here (weak - sign-out releases it naturally).
@MainActor
final class PhotoLibraryBackupSharedRef {
    static let shared = PhotoLibraryBackupSharedRef()

    private struct PendingWaiter {
        let continuation: CheckedContinuation<PhotoLibraryBackupController?, Never>
        let timeout: Task<Void, Never>
    }

    weak var controller: PhotoLibraryBackupController? {
        didSet {
            guard let controller else { return }
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: controller)
            }
        }
    }
    private var waiters: [UUID: PendingWaiter] = [:]

    private init() {}

    /// A BG task can launch the process before SwiftUI finishes restoring the account/backend.
    /// Suspend without polling until configuration publishes the controller or the launch window times out.
    func controllerWhenReady(timeout: Duration) async -> PhotoLibraryBackupController? {
        if let controller { return controller }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishWaiter(id: id, controller: nil)
                }
                waiters[id] = PendingWaiter(continuation: continuation, timeout: timeoutTask)
            }
        } onCancel: {
            Task { @MainActor in
                Self.shared.finishWaiter(id: id, controller: nil)
            }
        }
    }

    private func finishWaiter(id: UUID, controller: PhotoLibraryBackupController?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: controller)
    }
}
