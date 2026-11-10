import Foundation
import PhotosCore

/// The motion of a Live Photo, chosen among its related files.
enum LivePhotoMotion: Equatable, Sendable {
    case video(String)
    /// No related file is a video, for example only the adjustment data of an edit: the photo shows no Live control.
    case noVideo
    /// The listing names no related file yet, the type of a related file is not known, or the name of a video is not
    /// known while the photo has two or more videos.
    case unknown

    var linkID: String? {
        if case .video(let linkID) = self { return linkID }
        return nil
    }

    /// The timeline shows a Live control unless no related file is a video. An unknown motion keeps the control, so a
    /// failed type read does not hide it; the next refresh reads the type again.
    var showsLiveControl: Bool { self != .noVideo }
}

/// Chooses the motion of a Live Photo among its related files. The photos listing names the related files without their
/// type and lists the newest first, so an edited Live Photo can name its adjustment data first. The type of a link does
/// not change. A type or a name read once stays valid for the session, and a renamed video changes only a motion that
/// the timeline has not stored.
struct LivePhotoMotionLinks: Sendable {
    /// Types read for related files, by link ID. An empty type marks a file that the read returned without a type.
    private(set) var mimeTypes: [String: String] = [:]
    /// Names read for related files, by link ID. An empty name marks a file whose name did not decrypt.
    private(set) var names: [String: String] = [:]

    /// The answer of one read: the types and the names of the files it read.
    struct Read: Equatable, Sendable {
        var types: [String: String] = [:]
        var names: [String: String] = [:]
    }

    /// The answer of one metadata read: each read file with its type and, where the read decrypted it, its name.
    /// `namesRead` is false when the names could not be decrypted; the types still hold.
    struct Answer: Sendable {
        var files: [String: BurstFrameVerdicts.RelatedFile]
        var namesRead = true
    }

    /// The answer for the `links` of one metadata read whose names `nameLinkIDs` asks for. Only a video can be the
    /// edited motion, and the read delivers each type together with the name, so only the requested names of videos
    /// decrypt. A failed root key read keeps the types, like the order pass of the same load: only the photos that
    /// need a name stay undecided until the next refresh.
    static func answer<Key>(
        links: [AlbumPhotoLinkBody], nameLinkIDs: Set<String>, rootKey: () async throws -> Key,
        decrypt: (_ armoredName: String, _ rootKey: Key) throws -> String
    ) async throws -> Answer {
        do {
            let files = try await RelatedFileRead.files(
                in: links,
                decryptingNamesWhere: { link in
                    (link.linkID.map(nameLinkIDs.contains) ?? false) && isVideo(link.mimeType ?? "")
                }, rootKey: rootKey, decrypt: decrypt)
            return Answer(files: files)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DebugLog.log("timeline: Live Photo video names unread, root key unavailable - \(error)")
            let files = try await RelatedFileRead.files(
                in: links, decryptingNamesWhere: { _ in false }, rootKey: rootKey, decrypt: decrypt)
            return Answer(files: files, namesRead: false)
        }
    }

    /// The motion is the edited motion when the Live Photo has one, otherwise its first video in listing order.
    ///
    /// The backup uploads every file of an edited Live Photo: Photos plays the rendered edit (`fullSizePairedVideo`,
    /// named `FullSizeRender.mov`), and the original motion uploads last, so it is the first video. A related file carries
    /// no role, so only the name of a video tells the edit apart, and only a Live Photo with two or more videos needs it.
    /// A file that is not a video is never the motion, even as the only related file: an edit of an earlier version can
    /// leave only the adjustment data.
    ///
    /// Any file without a read type, or a video without a read name, can be the edited motion, so the motion stays
    /// unknown. An empty name did not decrypt; that video is not the edit.
    static func motion(
        among related: [String], mimeTypes: [String: String], names: [String: String]
    ) -> LivePhotoMotion {
        guard !related.isEmpty else { return .unknown }
        var videos: [String] = []
        for linkID in related {
            guard let mimeType = mimeTypes[linkID] else { return .unknown }
            if isVideo(mimeType) { videos.append(linkID) }
        }
        guard let first = videos.first else { return .noVideo }
        guard videos.count > 1 else { return .video(first) }
        for linkID in videos {
            guard let name = names[linkID] else { return .unknown }
            if isEditedMotion(name) { return .video(linkID) }
        }
        return .video(first)
    }

    private static func isVideo(_ mimeType: String) -> Bool {
        mimeType.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("video/")
    }

    /// Photos names the rendered motion of an edited Live Photo `FullSizeRender`, and the backup keeps that name.
    private static func isEditedMotion(_ name: String) -> Bool {
        (name as NSString).deletingPathExtension.lowercased() == "fullsizerender"
    }

    /// Names this motion rule in the stored timeline. A change of the rule changes the name, so the next refresh reads
    /// the types and names again instead of trusting motions that an earlier rule chose.
    static let rule = "liveMotion.editedOrFirstVideo.3"

    /// The motions in the stored timeline that still hold for these Live Photos (link ID to related files): this rule
    /// chose them, and the stored video is still one of the related files of the photo. An edit uploads a new photo, so
    /// its stored row does not exist yet.
    static func storedMotions(
        of livePhotos: [String: [String]], volumeID: String, in store: TimelineMetadataStore?
    ) -> [String: String] {
        let related = livePhotos.filter { !$0.value.isEmpty }
        guard let store, !related.isEmpty else { return [:] }
        let uids = related.keys.sorted().map { PhotoUID(volumeID: volumeID, nodeID: $0) }
        return store.relatedVideoIDs(for: uids, chosenBy: rule).filter { related[$0.key]?.contains($0.value) == true }
    }

    /// The motion of each of these Live Photos (link ID to related files in listing order). A `stored` motion holds
    /// without a read. The other photos use `evidence`, the types and names read earlier in this session, and one `fetch`
    /// of the related files that neither holds. The fetch also asks for the names (`nameLinkIDs`) of the files that are or
    /// can be videos of a photo with two or more of them. `read` holds the answer for this session: a link without a type
    /// in the answer is no video, and a link without a name in the answer is not the edited motion. A failed read, or a
    /// read whose names did not decrypt, leaves those files unread, so the next refresh reads them again.
    func motions(
        of livePhotos: [String: [String]], stored: [String: String], evidence: [String: String],
        allowFetch: Bool = true,
        fetch: (_ linkIDs: [String], _ nameLinkIDs: Set<String>) async throws -> Answer
    ) async throws -> (motions: [String: LivePhotoMotion], read: Read) {
        let typeOf = { (link: String) in evidence[link] ?? mimeTypes[link] }
        var seen = Set<String>()
        var nameLinkIDs = Set<String>()
        let unread = livePhotos.keys.sorted().flatMap { linkID -> [String] in
            guard let related = livePhotos[linkID], stored[linkID] == nil else { return [] }
            let possibleVideos = related.filter { typeOf($0).map(Self.isVideo) ?? true }
            let needsName = Set(possibleVideos.count > 1 ? possibleVideos.filter { names[$0] == nil } : [])
            nameLinkIDs.formUnion(needsName)
            return related.filter { (typeOf($0) == nil || needsName.contains($0)) && seen.insert($0).inserted }
        }
        var read = Read()
        if !unread.isEmpty, allowFetch {
            do {
                let answer = try await fetch(unread, nameLinkIDs)
                for linkID in unread where typeOf(linkID) == nil {
                    read.types[linkID] = answer.files[linkID]?.mimeType ?? ""
                }
                if answer.namesRead {
                    for linkID in nameLinkIDs { read.names[linkID] = answer.files[linkID]?.name ?? "" }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.log("timeline: type or name of \(unread.count) Live Photo related files unread - \(error)")
            }
        }
        let types = evidence.merging(mimeTypes.merging(read.types) { _, read in read }) { evidence, _ in evidence }
        let names = names.merging(read.names) { _, read in read }
        let motions = livePhotos.reduce(into: [String: LivePhotoMotion]()) { motions, photo in
            motions[photo.key] =
                stored[photo.key].map(LivePhotoMotion.video)
                ?? Self.motion(among: photo.value, mimeTypes: types, names: names)
        }
        return (motions, read)
    }

    /// Keeps the `read` answer of `motions(of:stored:evidence:fetch:)` for this session.
    mutating func record(_ read: Read) {
        mimeTypes.merge(read.types) { _, read in read }
        names.merge(read.names) { _, read in read }
    }
}
