import Foundation
import PhotosCore

extension UploadError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .unsupportedFile: .unsupported
        case .fileMissing, .sourceReportedMissing: .unknown
        case .permissionDenied: .permission
        case .transport(let code, _): code == URLError.cancelled.rawValue ? .cancelled : .network
        case .retryableBackend: .serviceTemporary
        case .cancelled: .cancelled
        case .accountStorageFull: .accountStorage
        case .tagAdderUnavailable: .localState
        case .sourceNotReady, .sourceUnavailable: .sourceTemporarilyUnavailable
        case .backend, .albumStep: .unknown
        }
    }
}

extension FolderEnumerationError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch failureClass {
        case .permissionDenied: .permission
        case .missing, .transient: .unknown
        }
    }
}

extension UploadRemoteCommitRecoveryError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .storeUnavailable, .malformedReceipt, .invalidReceipt, .receiptRemovalFailed: .localState
        case .descriptorUnavailable, .descriptorMismatch: .unknown
        }
    }
}

extension BackupIssueKind: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .network: .network
        case .deviceStorage: .deviceStorage
        case .permission: .permission
        case .unsupported: .unsupported
        case .localState: .localState
        case .remoteDeletion, .deletedElsewhere: .userDecision
        case .accountStorage: .accountStorage
        case .remoteDraft, .remoteDraftStale, .sourceMissing, .remoteService, .unknown: .unknown
        }
    }
}

extension SeriesDissolutionError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .invalidSelection: .userDecision
        case .libraryUnavailable: .localState
        case .notOwnLibrary, .alreadyRunning, .blockedByForeignDraft, .copyNotConfirmed, .trashNotConfirmed: .unknown
        }
    }
}

extension BackupTempFileStore.BackupTempFileError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .needsFreeSpace: .deviceStorage
        case .diskBudgetExceeded: .unknown
        }
    }
}

extension UploadRemoteCommitSettlementError: FailureClassifiable {
    public var failureCause: FailureCause { .partialCompletion }
}
