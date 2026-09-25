import Foundation
import MediaDecodingCore
import PhotosCore

/// Loads thumbnails of local pending photos (Apple Photos assets, watched files) from the device. The feed
/// keeps them in memory only: no encrypted disk copy, no coverage checkpoint, no Proton request.
public protocol LocalThumbnailLoading: Sendable {
    /// Decoded images at most `maxPixelSize` on the long side. A missing identity has no image right now.
    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail]
}

/// Which local pending photos the feed may show. The host replaces the set whenever the pending grid changes
/// and clears it on account teardown, when backup turns off, or when Photos access ends.
final class LocalThumbnailAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = Set<PhotoUID>()

    func isAllowed(_ uid: PhotoUID) -> Bool {
        lock.withLock { allowed.contains(uid) }
    }

    var snapshot: Set<PhotoUID> { lock.withLock { allowed } }

    /// Replaces the set and returns what changed.
    func replace(with uids: Set<PhotoUID>) -> (added: Set<PhotoUID>, removed: Set<PhotoUID>) {
        lock.withLock {
            let added = uids.subtracting(allowed)
            let removed = allowed.subtracting(uids)
            allowed = uids
            return (added, removed)
        }
    }
}
