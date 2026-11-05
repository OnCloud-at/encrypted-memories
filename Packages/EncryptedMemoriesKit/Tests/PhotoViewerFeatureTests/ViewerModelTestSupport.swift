import Foundation
import MediaByteCache
import MediaCache
import PhotosCore

/// Small fakes that viewer model tests share: a thumbnail loader that delivers nothing and a media provider that fails.
struct MetadataEmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

struct MetadataFailingMediaProvider: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw MetadataTestError.unavailable }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw MetadataTestError.unavailable
    }
}

enum MetadataTestError: Error {
    case unavailable
}
