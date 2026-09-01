import Foundation

public struct TimelineUploadRefreshAttempt: Sendable, Equatable {
    public let attempt: Int
    public let failureReason: TimelineRefreshFailureReason?
    public let decision: TimelineRefreshConvergenceDecision

    public init(
        attempt: Int,
        failureReason: TimelineRefreshFailureReason?,
        decision: TimelineRefreshConvergenceDecision
    ) {
        self.attempt = attempt
        self.failureReason = failureReason
        self.decision = decision
    }
}

/// Owns one bounded convergence drain for upload-triggered library refreshes.
/// Repeated upload signals join the active drain and produce at most one follow-up cycle.
public actor TimelineUploadRefreshCoordinator {
    public typealias Refresh = @Sendable (Int) async -> TimelineRefreshFailureReason?
    public typealias Observer = @Sendable (TimelineUploadRefreshAttempt) async -> Void

    private let policy: TimelineRefreshConvergencePolicy
    private var generation: UInt64 = 0
    private var nextWorkerID: UInt64 = 0
    private var activeWorkerID: UInt64?
    private var worker: Task<Void, Never>?
    private var latestRequest: Request?

    private struct Request: Sendable {
        let generation: UInt64
        let refresh: Refresh
        let observer: Observer
    }

    public init(policy: TimelineRefreshConvergencePolicy = .init()) {
        self.policy = policy
    }

    public func request(
        refresh: @escaping Refresh,
        observer: @escaping Observer = { _ in }
    ) {
        generation &+= 1
        latestRequest = Request(generation: generation, refresh: refresh, observer: observer)
        guard worker == nil else { return }
        nextWorkerID &+= 1
        let workerID = nextWorkerID
        activeWorkerID = workerID
        worker = Task { await drain(workerID: workerID) }
    }

    public func cancel() async {
        generation &+= 1
        let active = worker
        active?.cancel()
        activeWorkerID = nil
        worker = nil
        latestRequest = nil
        await active?.value
    }

    private func drain(workerID: UInt64) async {
        defer {
            if activeWorkerID == workerID {
                activeWorkerID = nil
                worker = nil
            }
        }

        cycle: while !Task.isCancelled {
            guard let request = latestRequest else { break }
            let cycleGeneration = request.generation
            var attempt = 0

            while !Task.isCancelled {
                guard generation == cycleGeneration else { continue cycle }
                let failure = await request.refresh(attempt)
                guard !Task.isCancelled else { break cycle }
                // A newer signal owns both the next refresh closure and its observer. Do not publish
                // stale results from a superseded account/load lease.
                guard generation == cycleGeneration else { continue cycle }
                let decision = policy.decision(after: failure, attempt: attempt)
                await request.observer(
                    .init(attempt: attempt, failureReason: failure, decision: decision))
                guard !Task.isCancelled else { break cycle }
                guard generation == cycleGeneration else { continue cycle }
                guard case .retry(let delay) = decision else { break }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break cycle
                }
                attempt += 1
            }

            guard !Task.isCancelled else { break }
            if generation == cycleGeneration { break }
            // A later upload arrived while the refresh was in flight. Its latest closures own one
            // immediate follow-up cycle, including when the superseded result was cancelled.
        }
    }
}
