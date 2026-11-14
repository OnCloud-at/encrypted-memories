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

    /// The still of each Live Photo motion in `items`, by the motion's UID. A motion pairs only with a still that comes
    /// before it, so an export that waits for the still's name never waits for a file that starts later.
    public static func stillsByMotion(in items: [PhotoItem]) -> [PhotoUID: PhotoUID] {
        var firstIndex: [PhotoUID: Int] = [:]
        for (index, item) in items.enumerated() where firstIndex[item.uid] == nil { firstIndex[item.uid] = index }
        var stills: [PhotoUID: PhotoUID] = [:]
        for (index, item) in items.enumerated() {
            guard let motion = livePhotoMotion(of: item)?.uid, let motionIndex = firstIndex[motion],
                motionIndex > index, stills[motion] == nil
            else { continue }
            stills[motion] = item.uid
        }
        return stills
    }

    /// The motion video of a Live Photo as an item of its own, or nil for every other photo.
    public static func livePhotoMotion(of item: PhotoItem) -> PhotoItem? {
        guard item.isLivePhoto, let motion = item.relatedVideoUID, motion != item.uid else { return nil }
        return PhotoItem(uid: motion, captureTime: item.captureTime, mediaType: "video/quicktime")
    }
}

/// The names that the stills of one export received, for their Live Photo motions
/// (`OriginalFileNaming.livePhotoMotionFilename`). A still records its name, or nil when it did not leave; a motion
/// waits for that answer. `OutboundMedia.stillsByMotion` pairs a motion only with an earlier still, so the still has
/// started when its motion waits.
actor OutboundStillNames {
    private var names: [PhotoUID: String?] = [:]
    private var waiters: [PhotoUID: [CheckedContinuation<String?, Never>]] = [:]

    init() {}

    /// Records the name that `still` received, or nil when it did not leave. The first answer counts.
    func record(_ name: String?, for still: PhotoUID) {
        guard names[still] == nil else { return }
        names[still] = .some(name)
        for waiter in waiters.removeValue(forKey: still) ?? [] { waiter.resume(returning: name) }
    }

    /// The name that `still` received, after it is recorded.
    func name(of still: PhotoUID) async -> String? {
        if let known = names[still] { return known }
        return await withCheckedContinuation { waiters[still, default: []].append($0) }
    }

    /// Ends every wait without a name, for an export that stops.
    func abandonAll() {
        for (still, list) in waiters {
            names[still] = .some(nil)
            for waiter in list { waiter.resume(returning: nil) }
        }
        waiters.removeAll()
    }
}

/// The names of the files of one drag whose receiver writes them under the names given here (macOS file promises).
/// Each name is unique in the drag, so no two files of the drag share a name, and a Live Photo motion takes the name its
/// still received. The first name of a file holds for the whole drag.
public struct OutboundFileNames: Sendable {
    private let stillOfMotion: [PhotoUID: PhotoUID]
    private var assigned: [PhotoUID: String] = [:]
    private var used = UniqueNameSet()

    public init(items: [PhotoItem]) {
        stillOfMotion = OutboundMedia.stillsByMotion(in: items)
    }

    /// The name of `uid`; `own` names a file on its own.
    public mutating func name(for uid: PhotoUID, own: (PhotoUID) -> String) -> String {
        if let name = assigned[uid] { return name }
        var name = own(uid)
        if let still = stillOfMotion[uid] {
            name = OriginalFileNaming.livePhotoMotionFilename(name, stillName: self.name(for: still, own: own))
        }
        let unique = used.unique(name)
        assigned[uid] = unique
        return unique
    }
}
