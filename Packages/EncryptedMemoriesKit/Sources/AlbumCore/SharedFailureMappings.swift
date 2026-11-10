import PhotosCore

extension AlbumError: FailureClassifiable {
    public var failureCause: FailureCause {
        if case .requestFailed(let cause) = self, FailureCancellation.isCancellation(cause.underlyingError) {
            return .cancelled
        }
        return switch self {
        case .unsupported: .unsupported
        case .sharedAlbumReadOnly(.roleDoesNotPermitEditing): .permission
        case .sharedAlbumReadOnly(.transportUnsupported): .unsupported
        case .requestFailed(let cause):
            switch cause.kind {
            case .cancelled: .cancelled
            case .network where cause.isTransient: .network
            case .http(let status) where status == 429: .rateLimited
            case .http where cause.isTransient: .serviceTemporary
            case .network, .http, .unknown: .unknown
            }
        case .albumCreatedButPhotosNotAdded, .partialAdd, .partialAddWithCauses: .partialCompletion
        case .backend: .unknown
        }
    }
}
