import Foundation
import PhotosCore
import UploadCore

/// The motion of a Live Photo, chosen among its related files.
enum LivePhotoMotion: Equatable, Sendable {
    case video(String)
    case loopingVideo(String)
    /// No related file is a video, for example only the adjustment data of an edit: the photo shows no Live control.
    case noVideo
    /// The listing names no related file yet, the type of a related file is not known, or the name of a video is not
    /// known while the photo has two or more videos.
    case unknown

    var linkID: String? {
        switch self {
        case .video(let linkID), .loopingVideo(let linkID): return linkID
        default: break
        }
        return nil
    }

    /// Unknown motion preserves the Live Photo classification. Loops also keep it for the Live Photos filter.
    var isLivePhoto: Bool { self != .noVideo }
    var isLooping: Bool {
        if case .loopingVideo = self { return true }
        return false
    }
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
    /// Playback evidence read with the types and names. Failed reads stay absent and retry on the next refresh.
    private(set) var playback: [String: Bool] = [:]

    /// The types, names and primary playback evidence read in one batch.
    struct Read: Equatable, Sendable {
        var types: [String: String] = [:]
        var names: [String: String] = [:]
        var playback: [String: Bool] = [:]
    }

    /// The answer of one metadata read: each read file with its type and, where the read decrypted it, its name.
    /// `namesRead` is false when the names could not be decrypted; the types still hold.
    /// `unreadPlayback` distinguishes missing or failed primary metadata from a known absent marker.
    struct Answer: Sendable {
        var files: [String: BurstFrameVerdicts.RelatedFile]
        var namesRead = true
        var playback: [String: Bool] = [:]
        var unreadPlayback: Set<String> = []
    }

    /// The answer for the `links` of one metadata read whose names `nameLinkIDs` asks for. Only a video can be the
    /// edited motion, and the read delivers each type together with the name, so only the requested names of videos
    /// decrypt. A failed root key read keeps the types, like the order pass of the same load: only the photos that
    /// need a name stay undecided until the next refresh.
    static func answer<Key>(
        links: [AlbumPhotoLinkBody], nameLinkIDs: Set<String>, rootKey: () async throws -> Key,
        decrypt: (_ armoredName: String, _ rootKey: Key) throws -> String,
        playbackPhotoIDs: Set<String> = [],
        decryptPlayback: ((_ link: AlbumPhotoLinkBody, _ rootKey: Key) throws -> Bool)? = nil
    ) async throws -> Answer {
        var key: Key?
        var keyFailure: (any Error)?
        func sharedRootKey() async throws -> Key {
            if let key { return key }
            if let keyFailure { throw keyFailure }
            do {
                let read = try await rootKey()
                key = read
                return read
            } catch {
                keyFailure = error
                throw error
            }
        }
        var answer: Answer
        do {
            let files = try await RelatedFileRead.files(
                in: links,
                decryptingNamesWhere: { link in
                    (link.linkID.map(nameLinkIDs.contains) ?? false) && isVideo(link.mimeType ?? "")
                }, rootKey: sharedRootKey, decrypt: decrypt)
            answer = Answer(files: files)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DebugLog.log("timeline: Live Photo video names unread, root key unavailable - \(error)")
            let files = try await RelatedFileRead.files(
                in: links, decryptingNamesWhere: { _ in false }, rootKey: rootKey, decrypt: decrypt)
            answer = Answer(files: files, namesRead: false)
        }
        let byID = Dictionary(
            links.compactMap { link in link.linkID.map { ($0, link) } },
            uniquingKeysWith: { first, _ in first })
        for id in playbackPhotoIDs.sorted() {
            try Task.checkCancellation()
            guard let link = byID[id], link.state == nil || link.state == 1 else {
                answer.unreadPlayback.insert(id)
                continue
            }
            guard playbackXAttr(of: link) != nil else {
                answer.playback[id] = false
                continue
            }
            guard let decryptPlayback else {
                answer.unreadPlayback.insert(id)
                continue
            }
            do {
                answer.playback[id] = try decryptPlayback(link, try await sharedRootKey())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                answer.unreadPlayback.insert(id)
                PhotoDiagnostics.shared.increment("timeline.liveMotion.playbackUnread")
            }
        }
        return answer
    }

    static func playbackXAttr(of link: AlbumPhotoLinkBody) -> String? {
        if let revision = link.fileProperties?.activeRevision { return revision.xAttr }
        return link.xAttr
    }

    private struct Playback: Decodable {
        let style: String?
        init(from decoder: any Decoder) throws {
            style = try PhotoUploadMetadataEncoder.IOSPhotos.readPlaybackStyle(from: decoder)
        }
    }

    static func isLoopingPlayback(in data: Data) throws -> Bool {
        let style = try JSONDecoder().decode(Playback.self, from: data).style
        return style == PhotoUploadMetadataEncoder.IOSPhotos.loopingPlaybackStyle
    }

    static func isLoopingPlayback(
        of link: AlbumPhotoLinkBody, parent: UnlockableKey, crypto: DriveCrypto
    ) throws -> Bool {
        guard let xattr = playbackXAttr(of: link), let key = link.nodeKey, let passphrase = link.nodePassphrase else {
            throw DriveCryptoError.keyRing
        }
        let node = try crypto.unlockNode(key: key, passphrase: passphrase, parent: parent)
        return try isLoopingPlayback(in: crypto.decryptXAttr(xattr, node: node))
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
    ) -> [String: LivePhotoMotion] {
        let related = livePhotos.filter { !$0.value.isEmpty }
        guard let store, !related.isEmpty else { return [:] }
        let uids = related.keys.sorted().map { PhotoUID(volumeID: volumeID, nodeID: $0) }
        return store.relatedVideos(for: uids, chosenBy: rule)
            .filter { related[$0.key]?.contains($0.value.id) == true }
            .mapValues { $0.loops ? .loopingVideo($0.id) : .video($0.id) }
    }

    /// A stored motion retains its playback without a request. Other photos use the session's types, names and primary
    /// playback evidence. One fetch combines unread related files with the primaries whose selected motion can be a
    /// render. Known ordinary motions and known single-video photos need no primary read. Unknown related types can
    /// still expose a render, so their primaries join the first batch. Only the primary's explicit marker makes a
    /// selected render loop. An unread primary keeps that render undecided and retries without rereading known names.
    func motions(
        of livePhotos: [String: [String]], stored: [String: LivePhotoMotion], evidence: [String: String],
        allowFetch: Bool = true,
        fetch: (_ linkIDs: [String], _ nameLinkIDs: Set<String>, _ playbackPhotoIDs: Set<String>) async throws -> Answer
    ) async throws -> (motions: [String: LivePhotoMotion], read: Read) {
        let typeOf = { (link: String) in evidence[link] ?? mimeTypes[link] }
        var seen = Set<String>()
        var nameLinkIDs = Set<String>()
        var playbackPhotoIDs = Set<String>()
        var unread = livePhotos.keys.sorted().flatMap { linkID -> [String] in
            guard let related = livePhotos[linkID], stored[linkID] == nil else { return [] }
            let possibleVideos = related.filter { typeOf($0).map(Self.isVideo) ?? true }
            let knownTypes = Dictionary(
                related.compactMap { id in typeOf(id).map { (id, $0) } },
                uniquingKeysWith: { first, _ in first })
            let motion = Self.motion(among: related, mimeTypes: knownTypes, names: names)
            let canLoop: Bool
            if let videoID = motion.linkID {
                canLoop = names[videoID].map(Self.isEditedMotion) ?? false
            } else {
                canLoop = motion == .unknown && possibleVideos.count > 1
            }
            if canLoop, playback[linkID] == nil { playbackPhotoIDs.insert(linkID) }
            let needsName = Set(possibleVideos.count > 1 ? possibleVideos.filter { names[$0] == nil } : [])
            nameLinkIDs.formUnion(needsName)
            return related.filter { (typeOf($0) == nil || needsName.contains($0)) && seen.insert($0).inserted }
        }
        let unreadTypes = unread.filter { typeOf($0) == nil }
        unread += playbackPhotoIDs.sorted().filter { seen.insert($0).inserted }
        var read = Read()
        if !unread.isEmpty, allowFetch {
            do {
                let answer = try await fetch(unread, nameLinkIDs, playbackPhotoIDs)
                for linkID in unreadTypes {
                    read.types[linkID] = answer.files[linkID]?.mimeType ?? ""
                }
                if answer.namesRead {
                    for linkID in nameLinkIDs { read.names[linkID] = answer.files[linkID]?.name ?? "" }
                }
                for linkID in playbackPhotoIDs where !answer.unreadPlayback.contains(linkID) {
                    read.playback[linkID] = answer.playback[linkID] ?? false
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.log("timeline: type or name of \(unread.count) Live Photo related files unread - \(error)")
            }
        }
        let types = evidence.merging(mimeTypes.merging(read.types) { _, read in read }) { evidence, _ in evidence }
        let names = names.merging(read.names) { _, read in read }
        let playback = playback.merging(read.playback) { _, read in read }
        let motions = livePhotos.reduce(into: [String: LivePhotoMotion]()) { motions, photo in
            if let stored = stored[photo.key] {
                motions[photo.key] = stored
                return
            }
            let motion = Self.motion(among: photo.value, mimeTypes: types, names: names)
            guard let videoID = motion.linkID, names[videoID].map(Self.isEditedMotion) == true else {
                motions[photo.key] = motion
                return
            }
            switch playback[photo.key] {
            case true: motions[photo.key] = .loopingVideo(videoID)
            case false: motions[photo.key] = motion
            case nil: motions[photo.key] = .unknown
            }
        }
        return (motions, read)
    }

    /// Keeps the `read` answer of `motions(of:stored:evidence:fetch:)` for this session.
    mutating func record(_ read: Read) {
        mimeTypes.merge(read.types) { _, read in read }
        names.merge(read.names) { _, read in read }
        playback.merge(read.playback) { _, read in read }
    }
}
