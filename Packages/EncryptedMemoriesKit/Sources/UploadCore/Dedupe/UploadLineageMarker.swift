import Foundation

/// The encrypted metadata section of an upload that replaces earlier uploads of the same photo. Another device reads
/// it to tell a replacement by a backup apart from a deletion by the person. Other clients ignore unknown sections.
public struct UploadLineageMarker: Sendable, Equatable {
    public static let sectionName = "EncryptedMemories.lineage"
    /// The server accepts at most 65,535 characters for all encrypted sections together; 200 links use about 18 KB.
    public static let maximumReplacedLinks = 200

    public enum Reason: String, Sendable {
        case edit
        case undo
    }

    public let reason: Reason
    /// The replaced main photos, newest first.
    public let replaces: [String]

    /// Nil when nothing is replaced. Keeps the newest links when there are more than the limit.
    public init?(reason: Reason, replaces: [String]) {
        self.init(reason: reason, history: replaces.map { [$0] })
    }

    /// `history` holds groups of links, newest first. A group has no inner order, for example the uploads that a
    /// remote photo replaced. Above the limit, the marker keeps the newest whole groups and stops at the first group
    /// that does not fit, so no identifier order decides which links stay.
    public init?(reason: Reason, history: [[String]]) {
        var seen = Set<String>()
        var links: [String] = []
        for group in history {
            let fresh = group.filter { !$0.isEmpty && !seen.contains($0) }
            guard links.count + Set(fresh).count <= Self.maximumReplacedLinks else { break }
            for link in fresh where seen.insert(link).inserted { links.append(link) }
        }
        guard !links.isEmpty else { return nil }
        self.reason = reason
        self.replaces = links
    }

    public var additionalMetadata: PhotoUploadAdditionalMetadata {
        let object: [String: Any] = ["V": 1, "Reason": reason.rawValue, "Replaces": replaces]
        // A dictionary of strings, an integer, and a string array always serializes.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return PhotoUploadAdditionalMetadata(name: Self.sectionName, utf8JsonValue: data)
    }
}
