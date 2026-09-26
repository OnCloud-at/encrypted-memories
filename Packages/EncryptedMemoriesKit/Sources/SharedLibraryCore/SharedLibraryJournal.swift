import AlbumCore
import Foundation
import PhotosCore

/// One account-wide change to the shared library.
public enum SharedLibraryChange: Sendable, Equatable {
    /// The owner hid a photo, or showed it again.
    case hidden(PhotoUID, isHidden: Bool)
    /// The owner kept a photo for themselves ("Nur für mich"), or shared it again.
    case personal(PhotoUID, isPersonal: Bool)
    /// The owner changed the sharing choice.
    case settings(SharedLibrarySettings)
    /// A device created a shard album.
    case shardCreated(index: Int, album: AlbumNodeIdentifier)
    /// A shard album left the shared library.
    case shardRetired(album: AlbumNodeIdentifier)
    /// A change that this build does not know or cannot read. Kept verbatim and never applied.
    case unrecognized(SharedLibraryJSONValue)
}

extension SharedLibraryChange: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try SharedLibraryJSONValue(from: decoder)
        self = Self.parse(raw) ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        guard isWritable else {
            throw EncodingError.invalidValue(
                self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Not representable"))
        }
        try json.encode(to: encoder)
    }

    var json: SharedLibraryJSONValue {
        switch self {
        case .hidden(let photo, let value):
            .object(["type": .string("hidden"), "photo": Self.json(photo), "value": .bool(value)])
        case .personal(let photo, let value):
            .object(["type": .string("personal"), "photo": Self.json(photo), "value": .bool(value)])
        case .settings(let settings):
            .object(Self.settingsFields(settings))
        case .shardCreated(let index, let album):
            .object(["type": .string("shardCreated"), "index": .number(Decimal(index)), "album": Self.json(album)])
        case .shardRetired(let album):
            .object(["type": .string("shardRetired"), "album": Self.json(album)])
        case .unrecognized(let raw):
            raw
        }
    }

    private static func parse(_ raw: SharedLibraryJSONValue) -> SharedLibraryChange? {
        switch raw["type"]?.stringValue {
        case "hidden":
            guard let photo = photoUID(raw["photo"]), let value = raw["value"]?.boolValue else { return nil }
            return .hidden(photo, isHidden: value)
        case "personal":
            guard let photo = photoUID(raw["photo"]), let value = raw["value"]?.boolValue else { return nil }
            return .personal(photo, isPersonal: value)
        case "settings":
            guard let enabled = raw["enabled"]?.boolValue else { return nil }
            // Only a missing start date means everything. An unreadable one must never widen what is shared.
            switch raw["since"] {
            case nil:
                return .settings(SharedLibrarySettings(isEnabled: enabled, scope: .everything))
            case let since?:
                guard let seconds = since.numberValue else { return nil }
                return .settings(
                    SharedLibrarySettings(isEnabled: enabled, scope: .since(Date(timeIntervalSince1970: seconds))))
            }
        case "shardCreated":
            guard let index = raw["index"]?.integerValue(in: 1...Int.max), let album = albumIdentifier(raw["album"])
            else { return nil }
            return .shardCreated(index: index, album: album)
        case "shardRetired":
            guard let album = albumIdentifier(raw["album"]) else { return nil }
            return .shardRetired(album: album)
        default:
            return nil
        }
    }

    private static func settingsFields(_ settings: SharedLibrarySettings) -> [String: SharedLibraryJSONValue] {
        var fields: [String: SharedLibraryJSONValue] = [
            "type": .string("settings"), "enabled": .bool(settings.isEnabled),
        ]
        // `isWritable` guarantees a representable date before anything is written.
        if case .since(let date) = settings.scope, let seconds = Self.decimal(date.timeIntervalSince1970) {
            fields["since"] = .number(seconds)
        }
        return fields
    }

    /// The shortest decimal text that reads back as the same `Double`; nil when no such decimal exists (not finite,
    /// or beyond Decimal's range).
    private static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite, let decimal = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")),
            Double(decimal.description) == value
        else { return nil }
        return decimal
    }

    /// Whether the change can be written and read back unchanged.
    var isWritable: Bool {
        switch self {
        case .settings(let settings):
            if case .since(let date) = settings.scope { return Self.decimal(date.timeIntervalSince1970) != nil }
            return true
        case .shardCreated(let index, _): return index >= 1
        case .hidden, .personal, .shardRetired, .unrecognized: return true
        }
    }

    private static func json(_ photo: PhotoUID) -> SharedLibraryJSONValue {
        .object(["volumeID": .string(photo.volumeID), "nodeID": .string(photo.nodeID)])
    }

    private static func json(_ album: AlbumNodeIdentifier) -> SharedLibraryJSONValue {
        .object(["volumeID": .string(album.volumeID), "nodeID": .string(album.nodeID)])
    }

    private static func photoUID(_ raw: SharedLibraryJSONValue?) -> PhotoUID? {
        guard let volume = raw?["volumeID"]?.stringValue, let node = raw?["nodeID"]?.stringValue,
            !volume.isEmpty, !node.isEmpty
        else { return nil }
        return PhotoUID(volumeID: volume, nodeID: node)
    }

    private static func albumIdentifier(_ raw: SharedLibraryJSONValue?) -> AlbumNodeIdentifier? {
        photoUID(raw).map { AlbumNodeIdentifier(volumeID: $0.volumeID, nodeID: $0.nodeID) }
    }
}

/// One change that a device recorded, in the order that device made its changes.
public struct SharedLibraryJournalEntry: Sendable, Equatable, Codable {
    public let deviceID: String
    /// Increases with every change the device records.
    public let sequence: UInt64
    public let recordedAt: Date
    public let change: SharedLibraryChange

    public init(deviceID: String, sequence: UInt64, recordedAt: Date, change: SharedLibraryChange) {
        self.deviceID = deviceID
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.change = change
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device"
        case sequence = "seq"
        case recordedAt = "time"
        case change
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        recordedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .recordedAt))
        change = try container.decode(SharedLibraryChange.self, forKey: .change)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(recordedAt.timeIntervalSince1970, forKey: .recordedAt)
        try container.encode(change, forKey: .change)
    }

    /// Of two changes to the same thing, the later one wins. Equal times fall back to the device, its sequence, and
    /// finally the change itself, so every device reaches the same result in any reading order.
    func supersedes(_ other: SharedLibraryJournalEntry) -> Bool {
        if recordedAt != other.recordedAt { return recordedAt > other.recordedAt }
        if deviceID != other.deviceID { return deviceID > other.deviceID }
        if sequence != other.sequence { return sequence > other.sequence }
        return change.json.canonicalText > other.change.json.canonicalText
    }
}

/// A journal in a newer format; this build reads it but never changes or writes it.
public struct SharedLibraryJournalReadOnlyError: Error, Equatable {
    public let format: Int
}

/// A change that cannot be recorded: a date that is not finite, an invalid shard index, or a used-up sequence.
public struct SharedLibraryJournalInvalidChangeError: Error, Equatable {}

/// A journal whose sequence counter is damaged. Its entries still count, but the device must start a new journal,
/// because the next sequence cannot be known.
public struct SharedLibraryJournalDamagedError: Error, Equatable {}

/// The changes one device recorded. Each device writes only its own journal, so devices never overwrite each
/// other; every device reads all journals and merges them.
public struct SharedLibraryJournal: Sendable, Equatable {
    public static let currentFormat = 1

    public let format: Int
    public let deviceID: String
    public private(set) var entries: [SharedLibraryJournalEntry]
    /// Entries this build could not read, kept verbatim so a rewrite does not lose them. They never count.
    public private(set) var unreadableEntries: [SharedLibraryJSONValue]
    /// The highest sequence this device ever used; it only grows, also when compaction drops entries.
    public private(set) var lastSequence: UInt64
    /// False when the stored counter was present but unreadable; the journal is then read-only.
    public let hasTrustedSequence: Bool

    public init(deviceID: String, entries: [SharedLibraryJournalEntry] = []) {
        self.init(
            format: Self.currentFormat, deviceID: deviceID, entries: entries, unreadableEntries: [],
            lastSequence: entries.map(\.sequence).max() ?? 0, hasTrustedSequence: true)
    }

    private init(
        format: Int,
        deviceID: String,
        entries: [SharedLibraryJournalEntry],
        unreadableEntries: [SharedLibraryJSONValue],
        lastSequence: UInt64,
        hasTrustedSequence: Bool
    ) {
        self.format = format
        self.deviceID = deviceID
        self.entries = entries
        self.unreadableEntries = unreadableEntries
        self.lastSequence = max(lastSequence, entries.map(\.sequence).max() ?? 0)
        self.hasTrustedSequence = hasTrustedSequence
    }

    /// Whether this build can read the journal. A journal from a newer format is neither applied nor rewritten.
    public var isSupported: Bool { format <= Self.currentFormat }

    /// Whether this build may add changes and write the journal back.
    public var isAppendable: Bool { isSupported && hasTrustedSequence }

    private func requireAppendable() throws {
        guard isSupported else { throw SharedLibraryJournalReadOnlyError(format: format) }
        guard hasTrustedSequence else { throw SharedLibraryJournalDamagedError() }
    }

    /// Records `change` as this device's next change. A journal in a newer format stays unchanged.
    public mutating func record(_ change: SharedLibraryChange, at date: Date) throws {
        try requireAppendable()
        let (next, overflow) = lastSequence.addingReportingOverflow(1)
        guard !overflow, date.timeIntervalSince1970.isFinite, change.isWritable else {
            throw SharedLibraryJournalInvalidChangeError()
        }
        lastSequence = next
        entries.append(
            SharedLibraryJournalEntry(deviceID: deviceID, sequence: lastSequence, recordedAt: date, change: change))
    }

    /// The same journal with only the latest change for each thing, plus every unrecognized and unreadable entry.
    /// The merged state stays the same. A journal in a newer format stays unchanged.
    public func compacted() -> SharedLibraryJournal {
        guard isAppendable else { return self }
        var latest: [SharedLibraryMergeKey: SharedLibraryJournalEntry] = [:]
        var kept: [SharedLibraryJournalEntry] = []
        for entry in entries {
            guard let key = SharedLibraryMergeKey(entry.change) else {
                kept.append(entry)
                continue
            }
            if let current = latest[key], !entry.supersedes(current) { continue }
            latest[key] = entry
        }
        kept.append(contentsOf: latest.values)
        return SharedLibraryJournal(
            format: format, deviceID: deviceID, entries: kept.sorted { $0.sequence < $1.sequence },
            unreadableEntries: unreadableEntries, lastSequence: lastSequence, hasTrustedSequence: true)
    }

    /// Whether the journal holds many superseded changes, so a compacted copy is worth writing.
    public var needsCompaction: Bool {
        entries.count > 256 && entries.count > compacted().entries.count * 2
    }
}

extension SharedLibraryJournal: Codable {
    enum CodingKeys: String, CodingKey {
        case format
        case deviceID = "device"
        case entries
        case lastSequence = "last"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(Int.self, forKey: .format)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        guard format <= Self.currentFormat else {
            // A newer format may change the entry layout; its entries stay unread.
            self.init(
                format: format, deviceID: deviceID, entries: [], unreadableEntries: [], lastSequence: 0,
                hasTrustedSequence: false)
            return
        }
        // Each entry is read on its own, so one damaged entry does not hide the others.
        var entries: [SharedLibraryJournalEntry] = []
        var unreadable: [SharedLibraryJSONValue] = []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for raw in try container.decode([SharedLibraryJSONValue].self, forKey: .entries) {
            if let data = try? encoder.encode(raw),
                let entry = try? decoder.decode(SharedLibraryJournalEntry.self, from: data),
                entry.deviceID == deviceID
            {
                entries.append(entry)
            } else {
                unreadable.append(raw)
            }
        }
        // A sequence in an unreadable entry of this device still counts, so it is never used twice.
        let unreadableSequences = unreadable.compactMap { raw -> UInt64? in
            guard raw["device"]?.stringValue == deviceID else { return nil }
            return raw["seq"]?.integerValue(in: 0...UInt64.max)
        }
        // A counter that is present but unreadable cannot be rebuilt: compaction may have dropped the entry that held
        // the highest sequence. The journal stays readable but read-only.
        let recorded = try? container.decodeIfPresent(UInt64.self, forKey: .lastSequence)
        let counterIsReadable = recorded != nil || !container.contains(.lastSequence)
        let last = max(recorded ?? 0, unreadableSequences.max() ?? 0)
        self.init(
            format: format, deviceID: deviceID, entries: entries, unreadableEntries: unreadable, lastSequence: last,
            hasTrustedSequence: counterIsReadable)
    }

    public func encode(to encoder: Encoder) throws {
        try requireAppendable()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(deviceID, forKey: .deviceID)
        var raw: [SharedLibraryJSONValue] = []
        let entryEncoder = JSONEncoder()
        for entry in entries {
            raw.append(try JSONDecoder().decode(SharedLibraryJSONValue.self, from: entryEncoder.encode(entry)))
        }
        try container.encode(raw + unreadableEntries, forKey: .entries)
        try container.encode(lastSequence, forKey: .lastSequence)
    }
}

/// What a change is about. Two changes with the same key compete; the later one wins.
enum SharedLibraryMergeKey: Hashable {
    case hidden(PhotoUID)
    case personal(PhotoUID)
    case settings
    case shard(AlbumNodeIdentifier)

    init?(_ change: SharedLibraryChange) {
        switch change {
        case .hidden(let photo, _): self = .hidden(photo)
        case .personal(let photo, _): self = .personal(photo)
        case .settings: self = .settings
        case .shardCreated(_, let album), .shardRetired(let album): self = .shard(album)
        case .unrecognized: return nil
        }
    }
}
