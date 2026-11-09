extension VideoPlaybackError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .networkUnavailable: .network
        case .quotaOrRateLimited: .rateLimited
        case .streamURLUnavailable: .unsupported
        case .authExpired: .authentication
        case .notVideo, .unsupportedCodec, .decryptionFailed, .malformedContent: .permanent
        case .metadataUnavailable, .rangeNotSupported, .timedOut, .localFileError, .playerItemFailed, .unknown: .unknown
        }
    }
}

extension OriginalExportWriter.Failure: FailureClassifiable {
    public var failureCause: FailureCause { .deviceStorage }
}

extension DragOutStagingFailure: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .cancelled: .cancelled
        case .diskSpaceInsufficient: .deviceStorage
        case .writeFailed: .unknown
        }
    }
}

extension FavoriteMutationError: FailureClassifiable {
    public var failureCause: FailureCause { succeeded.isEmpty ? .unknown : .partialCompletion }
}
