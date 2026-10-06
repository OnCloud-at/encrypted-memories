import Foundation

/// A merge of exact duplicates that moved photos to the trash and has not confirmed an active copy of its group yet.
/// The merge records it before its trash. When the merge fails or the process ends before its check, the next scan or
/// merge reads the group again and restores a copy when none stayed.
public struct ExactDuplicateMergeIntent: Sendable, Equatable, Codable {
    /// One photo that the trash of the merge takes, with the manifest rows that moved from it to the kept photo.
    public struct Member: Sendable, Equatable, Codable {
        public let link: String
        public let moves: [UploadRemoteLinkMove]
    }

    public let volumeID: String
    /// The link of the photo to keep.
    public let kept: String
    public let contentHash: String
    public let hashKeyEpoch: String
    public let members: [Member]

    /// One intent for each group: the kept photo and the content of the group.
    var key: String { kept + "|" + contentHash }
}

/// The merges that wait for the check of their kept photo.
public protocol ExactDuplicateMergeJournaling: Sendable {
    /// Nil when the journal cannot be read.
    func pendingMerges() -> [ExactDuplicateMergeIntent]?
    /// Records `intents` in place of earlier intents of the same groups. False when the write failed.
    func record(_ intents: [ExactDuplicateMergeIntent]) -> Bool
    /// Removes the intents of these groups. False when the write failed.
    func clear(_ intents: [ExactDuplicateMergeIntent]) -> Bool
}

/// The journal of the account in one small JSON file, `fileName`, next to the upload manifest. A sign-out removes it
/// with the account's other files. Each call reads the file again, so two stores of one file agree.
public final class ExactDuplicateMergeJournalFileStore: ExactDuplicateMergeJournaling {
    public static let fileName = "exact-duplicate-merge-intents-v1.json"

    /// Serializes the writes of every store in the process.
    private static let lock = NSLock()
    private let url: URL

    public init(accountDataDirectory: URL) {
        url = accountDataDirectory.appendingPathComponent(Self.fileName)
    }

    public func pendingMerges() -> [ExactDuplicateMergeIntent]? {
        Self.lock.withLock { read() }
    }

    public func record(_ intents: [ExactDuplicateMergeIntent]) -> Bool {
        let keys = Set(intents.map(\.key))
        return update { $0 = $0.filter { !keys.contains($0.key) } + intents }
    }

    public func clear(_ intents: [ExactDuplicateMergeIntent]) -> Bool {
        let keys = Set(intents.map(\.key))
        return update { $0.removeAll { keys.contains($0.key) } }
    }

    private func read() -> [ExactDuplicateMergeIntent]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ExactDuplicateMergeIntent].self, from: data)
    }

    private func update(_ change: (inout [ExactDuplicateMergeIntent]) -> Void) -> Bool {
        Self.lock.withLock {
            guard var intents = read() else { return false }
            let before = intents
            change(&intents)
            guard intents != before else { return true }
            guard !intents.isEmpty else {
                return (try? FileManager.default.removeItem(at: url)) != nil
                    || !FileManager.default.fileExists(atPath: url.path)
            }
            guard let data = try? JSONEncoder().encode(intents) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }
}
