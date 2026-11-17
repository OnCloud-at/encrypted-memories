import Foundation
import PhotosCore

/// The one decision about a failed library load or refresh. macOS, iOS and iPadOS ask it; no host maps an error to a
/// reason, a monitor outcome or a screen by itself.
///
/// A refresh is a safe read, and the next refresh tries it again. A background refresh, which no person waits for,
/// therefore stays silent. A refresh that a person started shows its failure.
public enum TimelineRefreshFailurePolicy {
    public struct Verdict: Sendable, Equatable {
        public let reason: TimelineRefreshFailureReason
        /// What the change monitor does next. Lost scope access ends the monitor; every other failure retries.
        public let monitorOutcome: LibraryChangeRefreshOutcome
        /// Whether the failure reaches the person.
        public let presentation: FailurePresentation
    }

    public static func verdict(for error: any Error, situation: FailureSituation) -> Verdict {
        let reason = reason(for: error)
        return Verdict(
            reason: reason,
            monitorOutcome: monitorOutcome(for: reason),
            presentation: situation == .background ? .silent : .alert
        )
    }

    /// The stable class of a failed load. `unchanged` is no failure, so no error maps to it.
    public static func reason(for error: any Error) -> TimelineRefreshFailureReason {
        if error is CancellationError { return .cancelled }
        if error is any LibraryChangeTerminalError { return .scopeAccessLost }
        if error is any TimelineInventoryConvergenceError { return .pendingInventoryVisibility }
        return .other
    }

    /// The monitor's next step after a load that ended with `reason`. Only lost scope access ends the monitor.
    /// A load that found nothing new is a success; without a token it acknowledges no revision.
    public static func monitorOutcome(for reason: TimelineRefreshFailureReason) -> LibraryChangeRefreshOutcome {
        switch reason {
        case .scopeAccessLost: .terminal
        case .pendingInventoryVisibility, .superseded, .cancelled, .other: .retry
        case .unchanged: .refreshedWithoutRevision
        }
    }
}
