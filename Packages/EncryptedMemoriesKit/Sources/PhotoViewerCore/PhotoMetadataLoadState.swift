import PhotosCore

/// Truthful lifecycle for the viewer's lazily loaded metadata. A missing value is not enough to distinguish
/// loading from a failed request, so every platform renders this shared state instead of inferring it.
public enum PhotoMetadataLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(PhotoMetadata)
    case failed

    public var metadata: PhotoMetadata? {
        guard case .loaded(let metadata) = self else { return nil }
        return metadata
    }
}
