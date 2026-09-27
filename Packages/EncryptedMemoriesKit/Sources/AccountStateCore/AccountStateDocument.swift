import Foundation
import PhotosCore

/// When, on which device, and in which change a value was set. Of two changes to the same thing, the later stamp wins.
/// Equal times fall back to the device and then to a random number drawn for every change, so two different
/// changes never have the same stamp and every device reaches the same result in any merge order.
public struct AccountStateStamp: Sendable, Hashable, Comparable {
    /// Milliseconds since 1970. A whole number, so every device reads it back exactly.
    public let time: Int64
    public let deviceID: String
    public let nonce: UInt64

    public init(time: Int64, deviceID: String, nonce: UInt64) {
        self.time = time
        self.deviceID = deviceID
        self.nonce = nonce
    }

    public static func < (lhs: AccountStateStamp, rhs: AccountStateStamp) -> Bool {
        (lhs.time, lhs.deviceID, lhs.nonce) < (rhs.time, rhs.deviceID, rhs.nonce)
    }
}

/// The latest value of one thing, and when it was set.
public struct AccountStateRegister<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let stamp: AccountStateStamp
    /// Entry fields that a newer build added. They belong to this change and never carry over to a later one.
    public let extensions: [String: AccountStateJSONValue]

    public init(value: Value, stamp: AccountStateStamp, extensions: [String: AccountStateJSONValue] = [:]) {
        self.value = value
        self.stamp = stamp
        self.extensions = extensions
    }
}

/// A typed account setting stored under a stable name.
public struct AccountSettingKey<Value: Sendable & Equatable>: Sendable {
    public let name: String
    let encode: @Sendable (Value) -> AccountStateJSONValue
    let decode: @Sendable (AccountStateJSONValue) -> Value?

    public init(
        name: String,
        encode: @escaping @Sendable (Value) -> AccountStateJSONValue,
        decode: @escaping @Sendable (AccountStateJSONValue) -> Value?
    ) {
        self.name = name
        self.encode = encode
        self.decode = decode
    }
}

extension AccountSettingKey where Value == Bool {
    /// Whether the owner shares the library. A missing value, or a value that is not a Boolean, means off.
    public static let sharedLibraryEnabled = AccountSettingKey(
        name: "sharedLibrary.enabled", encode: { .bool($0) }, decode: { $0.boolValue })
}

/// A change the document cannot hold: a photo with an empty identifier, an empty setting name, a value nested too
/// deeply, text that normalization form C cannot hold, an empty or overlong device ID, a date that is not finite or
/// outside the stored range, or a clock that cannot advance any further.
public struct AccountStateInvalidChangeError: Error, Equatable {}

/// A document in a newer format. This build reads it but never changes or writes it.
public struct AccountStateReadOnlyError: Error, Equatable {
    public let format: Int
}

/// A document with a damaged field or entry. Damage cannot be ordered against other changes, so this build neither
/// changes, merges, nor writes the document; only an explicit repair continues.
public struct AccountStateDamagedError: Error, Equatable {}

/// Data that is not an account state document at all.
public struct AccountStateUnreadableError: Error, Equatable {}

/// The account state that all of the owner's devices agree on: the hidden photos and the account settings.
///
/// Every value is a register that the latest change wins, so two documents always merge to the same result in any
/// order, and merging again changes nothing. A photo that is shown again keeps its register, so an older copy
/// cannot hide it a second time.
///
/// Compatibility: a newer build may add top-level fields, fields inside an entry, and settings with new names. This
/// build keeps all of them. Any other change to the layout needs a new format number, which older builds only read.
/// Anything else this build cannot read is damage: the document is then unusable, sharing must pause, and only a
/// repair that the owner confirmed continues. Damage never shows a hidden photo.
public struct AccountStateDocument: Sendable, Equatable {
    public static let currentFormat = 1
    static let maximumDeviceIDBytes = 256

    public let format: Int
    public private(set) var hiddenRegisters: [PhotoUID: AccountStateRegister<Bool>]
    public private(set) var settingRegisters: [String: AccountStateRegister<AccountStateJSONValue>]
    /// Top-level fields that a newer build wrote, kept verbatim.
    public private(set) var extraFields: [String: AccountStateJSONValue]
    /// Hidden entries that this build could not read. A photo that such an entry names stays hidden.
    public private(set) var unreadableHiddenEntries: [AccountStateJSONValue]
    /// Settings that this build could not read, by name.
    public private(set) var unreadableSettings: [String: AccountStateJSONValue]
    /// The hidden or settings field when it has the wrong shape.
    public private(set) var damagedFields: [String: AccountStateJSONValue]

    public init() {
        self.init(format: Self.currentFormat)
    }

    private init(
        format: Int,
        hiddenRegisters: [PhotoUID: AccountStateRegister<Bool>] = [:],
        settingRegisters: [String: AccountStateRegister<AccountStateJSONValue>] = [:],
        extraFields: [String: AccountStateJSONValue] = [:],
        unreadableHiddenEntries: [AccountStateJSONValue] = [],
        unreadableSettings: [String: AccountStateJSONValue] = [:],
        damagedFields: [String: AccountStateJSONValue] = [:]
    ) {
        self.format = format
        self.hiddenRegisters = hiddenRegisters
        self.settingRegisters = settingRegisters
        self.extraFields = extraFields
        self.unreadableHiddenEntries = unreadableHiddenEntries
        self.unreadableSettings = unreadableSettings
        self.damagedFields = damagedFields
    }

    /// Whether this build understands the format. A newer document is read-only and counts as unknown state.
    public var isSupported: Bool { format <= Self.currentFormat }

    /// Whether the document has damage that this build cannot order against other changes.
    public var isDamaged: Bool {
        !unreadableHiddenEntries.isEmpty || !unreadableSettings.isEmpty || !damagedFields.isEmpty
    }

    /// Whether this build may rely on, change, merge, and write the document. Anything that shares photos must pause
    /// while it may not.
    public var isUsable: Bool { isSupported && !isDamaged }

    /// Photos hidden by a readable entry, and photos that a damaged entry names: damage never shows a photo.
    public var hiddenPhotos: Set<PhotoUID> {
        Set(hiddenRegisters.compactMap { $0.value.value ? $0.key : nil })
            .union(unreadableHiddenEntries.compactMap(Self.photo(named:)))
    }

    public func isHidden(_ photo: PhotoUID) -> Bool {
        hiddenRegisters[photo]?.value == true || unreadableHiddenEntries.contains { Self.photo(named: $0) == photo }
    }

    /// The setting, or nil when it is missing or has a value of another type.
    public func value<Value>(for key: AccountSettingKey<Value>) -> Value? {
        settingRegisters[key.name].flatMap { key.decode($0.value) }
    }

    /// Hides a photo, or shows it again. The change always supersedes what this document holds, also when the
    /// device clock is behind the device that made the previous change.
    public mutating func setHidden(
        _ photo: PhotoUID, _ isHidden: Bool, at date: Date, deviceID: String,
        nonce: UInt64 = .random(in: .min ... .max)
    ) throws {
        try requireUsable()
        guard !photo.volumeID.isEmpty, !photo.nodeID.isEmpty,
            AccountStateJSONValue.isNormalized(photo.volumeID), AccountStateJSONValue.isNormalized(photo.nodeID)
        else { throw AccountStateInvalidChangeError() }
        let stamp = try Self.stamp(after: hiddenRegisters[photo]?.stamp, at: date, deviceID: deviceID, nonce: nonce)
        hiddenRegisters[photo] = AccountStateRegister(value: isHidden, stamp: stamp)
    }

    public mutating func setValue<Value>(
        _ value: Value, for key: AccountSettingKey<Value>, at date: Date, deviceID: String,
        nonce: UInt64 = .random(in: .min ... .max)
    ) throws {
        try requireUsable()
        let original = key.encode(value)
        let encoded = original.normalizingStrings()
        // Swift compares text by canonical equivalence; a difference means normalization lost characters.
        guard encoded == original else { throw AccountStateInvalidChangeError() }
        // The document, the settings field, and the entry enclose the value.
        guard !key.name.isEmpty, AccountStateJSONValue.isNormalized(key.name), encoded.isWritable(insideLevels: 3)
        else {
            throw AccountStateInvalidChangeError()
        }
        let stamp = try Self.stamp(after: settingRegisters[key.name]?.stamp, at: date, deviceID: deviceID, nonce: nonce)
        settingRegisters[key.name] = AccountStateRegister(value: encoded, stamp: stamp)
    }

    /// Both documents combined. Nil when either document is not usable.
    public static func merged(_ lhs: AccountStateDocument, _ rhs: AccountStateDocument) -> AccountStateDocument? {
        guard lhs.isUsable, rhs.isUsable else { return nil }
        return AccountStateDocument(
            format: currentFormat,
            hiddenRegisters: lhs.hiddenRegisters.merging(rhs.hiddenRegisters, uniquingKeysWith: winner),
            settingRegisters: lhs.settingRegisters.merging(rhs.settingRegisters, uniquingKeysWith: winner),
            extraFields: lhs.extraFields.merging(rhs.extraFields) {
                AccountStateJSONValue.precedes($0, $1) ? $1 : $0
            }
        )
    }

    /// The document with only what this build could read. The hidden photos in damaged entries and fields are
    /// lost, so only a repair that the owner confirmed may use this. Nil for a newer format.
    public func discardingDamage() -> AccountStateDocument? {
        guard isSupported else { return nil }
        return AccountStateDocument(
            format: format, hiddenRegisters: hiddenRegisters, settingRegisters: settingRegisters,
            extraFields: extraFields)
    }

    /// The later register. Two registers with the same stamp and different content only come from damage or
    /// forgery; hiding then wins, so nothing is shared by mistake.
    static func winner(_ a: AccountStateRegister<Bool>, _ b: AccountStateRegister<Bool>) -> AccountStateRegister<Bool> {
        if a.stamp != b.stamp { return a.stamp > b.stamp ? a : b }
        if a.value != b.value { return a.value ? a : b }
        return extensionOrder(a, b)
    }

    /// The later register. Equal stamps with different content only come from damage or forgery; a value of true
    /// never wins then, so an equal-time "off" or unreadable value beats "on". Other values fall back to their
    /// canonical order.
    static func winner(
        _ a: AccountStateRegister<AccountStateJSONValue>, _ b: AccountStateRegister<AccountStateJSONValue>
    ) -> AccountStateRegister<AccountStateJSONValue> {
        if a.stamp != b.stamp { return a.stamp > b.stamp ? a : b }
        if a.value != b.value {
            if a.value == .bool(true) { return b }
            if b.value == .bool(true) { return a }
            return AccountStateJSONValue.precedes(a.value, b.value) ? b : a
        }
        return extensionOrder(a, b)
    }

    private static func extensionOrder<Value>(
        _ a: AccountStateRegister<Value>, _ b: AccountStateRegister<Value>
    ) -> AccountStateRegister<Value> {
        AccountStateJSONValue.precedes(.object(a.extensions), .object(b.extensions)) ? b : a
    }

    private func requireUsable() throws {
        guard isSupported else { throw AccountStateReadOnlyError(format: format) }
        guard !isDamaged else { throw AccountStateDamagedError() }
    }

    private static func stamp(
        after previous: AccountStateStamp?, at date: Date, deviceID: String, nonce: UInt64
    ) throws -> AccountStateStamp {
        let normalizedID = AccountStateJSONValue.normalized(deviceID)
        guard normalizedID == deviceID, isValidDeviceID(normalizedID), AccountStateJSONValue.isNormalized(normalizedID)
        else {
            throw AccountStateInvalidChangeError()
        }
        // Nearest, not down: a date made from whole milliseconds must read back as the same millisecond.
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        // Int64.max is not exactly representable as a Double; the strict bound keeps the conversion in range.
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else {
            throw AccountStateInvalidChangeError()
        }
        var time = Int64(milliseconds)
        if let previous, previous.time >= time {
            let (next, overflow) = previous.time.addingReportingOverflow(1)
            guard !overflow else { throw AccountStateInvalidChangeError() }
            time = next
        }
        return AccountStateStamp(time: time, deviceID: normalizedID, nonce: nonce)
    }

    static func isValidDeviceID(_ deviceID: String) -> Bool {
        !deviceID.isEmpty && deviceID.utf8.count <= maximumDeviceIDBytes
    }
}

// MARK: - Encoding

extension AccountStateDocument {
    private static let knownFields: Set<String> = ["format", "hidden", "settings"]
    private static let stampKeys: Set<String> = ["time", "device", "nonce"]
    private static let hiddenEntryKeys: Set<String> = stampKeys.union(["volumeID", "nodeID", "value"])
    private static let settingEntryKeys: Set<String> = stampKeys.union(["value"])

    /// Reads a document. Only data without a readable format number fails. A newer format is read-only, and
    /// anything else this build cannot read makes the document damaged.
    public init(data: Data) throws {
        guard case .object(let fields)? = AccountStateJSONValue(json: data),
            let format = fields["format"]?.integerValue(in: 1...Int.max)
        else { throw AccountStateUnreadableError() }
        let extra = fields.filter { !Self.knownFields.contains($0.key) }
        guard format <= Self.currentFormat else {
            // A newer format may change every layout; only its number is read.
            self.init(format: format, extraFields: extra)
            return
        }

        var damaged: [String: AccountStateJSONValue] = [:]
        var hidden: [PhotoUID: AccountStateRegister<Bool>] = [:]
        var unreadableHidden: [AccountStateJSONValue] = []
        switch fields["hidden"] {
        case nil:
            break
        case .array(let entries)?:
            for entry in entries {
                if let (photo, register) = Self.hiddenEntry(entry) {
                    hidden[photo] = hidden[photo].map { Self.winner($0, register) } ?? register
                } else {
                    unreadableHidden.append(entry)
                }
            }
        case let wrongShape?:
            damaged["hidden"] = wrongShape
        }

        var settings: [String: AccountStateRegister<AccountStateJSONValue>] = [:]
        var unreadableSettings: [String: AccountStateJSONValue] = [:]
        switch fields["settings"] {
        case nil:
            break
        case .object(let entries)?:
            for (name, entry) in entries {
                if !name.isEmpty, let register = Self.settingEntry(entry) {
                    settings[name] = register
                } else {
                    unreadableSettings[name] = entry
                }
            }
        case let wrongShape?:
            damaged["settings"] = wrongShape
        }

        self.init(
            format: format, hiddenRegisters: hidden, settingRegisters: settings, extraFields: extra,
            unreadableHiddenEntries: unreadableHidden, unreadableSettings: unreadableSettings, damagedFields: damaged)
    }

    /// The document as canonical JSON, so equal documents give equal bytes.
    public func encoded() throws -> Data {
        try requireUsable()
        let hiddenEntries: [AccountStateJSONValue] =
            hiddenRegisters.sorted { ($0.key.volumeID, $0.key.nodeID) < ($1.key.volumeID, $1.key.nodeID) }
            .map { photo, register in
                Self.entry(
                    register,
                    fields: [
                        "volumeID": .string(photo.volumeID), "nodeID": .string(photo.nodeID),
                        "value": .bool(register.value),
                    ])
            }
        var fields = extraFields
        fields["format"] = .integer(format)
        fields["hidden"] = .array(hiddenEntries)
        fields["settings"] = .object(settingRegisters.mapValues { Self.entry($0, fields: ["value": $0.value]) })
        return Data(AccountStateJSONValue.object(fields).canonicalBytes)
    }

    private static func entry<Value>(
        _ register: AccountStateRegister<Value>, fields: [String: AccountStateJSONValue]
    ) -> AccountStateJSONValue {
        var entry = register.extensions
        entry.merge(fields) { _, known in known }
        entry["time"] = .integer(register.stamp.time)
        entry["device"] = .string(register.stamp.deviceID)
        entry["nonce"] = .string(hex(register.stamp.nonce))
        return .object(entry)
    }

    private static func hex(_ nonce: UInt64) -> String {
        let digits = String(nonce, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    private static func stamp(_ raw: AccountStateJSONValue) -> AccountStateStamp? {
        guard let time = raw["time"]?.integerValue(in: 0...Int64.max),
            let device = raw["device"]?.stringValue, isValidDeviceID(device),
            let nonceText = raw["nonce"]?.stringValue, nonceText.utf8.count == 16,
            nonceText.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }),
            let nonce = UInt64(nonceText, radix: 16)
        else { return nil }
        return AccountStateStamp(time: time, deviceID: device, nonce: nonce)
    }

    private static func extensions(of raw: AccountStateJSONValue, known: Set<String>) -> [String: AccountStateJSONValue]
    {
        guard case .object(let fields) = raw else { return [:] }
        return fields.filter { !known.contains($0.key) }
    }

    static func photo(named raw: AccountStateJSONValue) -> PhotoUID? {
        guard let volume = raw["volumeID"]?.stringValue, let node = raw["nodeID"]?.stringValue,
            !volume.isEmpty, !node.isEmpty
        else { return nil }
        return PhotoUID(volumeID: volume, nodeID: node)
    }

    private static func hiddenEntry(_ raw: AccountStateJSONValue) -> (PhotoUID, AccountStateRegister<Bool>)? {
        guard let photo = photo(named: raw), let value = raw["value"]?.boolValue, let stamp = stamp(raw) else {
            return nil
        }
        let register = AccountStateRegister(
            value: value, stamp: stamp, extensions: extensions(of: raw, known: hiddenEntryKeys))
        return (photo, register)
    }

    private static func settingEntry(_ raw: AccountStateJSONValue) -> AccountStateRegister<AccountStateJSONValue>? {
        guard let value = raw["value"], let stamp = stamp(raw) else { return nil }
        return AccountStateRegister(
            value: value, stamp: stamp, extensions: extensions(of: raw, known: settingEntryKeys))
    }
}
