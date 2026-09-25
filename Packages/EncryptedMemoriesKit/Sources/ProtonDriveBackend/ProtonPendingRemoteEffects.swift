import AlbumCore
import Foundation
import PhotosCore
import ProtonAuth
import UploadCore

/// Applies pending-grid decisions to Proton: trash and restore of photos whose upload raced a delete, and
/// favorites or album adds that waited for an upload.
public struct ProtonPendingRemoteEffects: PendingRemoteEffects {
    private let trashProvider: (any TrashProvider)?
    private let favorites: (any FavoritesProvider)?
    private let albums: AlbumsRepository

    public init(facade: ProtonClientFacade) {
        trashProvider = facade.backend as? any TrashProvider
        favorites = facade.backend as? any FavoritesProvider
        albums = facade.albums
    }

    public func trash(_ uids: [PhotoUID]) async -> PendingEffectResult {
        guard let trashProvider else { return .retry }
        return await Self.run { try await trashProvider.trash(uids) }
    }

    public func restore(_ uids: [PhotoUID]) async -> PendingEffectResult {
        guard let trashProvider else { return .retry }
        return await Self.run { try await trashProvider.restore(uids) }
    }

    public func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        guard let favorites else { return .retry }
        return await Self.run { try await favorites.setFavorites([uid], favorite) }
    }

    public func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        await Self.run { try await albums.addPhotos([uid], to: albumID) }
    }

    /// Transport errors, 408, 429 and 5xx retry, as do unknown errors. Proton's per-item rejection of a batch
    /// (for example a photo already in or out of the trash) and other 4xx answers are final.
    static func run(_ operation: () async throws -> Void) async -> PendingEffectResult {
        do {
            try await operation()
            return .done
        } catch is DriveBatchActionError {
            return .permanentFailure
        } catch ProtonAuthError.apiError(let code, _) where (400...499).contains(code) && code != 408 && code != 429 {
            return .permanentFailure
        } catch {
            return .retry
        }
    }
}
