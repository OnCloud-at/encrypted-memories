/// A cause carries only what is known. Unknown failures do not prove a fixed restriction.
public enum FailureCause: Sendable, Equatable {
    case network
    case serviceTemporary
    case authentication
    case sourceTemporarilyUnavailable
    case sourceGone
    case rateLimited
    case protonRestriction
    case cancelled
    case unsupported
    case permission
    case deviceStorage
    case accountStorage
    case localState
    case userDecision
    case partialCompletion
    case unknown
}

/// Background and safe-read contexts require the caller to prove the operation safe to repeat.
public enum FailureContext: Sendable, Equatable {
    case background
    case awaitedByPerson
    case bulkAction
    case safeRead
    case safeReadExhausted
    case mutation
}

public enum FailureRetryPolicy: Sendable, Equatable {
    case afterPersonAction
    case afterReconciliation
    case automatic
    case manual
    case never
}

public enum FailurePresentation: Sendable, Equatable {
    case silent
    case alert
}

public protocol FailureClassifiable {
    var failureCause: FailureCause { get }
}

/// A policy recommendation for future consumers. Existing retry and presentation paths do not use it yet.
public struct FailurePolicy: Sendable, Equatable {
    public let retryPolicy: FailureRetryPolicy
    public let presentation: FailurePresentation

    public static func resolve(_ cause: FailureCause, context: FailureContext) -> Self {
        switch cause {
        case .protonRestriction, .cancelled:
            Self(retryPolicy: .never, presentation: .silent)
        case .unsupported:
            Self(retryPolicy: .never, presentation: .alert)
        case .network, .rateLimited, .serviceTemporary, .sourceTemporarilyUnavailable:
            switch context {
            case .safeRead, .background: Self(retryPolicy: .automatic, presentation: .silent)
            case .safeReadExhausted: Self(retryPolicy: .manual, presentation: .alert)
            case .mutation, .awaitedByPerson, .bulkAction:
                Self(retryPolicy: .afterReconciliation, presentation: .alert)
            }
        case .authentication:
            Self(retryPolicy: .afterPersonAction, presentation: .alert)
        case .sourceGone:
            Self(retryPolicy: .never, presentation: .alert)
        case .permission, .deviceStorage, .accountStorage, .userDecision:
            Self(retryPolicy: .afterPersonAction, presentation: .alert)
        case .partialCompletion:
            Self(retryPolicy: .afterReconciliation, presentation: .alert)
        case .localState, .unknown:
            switch context {
            case .mutation, .awaitedByPerson, .bulkAction:
                Self(retryPolicy: .afterReconciliation, presentation: .alert)
            case .safeRead, .safeReadExhausted, .background:
                Self(retryPolicy: .manual, presentation: .alert)
            }
        }
    }
}
