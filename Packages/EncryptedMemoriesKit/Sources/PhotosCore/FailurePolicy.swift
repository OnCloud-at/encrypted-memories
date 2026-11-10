import Foundation

/// A cause carries only what is known. Unknown failures do not prove a fixed restriction.
public enum FailureCause: Sendable, Equatable, CaseIterable {
    /// A network connection failed.
    case network
    /// A service reported a temporary failure.
    case serviceTemporary
    /// A local runtime or resource is temporarily unavailable.
    case localTransient
    /// The account needs sign-in.
    case authentication
    /// A source may become available without a new selection.
    case sourceTemporarilyUnavailable
    /// A selected source is missing; a new source selection is needed.
    case sourceGone
    /// The service limited the request rate.
    case rateLimited
    /// A fixed Proton rule rejects the operation; #1152 supplies this cause.
    case protonRestriction
    /// The operation was cancelled; a cancelled write may still have committed.
    case cancelled
    /// The current app or content cannot perform the operation.
    case unsupported
    /// No person action or repeat can fix this operation in its current conditions.
    case permanent
    /// Access is denied until permissions or roles change.
    case permission
    /// The device needs storage or its staging budget is exhausted.
    case deviceStorage
    /// The Proton account needs more storage.
    case accountStorage
    /// Local state cannot support the operation.
    case localState
    /// A person must choose or change something before continuing.
    case userDecision
    /// The operation changed remote state for part of its scope, or for an unconfirmed part, so repeating it can
    /// duplicate or conflict. Carriers include AlbumError.partialAdd and partialAddWithCauses,
    /// albumCreatedButPhotosNotAdded, FavoriteMutationError with non-empty succeeded,
    /// UploadRemoteCommitSettlementError and UploadRemoteCommitRecoveryError.storeUnavailable,
    /// descriptorUnavailable, descriptorMismatch and receiptRemovalFailed. Those recovery failures may retain a
    /// receipt. Malformed or invalid receipt data cannot be settled and maps to permanent instead.
    case partialCompletion
    /// The available evidence does not identify the cause.
    case unknown
}

/// Who is waiting for the result. The caller also supplies operation safety and retry exhaustion.
public enum FailureSituation: Sendable, Equatable, CaseIterable {
    /// No person is waiting for this result.
    case background
    /// A person is waiting for this operation.
    case awaitedByPerson
    /// The operation is part of a bulk action.
    case bulkAction
}

/// Whether an operation can be repeated without first reconciling remote state.
public enum FailureOperationSafety: Sendable, Equatable, CaseIterable {
    /// Repeating the read cannot change remote state.
    case safeRead
    /// The operation may have changed remote state.
    case mutation
}

public enum FailureRetryRule: Sendable, Equatable {
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

/// Recognizes native cancellation without inspecting error descriptions.
public enum FailureCancellation {
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

/// A policy recommendation for future consumers. Existing retry and presentation paths do not use it yet.
/// The model supersedes VideoPlaybackError, BackupIssueKind and MLRuntimeFailure `isRetryable`, AlbumWriteCause
/// `isTransient`, MLRuntimeFailure `isPermanent`, `offersUserRetry`, `canRetry`, and the follow-up replacement of
/// `canRetryMerge` in ExactDuplicatesModel.
/// `retriesExhausted` prevents automatic retries. Manual retry can remain for network and other transient reads,
/// and for unknown and local-state reads.
public struct FailurePolicy: Sendable, Equatable {
    public let retry: FailureRetryRule
    public let presentation: FailurePresentation

    public static func resolve(
        _ cause: FailureCause, situation: FailureSituation, safety: FailureOperationSafety,
        retriesExhausted: Bool = false
    ) -> Self {
        switch cause {
        case .protonRestriction:
            Self(retry: .never, presentation: situation == .background ? .silent : .alert)
        case .cancelled:
            safety == .mutation
                ? Self(retry: .afterReconciliation, presentation: .alert)
                : Self(retry: .never, presentation: .silent)
        case .unsupported, .permanent, .sourceGone:
            Self(retry: .never, presentation: .alert)
        case .network, .rateLimited, .serviceTemporary, .localTransient, .sourceTemporarilyUnavailable:
            if safety == .mutation {
                Self(retry: .afterReconciliation, presentation: .alert)
            } else if retriesExhausted {
                Self(retry: .manual, presentation: .alert)
            } else {
                Self(retry: .automatic, presentation: .silent)
            }
        case .authentication, .permission, .deviceStorage, .accountStorage, .userDecision:
            Self(retry: .afterPersonAction, presentation: .alert)
        case .partialCompletion:
            Self(retry: .afterReconciliation, presentation: .alert)
        case .localState, .unknown:
            safety == .mutation
                ? Self(retry: .afterReconciliation, presentation: .alert)
                : Self(retry: .manual, presentation: .alert)
        }
    }
}
