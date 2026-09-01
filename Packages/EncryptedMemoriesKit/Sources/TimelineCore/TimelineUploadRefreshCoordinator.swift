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
    private var worker: Task<Void, Never>?
    private var refresh: Refresh?
    private var observer: Observer?

    public init(policy: TimelineRefreshConvergencePolicy = .init()) {
        self.policy = policy
    }

    public func request(
        refresh: @escaping Refresh,
        observer: @escaping Observer = { _ in }
    ) {
        generation &+= 1
        self.refresh = refresh
        self.observer = observer
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    public func cancel() async {
        generation &+= 1
        let active = worker
        worker?.cancel()
        worker = nil
        refresh = nil
        observer = nil
        await active?.value
    }

    private func drain() async {
        while !Task.isCancelled {
            let cycleGeneration = generation
            guard let refresh else { break }
            let observer = self.observer
            var attempt = 0
            var finalDecision: TimelineRefreshConvergenceDecision = .cancelled

            while !Task.isCancelled {
                let failure = await refresh(attempt)
                guard !Task.isCancelled else { break }
                let decision = policy.decision(after: failure, attempt: attempt)
                finalDecision = decision
                await observer?(.init(attempt: attempt, failureReason: failure, decision: decision))
                guard case .retry(let delay) = decision else { break }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
                attempt += 1
            }

            guard !Task.isCancelled else { break }
            if generation == cycleGeneration || finalDecision == .cancelled {
                break
            }
            // A later upload arrived while the refresh was in flight. One immediate follow-up cycle
            // confirms that the authoritative listing also contains that mutation.
        }
        worker = nil
    }
}
