/// SwiftUI identities for a display list of titles. Two albums can carry the same title, so a title alone is no
/// identity: each chip is identified by its title and by how many equal titles precede it. The rendering keeps every
/// title, including a repeated one.
public enum ViewerChipIdentity {
    public struct ID: Hashable, Sendable {
        public let title: String
        public let occurrence: Int
    }

    public struct Chip: Equatable, Sendable {
        public let title: String
        public let id: ID
    }

    public static func forTitles(_ titles: [String]) -> [Chip] {
        var occurrences: [String: Int] = [:]
        return titles.map { title in
            let occurrence = occurrences[title, default: 0]
            occurrences[title] = occurrence + 1
            return Chip(title: title, id: ID(title: title, occurrence: occurrence))
        }
    }
}
