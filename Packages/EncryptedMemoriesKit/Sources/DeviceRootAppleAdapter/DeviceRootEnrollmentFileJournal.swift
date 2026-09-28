import Darwin
import DeviceRootCore
import Foundation

/// Account-scoped enrollment intent. Constructing this actor does not create a file.
public actor DeviceRootEnrollmentFileJournal: DeviceRootEnrollmentJournal {
    private static let processLock = NSLock()
    private struct Record: Codable {
        var version: Int
        var pendingIncarnation: String?
        var pendingLocation: DeviceRootLocation?
        var pendingDispatchAttempted: Bool?
        var createdDeviceUID: String?
        var createdRootFolderUID: String?
        var createdLocation: DeviceRootLocation?
        var selectedDeviceUID: String?
        var selectedRootFolderUID: String?
        var selectedIncarnation: String?
        var selectedLocation: DeviceRootLocation?

        var selectedRoot: DeviceRootIdentity? {
            guard let selectedDeviceUID, let selectedRootFolderUID, let selectedIncarnation else {
                return nil
            }
            return DeviceRootIdentity(
                deviceUID: selectedDeviceUID,
                rootFolderUID: selectedRootFolderUID,
                incarnation: selectedIncarnation,
                location: selectedLocation ?? .computer)
        }

        var pendingCreate: DeviceRootCreateIntent? {
            guard let pendingIncarnation else { return nil }
            let device: DeviceRootUnclaimedDevice?
            if let createdDeviceUID, let createdRootFolderUID {
                device = DeviceRootUnclaimedDevice(
                    deviceUID: createdDeviceUID, rootFolderUID: createdRootFolderUID,
                    location: createdLocation ?? .computer)
            } else {
                device = nil
            }
            return DeviceRootCreateIntent(
                incarnation: pendingIncarnation, createdDevice: device,
                location: pendingLocation ?? .computer,
                dispatchAttempted: pendingDispatchAttempted ?? true)
        }

        mutating func select(_ root: DeviceRootIdentity) {
            selectedDeviceUID = root.deviceUID
            selectedRootFolderUID = root.rootFolderUID
            selectedIncarnation = root.incarnation
            selectedLocation = root.location
        }
    }

    public enum JournalError: Error {
        case invalidRecord
        case conflictingRoot
        case noSelectedRoot
        case noPendingCreate
    }

    private let directory: URL
    private let fileURL: URL
    private let lockURL: URL
    private let onBeforeFileLock: (@Sendable () -> Void)?
    private let synchronize: @Sendable (Int32, Int32) throws -> Int32

    public init(accountDataDirectory: URL) {
        directory = accountDataDirectory
        fileURL = accountDataDirectory.appendingPathComponent("device-root-enrollment.json")
        lockURL = accountDataDirectory.appendingPathComponent("device-root-enrollment.lock")
        onBeforeFileLock = nil
        synchronize = Self.systemSync
    }

    init(
        accountDataDirectory: URL,
        onBeforeFileLock: (@Sendable () -> Void)?,
        synchronize: (@Sendable (Int32, Int32) throws -> Int32)?
    ) {
        directory = accountDataDirectory
        fileURL = accountDataDirectory.appendingPathComponent("device-root-enrollment.json")
        lockURL = accountDataDirectory.appendingPathComponent("device-root-enrollment.lock")
        self.onBeforeFileLock = onBeforeFileLock
        self.synchronize = synchronize ?? Self.systemSync
    }

    public func selectedRoot() throws -> DeviceRootIdentity? {
        try withExclusiveLock { try loadUnlocked().selectedRoot }
    }

    public func pendingCreate() throws -> DeviceRootCreateIntent? {
        try withExclusiveLock { try loadUnlocked().pendingCreate }
    }

    public func beginCreateIfAbsent(
        location: DeviceRootLocation, incarnation: String
    ) throws -> Bool {
        guard !incarnation.isEmpty else { throw JournalError.invalidRecord }
        return try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.pendingCreate == nil, record.selectedRoot == nil else { return false }
            record.pendingIncarnation = incarnation
            record.pendingLocation = location
            record.pendingDispatchAttempted = false
            try saveUnlocked(record)
            return true
        }
    }

    public func markCreateDispatchAttempted(
        location: DeviceRootLocation, incarnation: String
    ) throws -> Bool {
        try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.selectedRoot == nil, let intent = record.pendingCreate,
                intent.location == location, intent.incarnation == incarnation,
                !intent.dispatchAttempted, intent.createdDevice == nil
            else { return false }
            record.pendingDispatchAttempted = true
            try saveUnlocked(record)
            return true
        }
    }

    public func abortPreparedCreate(
        location: DeviceRootLocation, incarnation: String
    ) throws -> Bool {
        try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.selectedRoot == nil, let intent = record.pendingCreate,
                intent.location == location, intent.incarnation == incarnation,
                !intent.dispatchAttempted, intent.createdDevice == nil
            else { return false }
            record.pendingIncarnation = nil
            record.pendingLocation = nil
            record.pendingDispatchAttempted = nil
            try saveUnlocked(record)
            return true
        }
    }

    public func recordCreatedDevice(_ device: DeviceRootUnclaimedDevice) throws {
        guard !device.deviceUID.isEmpty, !device.rootFolderUID.isEmpty else {
            throw JournalError.invalidRecord
        }
        try withExclusiveLock {
            var record = try loadUnlocked()
            guard let intent = record.pendingCreate else { throw JournalError.noPendingCreate }
            guard intent.location == device.location else { throw JournalError.conflictingRoot }
            guard intent.dispatchAttempted else { throw JournalError.invalidRecord }
            if let existing = intent.createdDevice, existing != device { throw JournalError.conflictingRoot }
            record.createdDeviceUID = device.deviceUID
            record.createdRootFolderUID = device.rootFolderUID
            record.createdLocation = device.location
            try saveUnlocked(record)
        }
    }

    public func abortCreateBeforeRemoteCall(
        location: DeviceRootLocation, incarnation: String
    ) throws -> Bool {
        try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.selectedRoot == nil, let intent = record.pendingCreate,
                intent.location == location, intent.incarnation == incarnation,
                intent.createdDevice == nil
            else { return false }
            record.pendingIncarnation = nil
            record.pendingLocation = nil
            record.pendingDispatchAttempted = nil
            try saveUnlocked(record)
            return true
        }
    }

    public func select(_ root: DeviceRootIdentity) throws {
        guard !root.deviceUID.isEmpty, !root.rootFolderUID.isEmpty, !root.incarnation.isEmpty else {
            throw JournalError.invalidRecord
        }
        try withExclusiveLock {
            var record = try loadUnlocked()
            if let existing = record.selectedRoot, existing != root { throw JournalError.conflictingRoot }
            if let intent = record.pendingCreate {
                guard intent.incarnation == root.incarnation,
                    intent.location == root.location
                else { throw JournalError.conflictingRoot }
                if let device = intent.createdDevice {
                    guard device.deviceUID == root.deviceUID,
                        device.rootFolderUID == root.rootFolderUID
                    else { throw JournalError.conflictingRoot }
                }
            }
            record.select(root)
            try saveUnlocked(record)
        }
    }

    public func selectIfNoPending(_ root: DeviceRootIdentity) throws -> Bool {
        guard !root.deviceUID.isEmpty, !root.rootFolderUID.isEmpty, !root.incarnation.isEmpty else {
            throw JournalError.invalidRecord
        }
        return try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.pendingCreate == nil else { return false }
            if let existing = record.selectedRoot { return existing == root }
            record.select(root)
            try saveUnlocked(record)
            return true
        }
    }

    public func finishCreate() throws {
        try withExclusiveLock {
            var record = try loadUnlocked()
            guard record.selectedRoot != nil else { throw JournalError.noSelectedRoot }
            guard record.pendingCreate != nil else { return }
            record.pendingIncarnation = nil
            record.pendingLocation = nil
            record.pendingDispatchAttempted = nil
            record.createdDeviceUID = nil
            record.createdRootFolderUID = nil
            record.createdLocation = nil
            try saveUnlocked(record)
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        onBeforeFileLock?()
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else { throw posixError() }
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func loadUnlocked() throws -> Record {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return Record(
                    version: 4, pendingIncarnation: nil, pendingLocation: nil,
                    pendingDispatchAttempted: nil,
                    createdDeviceUID: nil, createdRootFolderUID: nil, createdLocation: nil,
                    selectedDeviceUID: nil, selectedRootFolderUID: nil,
                    selectedIncarnation: nil, selectedLocation: nil)
            }
            throw error
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        let selectedFields = [
            record.selectedDeviceUID, record.selectedRootFolderUID, record.selectedIncarnation,
        ]
        let createdFields = [record.createdDeviceUID, record.createdRootFolderUID]
        guard record.version == 2 || record.version == 3 || record.version == 4,
            record.version != 2
                || (record.pendingLocation == nil && record.createdLocation == nil
                    && record.selectedLocation == nil),
            selectedFields.allSatisfy({ $0 == nil }) || selectedFields.allSatisfy({ $0?.isEmpty == false }),
            createdFields.allSatisfy({ $0 == nil }) || createdFields.allSatisfy({ $0?.isEmpty == false }),
            record.pendingIncarnation == nil || record.pendingIncarnation?.isEmpty == false,
            record.pendingIncarnation != nil || createdFields.allSatisfy({ $0 == nil }),
            record.version == 2 || record.pendingLocation != nil || record.pendingIncarnation == nil,
            record.version == 2 || record.createdLocation != nil || createdFields.allSatisfy({ $0 == nil }),
            record.version == 2 || record.selectedLocation != nil || selectedFields.allSatisfy({ $0 == nil }),
            record.pendingIncarnation != nil || record.pendingLocation == nil,
            record.pendingIncarnation != nil || record.pendingDispatchAttempted == nil,
            record.version < 4 || record.pendingIncarnation == nil
                || record.pendingDispatchAttempted != nil,
            record.createdDeviceUID == nil || record.pendingCreate?.dispatchAttempted == true,
            record.selectedRoot != nil || record.selectedLocation == nil,
            record.pendingCreate?.createdDevice != nil || record.createdLocation == nil
        else { throw JournalError.invalidRecord }
        if let intent = record.pendingCreate, let selected = record.selectedRoot {
            guard intent.incarnation == selected.incarnation,
                intent.location == selected.location
            else { throw JournalError.invalidRecord }
            if let device = intent.createdDevice {
                guard device.deviceUID == selected.deviceUID,
                    device.rootFolderUID == selected.rootFolderUID
                else { throw JournalError.invalidRecord }
            }
        }
        if record.version < 4 { try saveUnlocked(record) }
        return record
    }

    private func saveUnlocked(_ record: Record) throws {
        var upgraded = record
        upgraded.version = 4
        if upgraded.pendingIncarnation != nil, upgraded.pendingDispatchAttempted == nil {
            // Older journals cannot prove whether remote create was sent.
            upgraded.pendingDispatchAttempted = true
        }
        if upgraded.pendingIncarnation != nil, upgraded.pendingLocation == nil {
            upgraded.pendingLocation = .computer
        }
        if upgraded.createdDeviceUID != nil, upgraded.createdLocation == nil {
            upgraded.createdLocation = .computer
        }
        if upgraded.selectedDeviceUID != nil, upgraded.selectedLocation == nil {
            upgraded.selectedLocation = .computer
        }
        try JSONEncoder().encode(upgraded).write(to: fileURL, options: .atomic)
        // The dispatch reservation must survive power loss before a remote create starts.
        try fullSync(fileURL, flags: O_RDONLY | O_NOFOLLOW)
        try fullSync(directory, flags: O_RDONLY | O_DIRECTORY)
    }

    static func systemSync(_ descriptor: Int32, command: Int32) -> Int32 {
        Darwin.fcntl(descriptor, command)
    }

    private func fullSync(_ url: URL, flags: Int32) throws {
        let descriptor = Darwin.open(url.path, flags | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard try synchronize(descriptor, F_FULLFSYNC) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
