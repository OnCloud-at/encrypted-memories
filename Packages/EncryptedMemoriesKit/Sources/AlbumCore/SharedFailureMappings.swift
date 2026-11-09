import Foundation
import PhotosCore

extension AlbumError: FailureClassifiable {
    public var failureCause: FailureCause {
        switch self {
        case .unsupported: .unsupported
        case .sharedAlbumReadOnly(.roleDoesNotPermitEditing): .permission
        case .sharedAlbumReadOnly(.transportUnsupported): .unsupported
        case .requestFailed(let cause):
            switch cause.kind {
            case .cancelled: .cancelled
            case .network(let code) where code == URLError.cancelled.rawValue: .cancelled
            case .network where cause.isTransient: .network
            case .http where cause.isTransient: .serviceTemporary
            case .network, .http, .unknown: .unknown
            }
        case .albumCreatedButPhotosNotAdded, .partialAdd, .partialAddWithCauses: .partialCompletion
        case .backend: .unknown
        }
    }
}
