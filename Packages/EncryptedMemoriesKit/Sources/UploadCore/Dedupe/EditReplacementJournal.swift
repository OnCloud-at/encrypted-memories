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
    /// Related links by earlier main, recorded before its trash. Nil in journals of earlier builds.
    public var retireIntent: [String: [String]]?

    public init(
        superseded: [PhotoUID] = [], retired: [String] = [], uploadedEdit: Bool? = nil,
        retireIntent: [String: [String]]? = nil
    ) {
        self.superseded = superseded
        self.retired = retired
        self.uploadedEdit = uploadedEdit
        self.retireIntent = retireIntent
    }

    /// Without the flag, a photo that already replaced an earlier upload counts as edited: only edits and undos
    /// replaced photos in earlier builds.
    public var lastUploadWasEdit: Bool { uploadedEdit ?? !retired.isEmpty }

    public var isEmpty: Bool {
        superseded.isEmpty && retired.isEmpty && uploadedEdit != true && (retireIntent?.isEmpty ?? true)
    }
}

/// Durable record of edited photos that replace their earlier upload. The dedupe pipeline adds the earlier
/// photo before its manifest record forgets it; the backup runner retires it after the trash write.
public protocol EditReplacementJournaling: Sendable {
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry
    /// One in-memory snapshot for admission after a queue reset, without reading each queued source.
    func supersededSourceIdentifiers() -> Set<String>
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws
    /// Records related links before trashing their mains, without retiring active links.
    func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws
    /// Clears an earlier intent when a retry confirms that its main is still active.
    func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws
    /// Removes the photos from `superseded`. With `trashed` true they and `related` join `retired`.
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws
    /// Records whether the upload that the backup finished for `source` was an edit.
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws
    /// Removes photos from `retired`: the person restored them, so they are in the library again.
    func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws
}

extension EditReplacementJournaling {
    public func supersededSourceIdentifiers() -> Set<String> { [] }
}

/// A log of JSON lines in the account data directory, so the sign-out purge removes it with the other stores. Each
/// change appends the new entry of one source, so a change costs one short line, also with thousands of edited
/// photos. The log is rewritten from the entries when it holds many more lines than entries. Retired links stay
/// without a limit: each edit adds only a few, and a dropped one could hide an undo.
public final class EditReplacementJournalFileStore: EditReplacementJournaling, @unchecked Sendable {
    /// The single JSON file of earlier builds. A store without a log reads it once and continues in the log.
    public static let fileName = "edit-replacement-journal-v1.json"
    public static let logFileName = "edit-replacement-journal-v2.jsonl"

    private struct Line: Codable {
        let key: String
        /// Nil when the entry of `key` became empty.
        let entry: EditReplacementJournalEntry?
    }

    /// Written in place of the file of earlier builds. An earlier build cannot read it and keeps earlier uploads,
    /// instead of replacing photos without the history that only the log holds.
    static let earlierBuildBarrier = Data(#"{"movedTo":"edit-replacement-journal-v2.jsonl"}"#.utf8)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: WeakStore] = [:]

    private struct WeakStore {
        weak var store: EditReplacementJournalFileStore?
    }

    /// One store for each journal in the process. Two stores of one log would write over each other's lines.
    /// Nil when the journal exists but cannot be read.
    public static func shared(accountDataDirectory: URL) -> EditReplacementJournalFileStore? {
        let key = accountDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return registryLock.withLock {
            if let store = registry[key]?.store { return store }
            guard let store = EditReplacementJournalFileStore(accountDataDirectory: accountDataDirectory) else {
                return nil
            }
            registry[key] = WeakStore(store: store)
            SupportDiagnosticsSources.shared.registerEditReplacements(store, key: key)
            return store
        }
    }

    private let logURL: URL
    private let lock = NSLock()
    private var entries: [String: EditReplacementJournalEntry]
    private var lineCount: Int
    /// Set when a failed write could not be undone. The log then accepts no further line.
    private var writeFailed = false

    /// Nil when the journal exists but cannot be read. Edits then keep their earlier uploads instead of losing the
    /// photos that still wait for their replacement. The app opens it through `shared(accountDataDirectory:)`.
    init?(accountDataDirectory: URL) {
        let logURL = accountDataDirectory.appendingPathComponent(Self.logFileName)
        self.logURL = logURL
        let earlierURL = accountDataDirectory.appendingPathComponent(Self.fileName)
        defer { Self.placeBarrier(at: earlierURL, whenLogExists: logURL) }
        if FileManager.default.fileExists(atPath: logURL.path) {
            guard let data = try? Data(contentsOf: logURL), let replay = Self.replay(data) else { return nil }
            entries = replay.entries
            lineCount = replay.lines
            // A write that stopped halfway leaves a line without its end. The next line would join it.
            if replay.tornTail {
                guard (try? rewrite()) != nil else { return nil }
            }
        } else if FileManager.default.fileExists(atPath: earlierURL.path) {
            guard let data = try? Data(contentsOf: earlierURL),
                let decoded = try? JSONDecoder().decode([String: EditReplacementJournalEntry].self, from: data)
            else { return nil }
            entries = decoded
            lineCount = 0
            guard (try? rewrite()) != nil else { return nil }
        } else {
            entries = [:]
            lineCount = 0
        }
    }

    /// Keeps earlier builds away from the log's history once the log exists.
    private static func placeBarrier(at earlierURL: URL, whenLogExists logURL: URL) {
        guard FileManager.default.fileExists(atPath: logURL.path),
            (try? Data(contentsOf: earlierURL)) != earlierBuildBarrier
        else { return }
        try? earlierBuildBarrier.write(to: earlierURL, options: .atomic)
    }

    private static func replay(
        _ data: Data
    ) -> (entries: [String: EditReplacementJournalEntry], lines: Int, tornTail: Bool)? {
        var entries: [String: EditReplacementJournalEntry] = [:]
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let tornTail = !data.isEmpty && data.last != UInt8(ascii: "\n")
        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            guard let decoded = try? decoder.decode(Line.self, from: Data(line)) else {
                // Only the last line can be cut off by a stop during a write. Any other broken line is damage.
                guard tornTail, index == lines.count - 1 else { return nil }
                return (entries, index, true)
            }
            entries[decoded.key] = decoded.entry
        }
        return (entries, lines.count, tornTail)
    }

    public func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry {
        lock.withLock { entries[Self.key(source)] ?? EditReplacementJournalEntry() }
    }

    public func supersededSourceIdentifiers() -> Set<String> {
        let prefix = UploadSourceIdentity.Kind.photoLibraryAsset.rawValue + "|"
        let suffix = "|" + UploadSourceIdentity.Resource.primary.rawValue
        return lock.withLock {
            Set(
                entries.compactMap { key, entry in
                    guard !entry.superseded.isEmpty, key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
                    return String(key.dropFirst(prefix.count).dropLast(suffix.count))
                })
        }
    }

    public func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            guard !entry.superseded.contains(where: { $0.nodeID == uid.nodeID }) else { return }
            entry.superseded.append(uid)
        }
    }

    public func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            var intent = entry.retireIntent ?? [:]
            for (main, related) in relatedByMain { intent[main] = related.sorted() }
            entry.retireIntent = intent.isEmpty ? nil : intent
        }
    }

    public func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try update(source) { entry in
            for nodeID in nodeIDs { entry.retireIntent?[nodeID] = nil }
            if entry.retireIntent?.isEmpty == true { entry.retireIntent = nil }
        }
    }

    public func settle(
        _ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity
    ) throws {
        try update(source) { entry in
            entry.superseded.removeAll { nodeIDs.contains($0.nodeID) }
            var confirmedRelated = related
            for nodeID in nodeIDs {
                if trashed { confirmedRelated.formUnion(entry.retireIntent?[nodeID] ?? []) }
                entry.retireIntent?[nodeID] = nil
            }
            if entry.retireIntent?.isEmpty == true { entry.retireIntent = nil }
            guard trashed else { return }
            for linkID in nodeIDs.union(confirmedRelated).sorted() where !entry.retired.contains(linkID) {
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

    public func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {
        try update(source) { entry in entry.retired.removeAll(where: nodeIDs.contains) }
    }

    private func update(_ source: UploadSourceIdentity, _ change: (inout EditReplacementJournalEntry) -> Void) throws {
        try lock.withLock {
            let key = Self.key(source)
            var entry = entries[key] ?? EditReplacementJournalEntry()
            change(&entry)
            let next = entry.isEmpty ? nil : entry
            guard next != entries[key] else { return }
            try append(Line(key: key, entry: next))
            entries[key] = next
            lineCount += 1
            if lineCount > max(1_000, entries.count * 2) { try rewrite() }
        }
    }

    private func append(_ line: Line) throws {
        guard !writeFailed else { throw UploadError.backend("Edit replacement journal could not be written") }
        var data = try JSONEncoder().encode(line)
        data.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try data.write(to: logURL, options: .atomic)
            Self.placeBarrier(
                at: logURL.deletingLastPathComponent().appendingPathComponent(Self.fileName), whenLogExists: logURL)
            return
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A part of the line may be in the file, for example when the disk filled up. The next line would join
            // it, so the log goes back to its length before this write.
            do {
                try handle.truncate(atOffset: end)
            } catch {
                writeFailed = true
            }
            throw error
        }
    }

    /// Replaces the log with one line for each entry, in one atomic write.
    private func rewrite() throws {
        let encoder = JSONEncoder()
        var data = Data()
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
            data.append(try encoder.encode(Line(key: key, entry: entry)))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: logURL, options: .atomic)
        lineCount = entries.count
    }

    private static func key(_ source: UploadSourceIdentity) -> String {
        "\(source.kind.rawValue)|\(source.identifier)|\(source.resource.rawValue)"
    }
}

extension EditReplacementJournalFileStore: EditReplacementSupportSource {
    public func editReplacementSupportSnapshot() -> EditReplacementSupportSnapshot {
        lock.withLock {
            var result = EditReplacementSupportSnapshot()
            for entry in entries.values {
                if !entry.superseded.isEmpty { result.sourcesWithSupersededEntries += 1 }
                result.totalSuperseded += entry.superseded.count
                result.totalRetired += entry.retired.count
                if !(entry.retireIntent?.isEmpty ?? true) { result.rowsWithRetireIntent += 1 }
            }
            return result
        }
    }
}
