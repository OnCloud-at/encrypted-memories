import PhotosCore

extension AlbumSyncError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .nameConflict: .userDecision
        case .mappingStoreUnavailable: .localState
        case .stopped: .cancelled
        case .localAlbumMissing, .alreadyRunning: .unknown
        }
    }
}
