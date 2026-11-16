import AlbumCore
import Foundation
import PhotosCore

/// A final catalog-read failure, separate from album write outcomes and partial success.
public struct AlbumFailurePresentation: Sendable, Equatable {
    public let message: String
    public let canRetry: Bool

    public static func read(_ error: any Error) -> Self? {
        if Task.isCancelled || FailureCancellation.isCancellation(error) {
            return nil
        }
        if let albumError = error as? AlbumError {
            if let cause = albumError.writeCause {
                switch cause.kind {
                case .cancelled, .network(code: URLError.cancelled.rawValue): return nil
                default: break
                }
            }
            switch albumError {
            case .unsupported, .sharedAlbumReadOnly:
                return Self(message: albumError.localizedDescription, canRetry: false)
            default: break
            }
        }
        // An unclassified failure is not proof that another read cannot succeed.
        return Self(message: L10n.string("albums.load_failed_message"), canRetry: true)
    }

    /// The alert text of a failed album-cover change; nil shows no alert. An album outcome that names its reason
    /// shows that reason. Every other failure shows the generic text that the host supplies.
    public static func coverMessage(
        for error: any Error, text: (LibraryActionFailureMessage.Text) -> String
    ) -> String? {
        let albumError = error as? AlbumError
        return LibraryActionFailureMessage.message(
            for: error, action: .albumCover, specificAlbumReason: albumError?.coverReason,
            underlyingError: albumError?.underlyingCause, text: text)
    }
}

extension AlbumError {
    fileprivate var coverReason: String? {
        switch self {
        case .unsupported, .sharedAlbumReadOnly, .albumCreatedButPhotosNotAdded, .partialAdd, .partialAddWithCauses:
            errorDescription
        case .backend, .requestFailed:
            nil
        }
    }
}
