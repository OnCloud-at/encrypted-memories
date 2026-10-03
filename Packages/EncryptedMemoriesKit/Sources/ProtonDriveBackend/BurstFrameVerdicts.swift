import Foundation

/// Which related files of a series can be frames. The bursts listing names every related file of a series photo,
/// also the adjustment data (.AAE) of an edit, which the series viewer must not show as a frame that cannot load.
/// The file type of a link does not change, so a verdict stays valid for the whole session.
struct BurstFrameVerdicts: Sendable {
    private var checked: Set<String> = []
    private var nonFrames: Set<String> = []

    /// The members without the related files that are known to be no frames. Only members that the bursts listing
    /// does not list are checked, each once, through `readMimeTypes`. A member stays when its type is unknown or the
    /// read fails: a frame of another Proton client can be missing from the bursts listing.
    static func frames(
        of memberIDs: [String],
        listed: Set<String>,
        verdicts: BurstFrameVerdicts,
        readMimeTypes: ([String]) async throws -> [String: String]
    ) async -> (frames: [String], verdicts: BurstFrameVerdicts) {
        var verdicts = verdicts
        let unchecked = memberIDs.filter { !listed.contains($0) && !verdicts.checked.contains($0) }
        if !unchecked.isEmpty {
            do {
                let mimeTypes = try await readMimeTypes(unchecked)
                verdicts.checked.formUnion(unchecked)
                verdicts.nonFrames.formUnion(
                    unchecked.filter { id in mimeTypes[id].map { !isFrame(mimeType: $0) } ?? false })
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

    /// An empty type is unknown, so it stays a frame.
    static func isFrame(mimeType: String) -> Bool {
        let mime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mime.isEmpty || mime.hasPrefix("image/") || mime.hasPrefix("video/")
    }
}
