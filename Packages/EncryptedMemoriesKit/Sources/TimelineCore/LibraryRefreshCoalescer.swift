/// Serializes refresh requests for one library and coalesces requests that arrive while a refresh is running.
///
/// Each owner keeps one instance and always supplies the same refresh pipeline. Callers that overlap wait for
/// the shared drain result. A request observed during an active refresh causes exactly one follow-up refresh,
/// which is important after a local upload: the already-running server snapshot may have started before the
/// upload became visible. The drain never polls a completed task, so it cannot monopolize a cooperative executor.
public actor LibraryRefreshCoalescer {
    public typealias Operation = @Sendable () async -> Bool

    private var requestedGeneration: UInt64 = 0
    private var drainIdentity: UInt64 = 0
    private var drainTask: Task<Bool, Never>?

    public init() {}

    public func request(_ operation: @escaping Operation) async -> Bool {
        let task = enqueue(operation)
        return await task.value
    }

    /// Cancels the current drain and allows the next request to start a new session immediately. An old
    /// operation that ignores cancellation cannot clear a newer drain because every drain has an identity.
    public func cancel() {
        drainIdentity &+= 1
        requestedGeneration &+= 1
        drainTask?.cancel()
        drainTask = nil
    }

    /// Enqueues a refresh and returns the active drain task.
    ///
    /// Callers normally use `request(_:)`.
    func enqueue(_ operation: @escaping Operation) -> Task<Bool, Never> {
        requestedGeneration &+= 1
        if let drainTask { return drainTask }

        drainIdentity &+= 1
        let identity = drainIdentity
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.drain(identity: identity, operation: operation)
        }
        drainTask = task
        return task
    }

    private func drain(identity: UInt64, operation: @escaping Operation) async -> Bool {
        var succeeded = false
        while !Task.isCancelled {
            let servicedGeneration = requestedGeneration
            succeeded = await operation()
            guard !Task.isCancelled, servicedGeneration != requestedGeneration else { break }
            await Task.yield()
        }

        if identity == drainIdentity {
            drainTask = nil
        }
        return succeeded
    }
}
