import Foundation

/// A range request can stop waiting without cancelling the shared fetch or other range requests.
final class VideoPrefetchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if isFinished {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func finish() {
        let pending = lock.withLock {
            isFinished = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}
