import Foundation

public enum DeviceRootLocation: String, Codable, Hashable, Sendable {
    case computer
    case myFiles
}

/// Opaque SDK identifiers and a root-claim incarnation. No feature uses these to choose a location.
public struct DeviceRootIdentity: Hashable, Sendable {
    public let deviceUID: String
    public let rootFolderUID: String
    public let incarnation: String
    public let location: DeviceRootLocation

    public init(
        deviceUID: String, rootFolderUID: String, incarnation: String,
        location: DeviceRootLocation = .computer
    ) {
        self.deviceUID = deviceUID
        self.rootFolderUID = rootFolderUID
        self.incarnation = incarnation
        self.location = location
    }
}

/// Device identifiers returned before the app claim has been published.
public struct DeviceRootUnclaimedDevice: Hashable, Sendable {
    public let deviceUID: String
    public let rootFolderUID: String
    public let location: DeviceRootLocation

    public init(
        deviceUID: String, rootFolderUID: String,
        location: DeviceRootLocation = .computer
    ) {
        self.deviceUID = deviceUID
        self.rootFolderUID = rootFolderUID
        self.location = location
    }
}

/// A persisted creation attempt, including the known SDK result when one exists.
public struct DeviceRootCreateIntent: Equatable, Sendable {
    public let incarnation: String
    public let createdDevice: DeviceRootUnclaimedDevice?
    public let location: DeviceRootLocation

    public init(
        incarnation: String, createdDevice: DeviceRootUnclaimedDevice?,
        location: DeviceRootLocation = .computer
    ) {
        self.incarnation = incarnation
        self.createdDevice = createdDevice
        self.location = location
    }
}

/// The backend includes only roots whose claim it verified for the current account.
/// A failed name decryption, unreadable claim, or failed signature sets hasUnverifiedCandidate.
public struct DeviceRootCandidateInventory: Sendable {
    public let verifiedCandidates: [DeviceRootIdentity]
    public let unclaimedCandidates: [DeviceRootUnclaimedDevice]
    public let isComplete: Bool
    public let hasUnverifiedCandidate: Bool

    public init(
        verifiedCandidates: [DeviceRootIdentity],
        unclaimedCandidates: [DeviceRootUnclaimedDevice] = [],
        isComplete: Bool, hasUnverifiedCandidate: Bool
    ) {
        self.verifiedCandidates = verifiedCandidates
        self.unclaimedCandidates = unclaimedCandidates
        self.isComplete = isComplete
        self.hasUnverifiedCandidate = hasUnverifiedCandidate
    }
}

/// A failed or incomplete lookup never authorizes writes or automatic root creation.
public enum DeviceRootResolution: Equatable, Sendable {
    case enrollmentRequired
    case ready(DeviceRootIdentity)
    case ambiguous
    case unavailable
}

/// SDK and cryptographic work stays in the backend adapter.
public protocol DeviceRootEnrollmentBackend: Sendable {
    func inventory() async throws -> DeviceRootCandidateInventory
    func inventory(location: DeviceRootLocation) async throws -> DeviceRootCandidateInventory
    /// Scans both locations unless Computer enumeration itself fails.
    func inventoryForExplicitFallback() async throws -> DeviceRootCandidateInventory
    /// A journaled UID can be recovered after the user renames its unclaimed device.
    func inventoryIncludingKnown(
        _ device: DeviceRootUnclaimedDevice
    ) async throws
        -> DeviceRootCandidateInventory
    func createDevice() async throws -> DeviceRootUnclaimedDevice
    func createFallbackFolder() async throws -> DeviceRootUnclaimedDevice
    /// Checks for an existing identical claim before writing. An uncertain upload is never retried blindly.
    func ensureClaim(
        for device: DeviceRootUnclaimedDevice, incarnation: String
    ) async throws
        -> DeviceRootIdentity
}

/// An account-scoped durable journal. Each stage persists before its next remote side effect.
public protocol DeviceRootEnrollmentJournal: Sendable {
    func selectedRoot() async throws -> DeviceRootIdentity?
    func pendingCreate() async throws -> DeviceRootCreateIntent?
    func beginCreateIfAbsent(location: DeviceRootLocation, incarnation: String) async throws -> Bool
    func recordCreatedDevice(_ device: DeviceRootUnclaimedDevice) async throws
    func select(_ root: DeviceRootIdentity) async throws
    /// Atomically adopts a discovered root only while no local create intent exists.
    func selectIfNoPending(_ root: DeviceRootIdentity) async throws -> Bool
    func finishCreate() async throws
}

extension DeviceRootEnrollmentJournal {
    public func beginCreateIfAbsent(incarnation: String) async throws -> Bool {
        try await beginCreateIfAbsent(location: .computer, incarnation: incarnation)
    }
}

/// Explicit first-device enrollment. An unknown create outcome remains an unresolved intent.
public actor DeviceRootEnrollmentCoordinator {
    private let backend: any DeviceRootEnrollmentBackend
    private let journal: any DeviceRootEnrollmentJournal
    private let makeIncarnation: @Sendable () -> String
    private var operationInProgress = false

    public init(
        backend: any DeviceRootEnrollmentBackend, journal: any DeviceRootEnrollmentJournal,
        makeIncarnation: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.backend = backend
        self.journal = journal
        self.makeIncarnation = makeIncarnation
    }

    public func discover() async -> DeviceRootResolution {
        guard !operationInProgress else { return .ambiguous }
        operationInProgress = true
        defer { operationInProgress = false }
        return await resolve()
    }

    /// Explicitly discovers a fallback when Computer inventory is unavailable. This never creates a root.
    public func discoverFallback() async -> DeviceRootResolution {
        guard !operationInProgress else { return .ambiguous }
        operationInProgress = true
        defer { operationInProgress = false }
        return await resolve(preferredLocation: .myFiles)
    }

    /// This method must only be called after the account owner starts setup on one device.
    public func enroll() async -> DeviceRootResolution {
        await enroll(at: .computer)
    }

    /// An explicit first-root fallback when the Computer location is unavailable.
    public func enrollFallback() async -> DeviceRootResolution {
        await enroll(at: .myFiles)
    }

    private func enroll(at location: DeviceRootLocation) async -> DeviceRootResolution {
        guard !operationInProgress else { return .ambiguous }
        operationInProgress = true
        defer { operationInProgress = false }

        let current = await resolve(preferredLocation: location == .myFiles ? .myFiles : nil)
        guard current == .enrollmentRequired else { return current }
        guard !Task.isCancelled else { return .unavailable }

        let incarnation = makeIncarnation()
        do {
            guard try await journal.beginCreateIfAbsent(location: location, incarnation: incarnation)
            else { return .ambiguous }
        } catch {
            return .unavailable
        }

        // A cancelled task must not start a new remote mutation. The intent remains recoverable.
        guard !Task.isCancelled else { return .ambiguous }

        do {
            let device: DeviceRootUnclaimedDevice
            switch location {
            case .computer: device = try await backend.createDevice()
            case .myFiles: device = try await backend.createFallbackFolder()
            }
            try await journal.recordCreatedDevice(device)
            guard !Task.isCancelled else { return .ambiguous }
            let created = try await backend.ensureClaim(for: device, incarnation: incarnation)
            guard created.deviceUID == device.deviceUID,
                created.rootFolderUID == device.rootFolderUID,
                created.incarnation == incarnation,
                created.location == device.location
            else { return .ambiguous }
            guard !Task.isCancelled else { return .ambiguous }
            try await journal.select(created)
        } catch {
            // The request may have succeeded. The pending intent prevents a blind retry.
            return .ambiguous
        }
        return await resolve()
    }

    /// An explicit recovery action after a claim upload returned an unknown result.
    public func recoverCreatedRoot(_ root: DeviceRootIdentity) async -> DeviceRootResolution {
        guard !operationInProgress else { return .ambiguous }
        operationInProgress = true
        defer { operationInProgress = false }

        do {
            guard let intent = try await journal.pendingCreate() else { return await resolve() }
            guard try await journal.selectedRoot() == nil else { return await resolve() }
            guard intent.incarnation == root.incarnation else { return .ambiguous }
            guard intent.location == root.location else { return .ambiguous }
            if let device = intent.createdDevice {
                guard device.deviceUID == root.deviceUID,
                    device.rootFolderUID == root.rootFolderUID,
                    device.location == root.location
                else { return .ambiguous }
            }
            let inventory: DeviceRootCandidateInventory
            if intent.location == .myFiles {
                inventory = try await backend.inventoryForExplicitFallback()
            } else {
                inventory = try await backend.inventory()
            }
            guard !Task.isCancelled else { return .unavailable }
            guard inventory.isComplete else { return .unavailable }
            guard !inventory.hasUnverifiedCandidate, inventory.unclaimedCandidates.isEmpty,
                Set(inventory.verifiedCandidates) == [root]
            else { return .ambiguous }
            try await journal.select(root)
            try await journal.finishCreate()
            return .ready(root)
        } catch {
            return .unavailable
        }
    }

    /// The owner selects the sole unclaimed device after an unknown create response.
    public func recoverUnclaimedDevice(_ device: DeviceRootUnclaimedDevice) async -> DeviceRootResolution {
        guard !operationInProgress else { return .ambiguous }
        operationInProgress = true
        defer { operationInProgress = false }

        do {
            guard let intent = try await journal.pendingCreate() else { return await resolve() }
            guard try await journal.selectedRoot() == nil else { return await resolve() }
            guard intent.location == device.location else { return .ambiguous }
            if let known = intent.createdDevice, known != device { return .ambiguous }
            let inventory = try await backend.inventoryIncludingKnown(device)
            guard !Task.isCancelled else { return .unavailable }
            guard inventory.isComplete else { return .unavailable }
            guard !inventory.hasUnverifiedCandidate,
                inventory.verifiedCandidates.isEmpty,
                Set(inventory.unclaimedCandidates) == [device]
            else { return .ambiguous }
            if intent.createdDevice == nil { try await journal.recordCreatedDevice(device) }
            guard !Task.isCancelled else { return .ambiguous }
            let root = try await backend.ensureClaim(for: device, incarnation: intent.incarnation)
            guard root.deviceUID == device.deviceUID,
                root.rootFolderUID == device.rootFolderUID,
                root.incarnation == intent.incarnation,
                root.location == intent.location
            else { return .ambiguous }
            guard !Task.isCancelled else { return .ambiguous }
            try await journal.select(root)
            return await resolve()
        } catch {
            return .ambiguous
        }
    }

    private func resolve(preferredLocation: DeviceRootLocation? = nil) async -> DeviceRootResolution {
        do {
            guard !Task.isCancelled else { return .unavailable }
            let selected = try await journal.selectedRoot()
            let pending = try await journal.pendingCreate()
            guard !Task.isCancelled else { return .unavailable }
            guard pending == nil || selected != nil else { return .ambiguous }

            let inventory: DeviceRootCandidateInventory
            if selected?.location == .myFiles || pending?.location == .myFiles {
                inventory = try await backend.inventory(location: .myFiles)
            } else if preferredLocation == .myFiles {
                inventory = try await backend.inventoryForExplicitFallback()
            } else {
                inventory = try await backend.inventory()
            }
            guard !Task.isCancelled else { return .unavailable }
            guard inventory.isComplete else { return .unavailable }
            guard !inventory.hasUnverifiedCandidate else { return .ambiguous }
            guard inventory.unclaimedCandidates.isEmpty else { return .ambiguous }

            let candidates = Set(inventory.verifiedCandidates)
            guard candidates.count <= 1 else { return .ambiguous }
            if let selected {
                guard candidates.contains(selected) else {
                    return candidates.isEmpty ? .unavailable : .ambiguous
                }
                if pending != nil { try await journal.finishCreate() }
                return .ready(selected)
            }
            guard let only = candidates.first else { return .enrollmentRequired }
            guard try await journal.selectIfNoPending(only) else { return .ambiguous }
            return .ready(only)
        } catch {
            return .unavailable
        }
    }
}
