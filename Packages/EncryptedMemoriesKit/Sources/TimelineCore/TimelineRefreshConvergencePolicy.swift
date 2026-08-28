import Foundation

/// Stable failure classes used by platform shells to distinguish expected server convergence from real errors.
public enum TimelineRefreshFailureReason: Sendable, Equatable {
    case pendingInventoryVisibility
    case scopeAccessLost
    case superseded
    case cancelled
    case other
}

public enum TimelineRefreshConvergenceDecision: Sendable, Equatable {
    case succeeded
    case retry(after: Duration)
    case notYetVisible
    case cancelled
    case failed
}

/// Pure bounded-retry policy for refreshes triggered by a completed upload.
public struct TimelineRefreshConvergencePolicy: Sendable, Equatable {
    public let schedule: TimelineRefreshRetrySchedule

    public init(schedule: TimelineRefreshRetrySchedule = .uploadDefault) {
        self.schedule = schedule
    }

    public func decision(
        after failure: TimelineRefreshFailureReason?,
        attempt: Int
    ) -> TimelineRefreshConvergenceDecision {
        guard let failure else { return .succeeded }
        switch failure {
        case .pendingInventoryVisibility:
            let nextAttempt = attempt + 1
            guard schedule.delays.indices.contains(nextAttempt) else { return .notYetVisible }
            return .retry(after: schedule.delays[nextAttempt])
        case .superseded, .cancelled:
            return .cancelled
        case .scopeAccessLost, .other:
            return .failed
        }
    }
}
