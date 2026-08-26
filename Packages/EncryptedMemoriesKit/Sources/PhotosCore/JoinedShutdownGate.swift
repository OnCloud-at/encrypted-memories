import Foundation

/// Shared admission and teardown barrier for one account-scoped owner.
///
/// Admission closes synchronously. Every admitted operation runs in a retained child task, so
/// teardown can cancel and join work that is suspended across an `await`. The gate does not know
/// the operation's domain; callers own the ordering of admission closure and resource teardown.
public final class JoinedShutdownGate: @unchecked Sendable {
    private final class OperationHandle: @unchecked Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void

        init(cancel: @escaping @Sendable () -> Void, join: @escaping @Sendable () async -> Void) {
            self.cancel = cancel
            self.join = join
        }
    }

    private let lock = NSLock()
    private var isClosed = false
    private var admitted: [UUID: OperationHandle] = [:]
    private var joinTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    public init() {}

    /// Closes admission without an await. Repeated calls are harmless.
    public func closeAdmission() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    /// Admits one operation and joins it before returning its result.
    ///
    /// The child task remains retained by the gate until it settles. A caller that arrives after
    /// admission closes receives `CancellationError` and its operation closure does not run.
    public func withAdmission<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let task: Task<T, any Error> = try lock.withLock {
            guard !isClosed else { throw CancellationError() }
            let task = Task { try await operation() }
            admitted[id] = OperationHandle(
                cancel: { task.cancel() },
                join: { _ = await task.result }
            )
            return task
        }

        defer {
            remove(id)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Closes admission, cancels every admitted child, and waits for every child to settle.
    public func closeAdmissionAndJoin() async {
        closeAdmission()
        let task = makeJoinTaskIfNeeded()
        await task.value
    }

    /// Runs one joined teardown after admission closes and all admitted operations settle.
    /// Concurrent callers await the same teardown task.
    public func run(_ operation: @escaping @Sendable () async -> Void) async {
        await closeAdmissionAndJoin()
        let task = lock.withLock {
            if let shutdownTask { return shutdownTask }
            let task = Task { await operation() }
            shutdownTask = task
            return task
        }
        await task.value
    }

    private func remove(_ id: UUID) {
        _ = lock.withLock { admitted.removeValue(forKey: id) }
    }

    private func makeJoinTaskIfNeeded() -> Task<Void, Never> {
        lock.withLock {
            if let joinTask { return joinTask }
            let handles = Array(admitted.values)
            let task = Task {
                handles.forEach { $0.cancel() }
                for handle in handles {
                    await handle.join()
                }
            }
            joinTask = task
            return task
        }
    }
}
