import Foundation

/// Account-owned controllers can appear after an OS background launch. Wait without polling or
/// retaining a signed-out account, and finish every waiter on cancellation, timeout or detachment.
@MainActor
public final class WeakAsyncReference<Value: AnyObject & Sendable> {
    private struct Waiter {
        let continuation: CheckedContinuation<Value?, Never>
        let timeout: Task<Void, Never>
    }

    public weak var value: Value? {
        didSet {
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: value)
            }
        }
    }
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func whenReady(timeout: Duration) async -> Value? {
        guard !Task.isCancelled else { return nil }
        if let value { return value }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(id)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: nil)
    }
}
