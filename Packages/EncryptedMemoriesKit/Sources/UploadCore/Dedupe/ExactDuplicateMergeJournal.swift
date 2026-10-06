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
    /// The device clock at the trash, in seconds since 1970. It dates the trash of the merge when the server no longer
    /// knows the trashed members, for example after the person emptied the trash. Nil in records without the time.
    public let trashedAt: Int64?

    /// One intent for each group: the kept photo and the content of the group.
    var key: String { kept + "|" + contentHash }
}

/// Whether a merge can record its trash.
public enum ExactDuplicateMergeJournalState: Sendable, Equatable {
    case ready
    /// The journal file could not be read. It moved aside under another name, and a new file starts.
    case replacedUnreadable
    /// The journal can be neither read nor written. A merge must not start its writes.
    case unavailable
}

/// The merges that wait for the check of their kept photo.
public protocol ExactDuplicateMergeJournaling: Sendable {
    /// Makes sure that the next `record` can succeed, before the merge writes anything else.
    func prepareForWrites() -> ExactDuplicateMergeJournalState
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

    /// Moves an unreadable file aside, so a damaged file never blocks every later merge. The moved file stays in the
    /// account folder for diagnostics.
    public func prepareForWrites() -> ExactDuplicateMergeJournalState {
        Self.lock.withLock {
            var state = ExactDuplicateMergeJournalState.ready
            if read() == nil {
                let aside = url.deletingLastPathComponent().appendingPathComponent(
                    "exact-duplicate-merge-intents-v1.unreadable-\(UUID().uuidString).json")
                guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return .unavailable }
                state = .replacedUnreadable
            }
            guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return .unavailable
            }
            return state
        }
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
