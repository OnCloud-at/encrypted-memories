import Foundation

/// One file that leaves the app for a picked photo. A Live Photo leaves as two files, its still and its
/// motion video, so the receiver can pair them again by their shared content identifier.
public struct OutboundMediaFile: Hashable, Sendable {
    /// The media whose original bytes leave the app.
    public let item: PhotoItem
    /// The photo that the user picked. The motion video of a Live Photo shows its still as the preview.
    public let picked: PhotoItem

    /// True for the motion video of a Live Photo. It is no photo of its own, so it never joins an album.
    public var isLivePhotoMotion: Bool { item.uid != picked.uid }
}

public enum OutboundMedia {
    /// The files for the picked photos, in order: each still directly followed by its motion video.
    public static func files(for picked: [PhotoItem]) -> [OutboundMediaFile] {
        var seen = Set<PhotoUID>()
        var files: [OutboundMediaFile] = []
        for item in picked where seen.insert(item.uid).inserted {
            files.append(OutboundMediaFile(item: item, picked: item))
            if let motion = livePhotoMotion(of: item), seen.insert(motion.uid).inserted {
                files.append(OutboundMediaFile(item: motion, picked: item))
            }
        }
        return files
    }

    /// The motion video of a Live Photo as an item of its own, or nil for every other photo.
    public static func livePhotoMotion(of item: PhotoItem) -> PhotoItem? {
        guard item.isLivePhoto, let motion = item.relatedVideoUID, motion != item.uid else { return nil }
        return PhotoItem(uid: motion, captureTime: item.captureTime, mediaType: "video/quicktime")
    }
}
