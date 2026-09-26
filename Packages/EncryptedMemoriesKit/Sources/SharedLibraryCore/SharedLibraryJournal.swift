import AlbumCore
import Foundation
import PhotosCore

/// One account-wide change to the shared library.
public enum SharedLibraryChange: Sendable, Equatable {
    /// The owner hid a photo, or showed it again.
    case hidden(PhotoUID, Bool)
    /// The owner kept a photo for themselves ("Nur für mich"), or shared it again.
    case personal(PhotoUID, Bool)
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
        try json.encode(to: encoder)
    }

    private var json: SharedLibraryJSONValue {
        switch self {
        case .hidden(let photo, let value):
            .object(["type": .string("hidden"), "photo": Self.json(photo), "value": .bool(value)])
        case .personal(let photo, let value):
            .object(["type": .string("personal"), "photo": Self.json(photo), "value": .bool(value)])
        case .settings(let settings):
            .object(Self.settingsFields(settings))
        case .shardCreated(let index, let album):
            .object(["type": .string("shardCreated"), "index": .number(Double(index)), "album": Self.json(album)])
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
            return .hidden(photo, value)
        case "personal":
            guard let photo = photoUID(raw["photo"]), let value = raw["value"]?.boolValue else { return nil }
            return .personal(photo, value)
        case "settings":
            guard let enabled = raw["enabled"]?.boolValue else { return nil }
            switch raw["since"] {
            case nil, .null?:
                return .settings(SharedLibrarySettings(isEnabled: enabled, scope: .everything))
            case let since?:
                guard let seconds = since.numberValue else { return nil }
                return .settings(
                    SharedLibrarySettings(isEnabled: enabled, scope: .since(Date(timeIntervalSince1970: seconds))))
            }
        case "shardCreated":
            guard let number = raw["index"]?.numberValue, number >= 1, number <= Double(Int.max),
                number == number.rounded(), let album = albumIdentifier(raw["album"])
            else { return nil }
            return .shardCreated(index: Int(number), album: album)
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
        if case .since(let date) = settings.scope { fields["since"] = .number(date.timeIntervalSince1970) }
        return fields
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

    /// Of two changes to the same thing, the later one wins. Equal times fall back to the device and its sequence, so
    /// every device reaches the same result.
    func supersedes(_ other: SharedLibraryJournalEntry) -> Bool {
        if recordedAt != other.recordedAt { return recordedAt > other.recordedAt }
        if deviceID != other.deviceID { return deviceID > other.deviceID }
        return sequence > other.sequence
    }
}

/// The changes one device recorded. Each device writes only its own journal, so devices never overwrite each
/// other; every device reads all journals and merges them.
public struct SharedLibraryJournal: Sendable, Equatable {
    public static let currentFormat = 1

    public let format: Int
    public let deviceID: String
    public private(set) var entries: [SharedLibraryJournalEntry]

    public init(deviceID: String, entries: [SharedLibraryJournalEntry] = []) {
        format = Self.currentFormat
        self.deviceID = deviceID
        self.entries = entries
    }

    /// Whether this build can read the journal. A journal from a newer format is neither applied nor rewritten.
    public var isSupported: Bool { format <= Self.currentFormat }

    /// Records `change` as this device's next change.
    public mutating func record(_ change: SharedLibraryChange, at date: Date) {
        precondition(isSupported, "A journal in a newer format is read-only")
        let next = (entries.map(\.sequence).max() ?? 0) + 1
        entries.append(SharedLibraryJournalEntry(deviceID: deviceID, sequence: next, recordedAt: date, change: change))
    }

    /// The same journal with only the latest change for each thing, plus every unrecognized change. The merged state
    /// stays the same.
    public func compacted() -> SharedLibraryJournal {
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
            format: format, deviceID: deviceID, entries: kept.sorted { $0.sequence < $1.sequence })
    }

    /// Whether the journal holds many superseded changes, so a compacted copy is worth writing.
    public var needsCompaction: Bool {
        entries.count > 256 && entries.count > compacted().entries.count * 2
    }

    private init(format: Int, deviceID: String, entries: [SharedLibraryJournalEntry]) {
        self.format = format
        self.deviceID = deviceID
        self.entries = entries
    }
}

extension SharedLibraryJournal: Codable {
    enum CodingKeys: String, CodingKey {
        case format
        case deviceID = "device"
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        // A newer format may change the entry layout; its entries stay unread.
        entries =
            format <= Self.currentFormat
            ? try container.decode([SharedLibraryJournalEntry].self, forKey: .entries) : []
    }

    public func encode(to encoder: Encoder) throws {
        precondition(isSupported, "A journal in a newer format is read-only")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(entries, forKey: .entries)
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
