import DeviceRootCore
import Foundation

struct DeviceRootSDKListedDevice: Sendable {
    let deviceUID: String
    let rootFolderUID: String
    let name: String?
    let location: DeviceRootLocation

    init(deviceUID: String, rootFolderUID: String, name: String?, location: DeviceRootLocation = .computer) {
        self.deviceUID = deviceUID
        self.rootFolderUID = rootFolderUID
        self.name = name
        self.location = location
    }
}

enum DeviceRootSDKMarkerStatus: Sendable {
    case missing
    case verified(name: String)
    case unverified
}

protocol DeviceRootSDKTransport: Sendable {
    func devices() async throws -> [DeviceRootSDKListedDevice]
    func myFilesFolders() async throws -> [DeviceRootSDKListedDevice]
    func createDevice(name: String) async throws -> DeviceRootSDKListedDevice
    func createMyFilesFolder(name: String) async throws -> DeviceRootSDKListedDevice
    func marker(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKMarkerStatus
    func createMarker(for device: DeviceRootSDKListedDevice, name: String) async throws
}

/// Accepts only an owner-signed marker in the exact SDK container being inventoried.
struct SDKDeviceRootEnrollmentBackend: DeviceRootEnrollmentBackend {
    private static let deviceName = "Encrypted Memories"
    private let transport: any DeviceRootSDKTransport

    init(transport: any DeviceRootSDKTransport) {
        self.transport = transport
    }

    func inventory() async throws -> DeviceRootCandidateInventory {
        try await collect(knownUnclaimed: nil, location: nil)
    }

    func inventory(location: DeviceRootLocation) async throws -> DeviceRootCandidateInventory {
        try await collect(knownUnclaimed: nil, location: location)
    }

    func inventoryForExplicitFallback() async throws -> DeviceRootCandidateInventory {
        try await collect(knownUnclaimed: nil, location: nil, allowComputerEnumerationFailure: true)
    }

    func inventoryIncludingKnown(_ device: DeviceRootUnclaimedDevice) async throws -> DeviceRootCandidateInventory {
        try await collect(
            knownUnclaimed: device, location: nil,
            allowComputerEnumerationFailure: device.location == .myFiles)
    }

    private func collect(
        knownUnclaimed: DeviceRootUnclaimedDevice?, location: DeviceRootLocation?,
        allowComputerEnumerationFailure: Bool = false
    ) async throws -> DeviceRootCandidateInventory {
        let computers: [DeviceRootSDKListedDevice]
        if location == .myFiles {
            computers = []
        } else if allowComputerEnumerationFailure {
            do {
                computers = try await transport.devices()
            } catch DeviceRootOperationError.unsupported {
                computers = []
            }
        } else {
            computers = try await transport.devices()
        }
        let fallbackFolders: [DeviceRootSDKListedDevice]
        if location == .computer {
            fallbackFolders = []
        } else {
            fallbackFolders = try await transport.myFilesFolders()
        }
        var verified: [DeviceRootIdentity] = []
        var unclaimed: [DeviceRootUnclaimedDevice] = []
        var hasUnverified = false

        for device in computers + fallbackFolders {
            guard let name = device.name, !device.deviceUID.isEmpty, !device.rootFolderUID.isEmpty else {
                hasUnverified = true
                continue
            }
            switch try await transport.marker(for: device) {
            case .missing:
                let candidate = DeviceRootUnclaimedDevice(
                    deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
                    location: device.location)
                if name == Self.deviceName || knownUnclaimed == candidate {
                    unclaimed.append(candidate)
                }
            case .unverified:
                hasUnverified = true
            case .verified(let markerName):
                guard let incarnation = DeviceRootMarker.incarnation(from: markerName, for: device) else {
                    hasUnverified = true
                    continue
                }
                verified.append(
                    .init(
                        deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
                        incarnation: incarnation, location: device.location))
            }
        }
        return DeviceRootCandidateInventory(
            verifiedCandidates: verified, unclaimedCandidates: unclaimed,
            isComplete: true, hasUnverifiedCandidate: hasUnverified)
    }

    func createDevice() async throws -> DeviceRootUnclaimedDevice {
        let created = try await transport.createDevice(name: Self.deviceName)
        guard !created.deviceUID.isEmpty, !created.rootFolderUID.isEmpty
        else { throw DeviceRootOperationError.verificationFailed }
        return .init(deviceUID: created.deviceUID, rootFolderUID: created.rootFolderUID)
    }

    func createFallbackFolder() async throws -> DeviceRootUnclaimedDevice {
        let created = try await transport.createMyFilesFolder(name: Self.deviceName)
        guard !created.deviceUID.isEmpty, !created.rootFolderUID.isEmpty, created.location == .myFiles
        else { throw DeviceRootOperationError.verificationFailed }
        return .init(deviceUID: created.deviceUID, rootFolderUID: created.rootFolderUID, location: .myFiles)
    }

    func ensureClaim(
        for device: DeviceRootUnclaimedDevice, incarnation: String
    ) async throws -> DeviceRootIdentity {
        let listed = DeviceRootSDKListedDevice(
            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
            name: Self.deviceName, location: device.location)
        guard let markerName = DeviceRootMarker.name(for: listed, incarnation: incarnation)
        else { throw DeviceRootOperationError.verificationFailed }
        let expected = DeviceRootIdentity(
            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
            incarnation: incarnation, location: device.location)
        let before = try await inventoryIncludingKnown(device)
        guard before.isComplete, !before.hasUnverifiedCandidate
        else { throw DeviceRootOperationError.ambiguousRoot }
        if before.verifiedCandidates == [expected], before.unclaimedCandidates.isEmpty {
            return expected
        }
        guard before.verifiedCandidates.isEmpty, before.unclaimedCandidates == [device]
        else { throw DeviceRootOperationError.ambiguousRoot }
        try Task.checkCancellation()
        try await transport.createMarker(for: listed, name: markerName)
        let after = try await (device.location == .myFiles ? inventoryForExplicitFallback() : inventory())
        guard after.isComplete, !after.hasUnverifiedCandidate,
            after.verifiedCandidates == [expected], after.unclaimedCandidates.isEmpty
        else { throw DeviceRootOperationError.unknownOutcome }
        return expected
    }
}
