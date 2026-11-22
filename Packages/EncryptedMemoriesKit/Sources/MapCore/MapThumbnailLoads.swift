import Foundation
import PhotosCore

/// The in-flight thumbnail loads of one map. A photo has at most one load at a time, a load that was cancelled
/// never applies its image (its pin left the map, and the view may be recycled), and every load stops when the
/// map goes away. `Image` is `NSImage` on the Mac and `UIImage` on iPhone and iPad.
@MainActor
public final class MapThumbnailLoads<Image> {
    private struct Load {
        /// Tells a load apart from a newer load of the same photo.
        let generation: Int
        let task: Task<Void, Never>
    }

    private var loads: [PhotoUID: Load] = [:]
    private var nextGeneration = 0

    public init() {}

    deinit {
        for (_, load) in loads { load.task.cancel() }
    }

    /// Starts a load for `uid` unless one already runs. `apply` receives the image when the load returned one and was
    /// not cancelled; a load that returns no image changes nothing and frees the slot for a later request.
    public func requestIfNeeded(
        _ uid: PhotoUID,
        load: @escaping (PhotoUID) async -> Image?,
        apply: @escaping (Image, PhotoUID) -> Void
    ) {
        guard loads[uid] == nil else { return }
        nextGeneration += 1
        let generation = nextGeneration
        let task = Task { @MainActor [weak self] in
            let image = await load(uid)
            guard let self else { return }
            // A cancelled load may return after a newer load of the same photo took the slot: it must not free it.
            if self.loads[uid]?.generation == generation { self.loads.removeValue(forKey: uid) }
            if Task.isCancelled { return }
            guard let image else { return }
            apply(image, uid)
        }
        loads[uid] = Load(generation: generation, task: task)
    }

    /// Cancels the loads of the photos whose pins left the map.
    public func cancel(_ uids: some Sequence<PhotoUID>) {
        for uid in uids { loads.removeValue(forKey: uid)?.task.cancel() }
    }
}
