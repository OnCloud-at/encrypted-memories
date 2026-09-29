import Foundation
import PhotosCore

/// The earlier uploads of one photo-library primary after the person edited the photo.
public struct EditReplacementJournalEntry: Sendable, Equatable, Codable {
    /// Photos that held earlier bytes of this primary. The backup moves them to the trash after the edited photo and
    /// its secondaries are uploaded.
    public var superseded: [PhotoUID]
    /// Links the backup already moved to the trash, with their related photos. A trashed copy among them is no
    /// deletion by the person.
    public var retired: [String]
    /// True when the last upload of this photo was an edit. Only then do other bytes of the unedited photo undo an
    /// edit. Nil in journals of earlier builds.
    public var uploadedEdit: Bool?

    public init(superseded: [PhotoUID] = [], retired: [String] = [], uploadedEdit: Bool? = nil) {
        self.superseded = superseded
        self.retired = retired
        self.uploadedEdit = uploadedEdit
    }

    /// Without the flag, a photo that already replaced an earlier upload counts as edited: only edits and undos
    /// replaced photos in earlier builds.
    public var lastUploadWasEdit: Bool { uploadedEdit ?? !retired.isEmpty }

    public var isEmpty: Bool { superseded.isEmpty && retired.isEmpty && uploadedEdit != true }
}

/// Durable record of edited photos that replace their earlier upload. The dedupe pipeline adds the earlier
/// photo before its manifest record forgets it; the backup runner retires it after the trash write.
public protocol EditReplacementJournaling: Sendable {
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws
    /// Removes the photos from `superseded`. With `trashed` true they and `related` join `retired`.
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws
    /// Records whether the upload that the backup finished for `source` was an edit.
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws
}

/// One JSON file in the account data directory, so the sign-out purge removes it with the other stores. Retired
/// links stay without a limit: each edit adds only a few, and a dropped one could hide an undo.
public final class EditReplacementJournalFileStore: EditReplacementJournaling, @unchecked Sendable {
    public static let fileName = "edit-replacement-journal-v1.json"

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: EditReplacementJournalEntry]

    /// Nil when the file exists but cannot be read. Edits then keep their earlier uploads instead of losing the
    /// photos that still wait for their replacement.
    public init?(accountDataDirectory: URL) {
        url = accountDataDirectory.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            return
        }
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: EditReplacementJournalEntry].self, from: data)
        else { return nil }
        entries = decoded
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
        }
    }

    public func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            // An unedited photo without other entries needs no flag: nil counts as unedited then.
            entry.uploadedEdit = edited || !entry.retired.isEmpty ? edited : nil
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
