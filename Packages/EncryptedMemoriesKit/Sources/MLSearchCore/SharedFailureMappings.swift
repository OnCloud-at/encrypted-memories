import PhotosCore

extension MLRuntimeFailure: FailureClassifiable {
    public var failureCause: FailureCause {
        switch category {
        case .network: .network
        case .missingModel, .incompatibleModel, .invalidOutputSchema, .invalidStaticInputContract: .permanent
        // These are local runtime conditions; they do not establish a service failure.
        case .temporaryResource, .retryableRuntimeState: .localTransient
        case .unknown: .unknown
        }
    }
}

extension MLModelInstallError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .insufficientStorage: .deviceStorage
        case .cancelled: .cancelled
        case .licenseProhibitsDistribution: .unsupported
        // The catalog entry alone decides these, so a new download repeats them.
        case .notDownloadable, .unsafeArtifactPath, .ambiguousModelArtifact: .permanent
        case .sizeMismatch, .checksumMismatch, .artifactMissing, .installRecordUnreadable: .unknown
        }
    }
}
