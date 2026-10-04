import Foundation
import UniformTypeIdentifiers

/// Which related files of a series can be frames. The bursts listing names every related file of a series photo,
/// also the adjustment data (.AAE) of an edit, which the series viewer must not show as a frame that cannot load.
/// The file type of a link does not change, so a verdict stays valid for the whole session.
struct BurstFrameVerdicts: Sendable {
    /// What the metadata of a related file tells about its type. `name` is nil when it does not decrypt.
    struct RelatedFile: Sendable, Equatable {
        var mimeType: String?
        var name: String?
    }

    private var checked: Set<String> = []
    private var nonFrames: Set<String> = []

    /// The members without the related files that are known to be no frames. Only members that the bursts listing
    /// does not list are checked, each once, through `readFiles`. A member stays when its type is unknown or the
    /// read fails: a frame of another Proton client can be missing from the bursts listing.
    static func frames(
        of memberIDs: [String],
        listed: Set<String>,
        verdicts: BurstFrameVerdicts,
        readFiles: ([String]) async throws -> [String: RelatedFile]
    ) async -> (frames: [String], verdicts: BurstFrameVerdicts) {
        var verdicts = verdicts
        let unchecked = memberIDs.filter { !listed.contains($0) && !verdicts.checked.contains($0) }
        if !unchecked.isEmpty {
            do {
                let files = try await readFiles(unchecked)
                verdicts.checked.formUnion(unchecked)
                verdicts.nonFrames.formUnion(unchecked.filter { id in files[id].map(isNonFrame(_:)) ?? false })
            } catch {
                DebugLog.log("burst: type of \(unchecked.count) related files unread; the viewer shows them - \(error)")
            }
        }
        return (memberIDs.filter { !verdicts.nonFrames.contains($0) }, verdicts)
    }

    /// Adds the verdicts of another series open, which can finish while this one waits for its read.
    mutating func merge(_ other: BurstFrameVerdicts) {
        checked.formUnion(other.checked)
        nonFrames.formUnion(other.nonFrames)
    }

    /// Name extensions of files that are certainly no frame, such as the adjustment data (.AAE) of an edit.
    static let nonFrameExtensions: Set<String> = ["aae", "plist", "xmp", "json", "xml"]

    /// The name decides first, because the backup uploads an .AAE as `application/octet-stream`. An image or video
    /// name keeps the file; without a name or with another extension, only a non-frame MIME type hides it.
    static func isNonFrame(_ file: RelatedFile) -> Bool {
        let fileExtension = file.name.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        if nonFrameExtensions.contains(fileExtension) { return true }
        if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension),
            type.conforms(to: .image) || type.conforms(to: .movie)
        {
            return false
        }
        return file.mimeType.map(isNonFrame(mimeType:)) ?? false
    }

    /// Types that name a file that is certainly no frame, such as the property list of an adjustment.
    static let nonFrameMimeTypes: Set<String> = [
        "application/xml", "text/xml", "application/x-plist", "application/json",
    ]

    /// Only a type that names no frame for certain hides a file. An empty or generic type, such as
    /// `application/octet-stream`, stays a frame: the backup uploads a frame with it when it cannot detect the type.
    static func isNonFrame(mimeType: String) -> Bool {
        let mime = (mimeType.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mime.hasPrefix("audio/") || nonFrameMimeTypes.contains(mime)
    }
}
