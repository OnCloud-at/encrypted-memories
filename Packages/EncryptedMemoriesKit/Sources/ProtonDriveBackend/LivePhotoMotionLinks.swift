import Foundation
import PhotosCore

/// The motion of a Live Photo, chosen among its related files.
enum LivePhotoMotion: Equatable, Sendable {
    case video(String)
    /// No related file is a video, for example only the adjustment data of an edit: the photo shows no Live control.
    case noVideo
    /// The listing names no related file yet, or the type of a related file is not known.
    case unknown

    var linkID: String? {
        if case .video(let linkID) = self { return linkID }
        return nil
    }
}

/// Chooses the motion of a Live Photo among its related files. The photos listing names the related files without their
/// type and lists the newest first, so an edited Live Photo can name its adjustment data first. The type of a link does
/// not change, so a type read once stays valid for the whole session.
struct LivePhotoMotionLinks: Sendable {
    /// Types read for related files, by link ID. An empty type marks a file that the read returned without a type.
    private(set) var mimeTypes: [String: String] = [:]

    /// One related file is the motion, without a type check. Of several, the first video in listing order is the
    /// motion: the backup uploads the Live Photo video last, and earlier versions uploaded it after the edited motion.
    static func motion(among related: [String], mimeTypes: [String: String]) -> LivePhotoMotion {
        guard related.count > 1 else { return related.first.map(LivePhotoMotion.video) ?? .unknown }
        for linkID in related {
            guard let mimeType = mimeTypes[linkID] else { return .unknown }
            if mimeType.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("video/") { return .video(linkID) }
        }
        return .noVideo
    }

    /// Names this motion rule in the stored timeline. A change of the rule changes the name, so the next refresh reads
    /// the types again instead of trusting motions that an earlier rule chose.
    static let rule = "liveMotion.firstRelatedVideo.1"

    /// The motions in the stored timeline that still hold for these Live Photos (link ID to related files): this rule
    /// chose them, and the stored video is still one of the related files of the photo. A Live Photo with one related
    /// file needs none. An edit uploads a new photo, so its stored row does not exist yet.
    static func storedMotions(
        of livePhotos: [String: [String]], volumeID: String, in store: TimelineMetadataStore?
    ) -> [String: String] {
        let several = livePhotos.filter { $0.value.count > 1 }
        guard let store, !several.isEmpty else { return [:] }
        let uids = several.keys.sorted().map { PhotoUID(volumeID: volumeID, nodeID: $0) }
        return store.relatedVideoIDs(for: uids, chosenBy: rule).filter { several[$0.key]?.contains($0.value) == true }
    }

    /// The motion of each of these Live Photos (link ID to related files in listing order). A `stored` motion holds
    /// without a read. The other photos with several related files use `evidence`, the types read earlier in this
    /// session, and one `fetch` of the related files that neither holds. `read` holds the answer for this session: a
    /// link without a type in the answer is no video. A failed read leaves `complete` false and its files unread, so the
    /// next refresh reads them again.
    func motions(
        of livePhotos: [String: [String]], stored: [String: String], evidence: [String: String],
        fetch: (_ linkIDs: [String]) async throws -> [String: String]
    ) async throws -> (motions: [String: LivePhotoMotion], read: [String: String], complete: Bool) {
        var seen = Set<String>()
        let unread = livePhotos.keys.sorted().flatMap { linkID -> [String] in
            guard let related = livePhotos[linkID], related.count > 1, stored[linkID] == nil else { return [] }
            return related.filter { evidence[$0] == nil && mimeTypes[$0] == nil && seen.insert($0).inserted }
        }
        var read: [String: String] = [:]
        var complete = true
        if !unread.isEmpty {
            do {
                let answer = try await fetch(unread)
                for linkID in unread { read[linkID] = answer[linkID] ?? "" }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                complete = false
                DebugLog.log("timeline: type of \(unread.count) Live Photo related files unread - \(error)")
            }
        }
        let types = evidence.merging(mimeTypes.merging(read) { _, read in read }) { evidence, _ in evidence }
        let motions = livePhotos.reduce(into: [String: LivePhotoMotion]()) { motions, photo in
            motions[photo.key] =
                stored[photo.key].map(LivePhotoMotion.video) ?? Self.motion(among: photo.value, mimeTypes: types)
        }
        return (motions, read, complete)
    }

    /// Keeps the `read` answer of `motions(of:stored:evidence:fetch:)` for this session.
    mutating func record(_ read: [String: String]) {
        mimeTypes.merge(read) { _, read in read }
    }
}
