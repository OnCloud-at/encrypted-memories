import Foundation

/// Names of the albums that hold the shared library ("shards"). Proton limits an album to 10,000 photos, so a large
/// library needs several albums. The name is visible in Proton's own apps and lets recipients recognize the albums,
/// so it is the same in every language.
public enum ShardNaming {
    public static let prefix = "Encrypted Memories · Shared Library"

    /// The name of the shard with the one-based `index`.
    public static func name(forIndex index: Int) -> String {
        "\(prefix) \(index)"
    }

    /// The one-based index when `name` is exactly a shard name, otherwise nil. Names compare in canonical Unicode
    /// form, so a name stored in another normalization still matches.
    public static func index(ofName name: String) -> Int? {
        let name = name.precomposedStringWithCanonicalMapping
        guard name.hasPrefix(prefix + " ") else { return nil }
        let digits = name.dropFirst(prefix.count + 1)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), digits.first != "0",
            let index = Int(digits), index >= 1
        else { return nil }
        return index
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
