import Foundation

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

    /// The types that choose the motion of Live Photos with these related files: `evidence`, the types read earlier in
    /// this session, and one `fetch` of the related files that neither holds. A Live Photo with one related file needs
    /// no read. `read` holds the answer for this session: a link without a type in the answer is no video. A failed
    /// read leaves `complete` false and its files unread, so the next refresh reads them again.
    func types(
        for related: some Sequence<[String]>, evidence: [String: String],
        fetch: (_ linkIDs: [String]) async throws -> [String: String]
    ) async throws -> (types: [String: String], read: [String: String], complete: Bool) {
        var seen = Set<String>()
        let unread = related.filter { $0.count > 1 }.joined().filter {
            evidence[$0] == nil && mimeTypes[$0] == nil && seen.insert($0).inserted
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
        let known = mimeTypes.merging(read) { _, read in read }
        return (evidence.merging(known) { evidence, _ in evidence }, read, complete)
    }

    /// Keeps the `read` answer of `types(for:evidence:fetch:)` for this session.
    mutating func record(_ read: [String: String]) {
        mimeTypes.merge(read) { _, read in read }
    }
}
