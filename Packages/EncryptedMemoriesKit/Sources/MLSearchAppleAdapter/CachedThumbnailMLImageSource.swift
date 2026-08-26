import MLSearchCore
import MediaFeedCore
import PhotosCore

/// Shared Apple-platform image source for semantic indexing.
///
/// It reuses the universal encrypted thumbnail cache and never starts a download. Missing
/// thumbnails remain transient so a later indexing pass can pick them up after normal library
/// prefetch, without ML work competing with the visible grid. One source instance is shared by
/// native and semantic indexing. Its small ML-only cache does not enter the grid decoded LRU.
public struct CachedThumbnailMLImageSource: CoreMLImageSource {
    private let coordinator: CachedThumbnailMLImageSourceCoordinator

    public init(feed: ThumbnailFeedCore) {
        self.coordinator = CachedThumbnailMLImageSourceCoordinator { uid in
            switch await feed.backgroundThumbnailDecodeResult(for: uid) {
            case .decoded(let thumbnail):
                return .image(CoreMLSourceImage(cgImage: thumbnail.image))
            case .undecodable:
                return .permanentFailure(reason: "cached thumbnail cannot be decoded")
            case .missing:
                if feed.isKnownUnfetchable(uid) {
                    return .permanentFailure(reason: "thumbnail unavailable from backend")
                }
                return .transientFailure
            }
        }
    }

    init(load: @escaping @Sendable (PhotoUID) async -> CoreMLSourceImage?) {
        self.coordinator = CachedThumbnailMLImageSourceCoordinator { uid in
            if let image = await load(uid) { return .image(image) }
            return .transientFailure
        }
    }

    init(resolve: @escaping @Sendable (PhotoUID) async -> CoreMLImageSourceOutcome) {
        self.coordinator = CachedThumbnailMLImageSourceCoordinator(resolve: resolve)
    }

    public func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        await coordinator.image(for: uid)
    }
}

private actor CachedThumbnailMLImageSourceCoordinator {
    private struct CachedImage {
        let image: CoreMLSourceImage
        let cost: Int
    }

    /// This is one shared ML-source cache, not a second grid cache. The fixed byte and entry
    /// caps prevent the source from growing with the library while native and semantic passes
    /// reuse the same decoded thumbnail.
    private static let maximumCachedBytes = 32 * 1024 * 1024
    private static let maximumCachedEntries = 128

    private let resolve: @Sendable (PhotoUID) async -> CoreMLImageSourceOutcome
    private var cached: [PhotoUID: CachedImage] = [:]
    private var order: [PhotoUID] = []
    private var cachedBytes = 0
    private var inFlight: [PhotoUID: Task<CoreMLImageSourceOutcome, Never>] = [:]

    init(resolve: @escaping @Sendable (PhotoUID) async -> CoreMLImageSourceOutcome) {
        self.resolve = resolve
    }

    func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        if let cachedImage = cached[uid] {
            touch(uid)
            return .image(cachedImage.image)
        }
        if let task = inFlight[uid] {
            return await task.value
        }

        let resolve = self.resolve
        let task = Task { await resolve(uid) }
        inFlight[uid] = task
        let outcome = await task.value
        inFlight.removeValue(forKey: uid)
        if case .image(let image) = outcome {
            insert(image, for: uid)
        }
        return outcome
    }

    private func insert(_ image: CoreMLSourceImage, for uid: PhotoUID) {
        let height = max(1, image.cgImage.height)
        let rowBytes = max(1, image.cgImage.bytesPerRow)
        let bytes = rowBytes.multipliedReportingOverflow(by: height)
        guard !bytes.overflow else { return }
        let cost = max(1, bytes.partialValue)
        guard cost <= Self.maximumCachedBytes else { return }

        if let previous = cached.updateValue(CachedImage(image: image, cost: cost), forKey: uid) {
            cachedBytes -= previous.cost
            order.removeAll { $0 == uid }
        }
        order.append(uid)
        cachedBytes += cost
        while cachedBytes > Self.maximumCachedBytes || cached.count > Self.maximumCachedEntries {
            guard let oldest = order.first else { break }
            order.removeFirst()
            guard let removed = cached.removeValue(forKey: oldest) else { continue }
            cachedBytes -= removed.cost
        }
    }

    private func touch(_ uid: PhotoUID) {
        order.removeAll { $0 == uid }
        order.append(uid)
    }
}
