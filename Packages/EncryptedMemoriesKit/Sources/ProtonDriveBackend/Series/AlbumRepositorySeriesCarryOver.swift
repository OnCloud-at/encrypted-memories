import AlbumCore
import Foundation
import PhotosCore
import UploadCore

/// Carries the albums of a series over to the standalone copies of its favorites.
///
/// The repository owns the album contract for the whole account: its membership read is the SDK catalog, and
/// its add throws unless every photo is a member afterwards. The dissolution therefore shares one album
/// semantic with the rest of the app instead of a second write path.
struct AlbumRepositorySeriesCarryOver: SeriesAlbumCarryOver {
    let repository: AlbumsRepository

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        let memberships = try await repository.albumMemberships(for: [uid])
        return (memberships[uid] ?? []).map {
            SeriesAlbumReference(volumeID: $0.volumeID, albumID: $0.nodeID)
        }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        guard !uids.isEmpty else { return }
        try await repository.addPhotos(uids, to: albumID)
    }
}
