import PhotosCore

extension UploadError: FailureClassifiable {
    public var failureCause: FailureCause {
        if Self.isCancellation(self) { return .cancelled }
        return switch self {
        case .unsupportedFile: .unsupported
        case .fileMissing, .sourceReportedMissing: .unknown
        case .permissionDenied: .permission
        case .transport: .network
        case .retryableBackend(let code, _): code == 429 ? .rateLimited : .serviceTemporary
        case .serviceRejected: .protonRestriction
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
        case .missing: .sourceGone
        case .transient: .sourceTemporarilyUnavailable
        }
    }
}

extension UploadRemoteCommitRecoveryError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        // Missing or invalid receipt data cannot be settled. Every other case may retain a remote commit.
        case .malformedReceipt, .invalidReceipt: .permanent
        case .storeUnavailable, .descriptorUnavailable, .descriptorMismatch, .receiptRemovalFailed: .partialCompletion
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
        case .remoteDraftStale: .permanent
        // UploadError.serviceRejected maps separately to protonRestriction. The persisted remoteService kind cannot
        // prove a refusal: generic backend, album, temporary and rate-limited failures also use it, so it remains unknown.
        case .remoteDraft, .sourceMissing, .remoteService, .unknown: .unknown
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
        case .needsFreeSpace, .diskBudgetExceeded: .deviceStorage
        }
    }
}

extension UploadRemoteCommitSettlementError: FailureClassifiable {
    public var failureCause: FailureCause { .partialCompletion }
}
