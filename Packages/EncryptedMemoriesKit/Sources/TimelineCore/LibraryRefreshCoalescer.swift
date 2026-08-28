/// Serializes refresh requests for one library and coalesces requests that arrive while a refresh is running.
///
/// Each owner keeps one instance and always supplies the same refresh pipeline. Callers that overlap wait for
/// the shared drain result. A request observed during an active refresh causes exactly one follow-up refresh,
/// which is important after a local upload: the already-running server snapshot may have started before the
/// upload became visible. The drain never polls a completed task, so it cannot monopolize a cooperative executor.
public actor LibraryRefreshCoalescer {
    public typealias Operation = @Sendable () async -> LibraryChangeRefreshOutcome

    private var requestedGeneration: UInt64 = 0
    private var drainIdentity: UInt64 = 0
    private var drainTask: Task<LibraryChangeRefreshOutcome, Never>?
    private var admissionBarrierIdentity: UInt64 = 0
    private var admissionBarrierTask: Task<Void, Never>?

    public init() {}

    public func request(_ operation: @escaping Operation) async -> LibraryChangeRefreshOutcome {
        await waitForAdmissionBarrier()
        let task = enqueue(operation)
        return await task.value
    }

    /// Cancels and joins the current drain. Requests wait at the admission barrier until every earlier drain has
    /// returned, including a non-cooperative operation that ignores cancellation.
    public func cancel() async {
        let previousBarrier = admissionBarrierTask
        let retiringTask = drainTask
        admissionBarrierIdentity &+= 1
        let barrierIdentity = admissionBarrierIdentity
        drainIdentity &+= 1
        requestedGeneration &+= 1
        retiringTask?.cancel()
        drainTask = nil

        let barrierTask = Task {
            _ = await previousBarrier?.value
            _ = await retiringTask?.value
        }
        admissionBarrierTask = barrierTask
        await barrierTask.value
        if barrierIdentity == admissionBarrierIdentity {
            admissionBarrierTask = nil
        }
    }

    /// Enqueues a refresh and returns the active drain task.
    ///
    /// Callers normally use `request(_:)`.
    private func enqueue(_ operation: @escaping Operation) -> Task<LibraryChangeRefreshOutcome, Never> {
        requestedGeneration &+= 1
        if let drainTask { return drainTask }

        drainIdentity &+= 1
        let identity = drainIdentity
        let task = Task<LibraryChangeRefreshOutcome, Never> { [weak self] in
            guard let self else { return LibraryChangeRefreshOutcome.retry }
            return await self.drain(identity: identity, operation: operation)
        }
        drainTask = task
        return task
    }

    private func drain(
        identity: UInt64,
        operation: @escaping Operation
    ) async -> LibraryChangeRefreshOutcome {
        var outcome = LibraryChangeRefreshOutcome.retry
        while !Task.isCancelled {
            let servicedGeneration = requestedGeneration
            outcome = await operation()
            guard outcome != .terminal else { break }
            guard !Task.isCancelled, servicedGeneration != requestedGeneration else { break }
            await Task.yield()
        }

        if identity == drainIdentity {
            drainTask = nil
        }
        return outcome
    }

    private func waitForAdmissionBarrier() async {
        while let barrierTask = admissionBarrierTask {
            let barrierIdentity = admissionBarrierIdentity
            await barrierTask.value
            if barrierIdentity == admissionBarrierIdentity { return }
        }
    }

    #if DEBUG
        func testingState() -> (requestedGeneration: UInt64, cancellationBarrierActive: Bool) {
            (requestedGeneration, admissionBarrierTask != nil)
        }
    #endif
}
