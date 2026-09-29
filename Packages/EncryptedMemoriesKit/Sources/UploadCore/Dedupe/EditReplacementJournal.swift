import Foundation
import PhotosCore

/// The earlier uploads of one photo-library primary after the person edited the photo.
public struct EditReplacementJournalEntry: Sendable, Equatable, Codable {
    /// Photos this installation uploaded with earlier bytes. The backup moves them to the trash after the edited
    /// photo and its secondaries are uploaded.
    public var superseded: [PhotoUID]
    /// Links the backup already moved to the trash, with their related photos. A trashed copy among them is no
    /// deletion by the person.
    public var retired: [String]

    public init(superseded: [PhotoUID] = [], retired: [String] = []) {
        self.superseded = superseded
        self.retired = retired
    }

    public var isEmpty: Bool { superseded.isEmpty && retired.isEmpty }
}

/// Durable record of edited photos that replace their earlier upload. The dedupe pipeline adds the earlier
/// photo before its manifest record forgets it; the backup runner retires it after the trash write.
public protocol EditReplacementJournaling: Sendable {
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws
    /// Removes the photos from `superseded`. With `trashed` true they and `related` join `retired`.
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws
}

/// One JSON file in the account data directory, so the sign-out purge removes it with the other stores.
public final class EditReplacementJournalFileStore: EditReplacementJournaling, @unchecked Sendable {
    public static let fileName = "edit-replacement-journal-v1.json"
    /// Retired links only filter duplicate rows; the oldest ones leave the list after this many.
    static let retiredLimit = 64

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: EditReplacementJournalEntry]

    public init(accountDataDirectory: URL) {
        url = accountDataDirectory.appendingPathComponent(Self.fileName)
        entries =
            (try? JSONDecoder().decode([String: EditReplacementJournalEntry].self, from: Data(contentsOf: url)))
            ?? [:]
    }

    public func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry {
        lock.withLock { entries[Self.key(source)] ?? EditReplacementJournalEntry() }
    }

    public func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            guard !entry.superseded.contains(where: { $0.nodeID == uid.nodeID }) else { return }
            entry.superseded.append(uid)
        }
    }

    public func settle(
        _ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity
    ) throws {
        try update(source) { entry in
            entry.superseded.removeAll { nodeIDs.contains($0.nodeID) }
            guard trashed else { return }
            for linkID in nodeIDs.union(related).sorted() where !entry.retired.contains(linkID) {
                entry.retired.append(linkID)
            }
            entry.retired = Array(entry.retired.suffix(Self.retiredLimit))
        }
    }

    private func update(_ source: UploadSourceIdentity, _ change: (inout EditReplacementJournalEntry) -> Void) throws {
        try lock.withLock {
            let key = Self.key(source)
            var next = entries
            var entry = next[key] ?? EditReplacementJournalEntry()
            change(&entry)
            next[key] = entry.isEmpty ? nil : entry
            guard next != entries else { return }
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            entries = next
        }
    }

    private static func key(_ source: UploadSourceIdentity) -> String {
        "\(source.kind.rawValue)|\(source.identifier)|\(source.resource.rawValue)"
    }
}
