import CryptoKit
import DeviceRootCore
import Foundation

enum DeviceRootDigest {
    static func hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// The SDK-facing transport verifies node signatures and downloaded content before returning bytes.
struct DeviceRootSDKListedDevice: Sendable {
    let deviceUID: String
    let rootFolderUID: String
    /// Nil means that the SDK could not verify and decrypt the name.
    let name: String?
    let location: DeviceRootLocation

    init(
        deviceUID: String, rootFolderUID: String, name: String?,
        location: DeviceRootLocation = .computer
    ) {
        self.deviceUID = deviceUID
        self.rootFolderUID = rootFolderUID
        self.name = name
        self.location = location
    }
}

enum DeviceRootSDKClaimStatus: Sendable {
    case missing
    case verified(filename: String, bytes: Data)
    case unverified
}

protocol DeviceRootSDKTransport: Sendable {
    func devices() async throws -> [DeviceRootSDKListedDevice]
    func myFilesFolders() async throws -> [DeviceRootSDKListedDevice]
    func createDevice(name: String) async throws -> DeviceRootSDKListedDevice
    func createMyFilesFolder(name: String) async throws -> DeviceRootSDKListedDevice
    func claim(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKClaimStatus
    func uploadClaim(
        for device: DeviceRootSDKListedDevice, filename: String, bytes: Data,
        overrideExistingDraft: Bool
    ) async throws
}

/// Validates the app claim after SDK cryptographic verification. A matching name alone is never adopted.
struct SDKDeviceRootEnrollmentBackend: DeviceRootEnrollmentBackend {
    private struct Claim: Codable {
        let version: Int
        let deviceUID: String
        let rootFolderUID: String
        let incarnation: String
        let location: DeviceRootLocation
    }

    private static let deviceName = "Encrypted Memories"
    static let claimPrefix = "em-root-"
    static let maxClaimBytes = 4_096
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
        try await collect(
            knownUnclaimed: nil, location: nil, allowComputerEnumerationFailure: true)
    }

    func inventoryIncludingKnown(
        _ device: DeviceRootUnclaimedDevice
    ) async throws
        -> DeviceRootCandidateInventory
    {
        try await collect(
            knownUnclaimed: device,
            location: nil,
            allowComputerEnumerationFailure: device.location == .myFiles)
    }

    private func collect(
        knownUnclaimed: DeviceRootUnclaimedDevice?, location: DeviceRootLocation?,
        allowComputerEnumerationFailure: Bool = false
    ) async throws
        -> DeviceRootCandidateInventory
    {
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
        let devices = computers + fallbackFolders
        var verified: [DeviceRootIdentity] = []
        var unclaimed: [DeviceRootUnclaimedDevice] = []
        var hasUnverified = false

        for device in devices {
            guard let name = device.name else {
                hasUnverified = true
                continue
            }
            guard !device.deviceUID.isEmpty, !device.rootFolderUID.isEmpty else {
                hasUnverified = true
                continue
            }
            switch try await transport.claim(for: device) {
            case .missing:
                if name == Self.deviceName
                    || knownUnclaimed
                        == .init(
                            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
                            location: device.location)
                {
                    unclaimed.append(
                        .init(
                            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
                            location: device.location))
                }
            case .unverified:
                hasUnverified = true
            case .verified(let filename, let bytes):
                guard let root = Self.decodeClaim(filename: filename, bytes: bytes),
                    root.deviceUID == device.deviceUID,
                    root.rootFolderUID == device.rootFolderUID,
                    root.location == device.location
                else {
                    hasUnverified = true
                    continue
                }
                verified.append(root)
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
        guard !created.deviceUID.isEmpty, !created.rootFolderUID.isEmpty,
            created.location == .myFiles
        else { throw DeviceRootOperationError.verificationFailed }
        return .init(
            deviceUID: created.deviceUID, rootFolderUID: created.rootFolderUID,
            location: .myFiles)
    }

    func ensureClaim(
        for device: DeviceRootUnclaimedDevice, incarnation: String
    ) async throws -> DeviceRootIdentity {
        guard !device.deviceUID.isEmpty, !device.rootFolderUID.isEmpty,
            Self.validIncarnation(incarnation)
        else { throw DeviceRootOperationError.verificationFailed }

        let expected = DeviceRootIdentity(
            deviceUID: device.deviceUID,
            rootFolderUID: device.rootFolderUID,
            incarnation: incarnation, location: device.location)
        let bytes = try Self.encodeClaim(expected)
        let filename = Self.filename(for: bytes)
        let before = try await inventoryIncludingKnown(device)
        guard before.isComplete, !before.hasUnverifiedCandidate else {
            throw DeviceRootOperationError.ambiguousRoot
        }
        if before.verifiedCandidates == [expected], before.unclaimedCandidates.isEmpty {
            return expected
        }
        guard before.verifiedCandidates.isEmpty,
            before.unclaimedCandidates == [device]
        else { throw DeviceRootOperationError.ambiguousRoot }
        let matchingDevice = DeviceRootSDKListedDevice(
            deviceUID: device.deviceUID, rootFolderUID: device.rootFolderUID,
            name: Self.deviceName, location: device.location)

        try await transport.uploadClaim(
            for: matchingDevice, filename: filename, bytes: bytes,
            overrideExistingDraft: false)
        let after =
            try await
            (device.location == .myFiles
            ? inventoryForExplicitFallback() : inventory())
        guard after.isComplete, !after.hasUnverifiedCandidate,
            after.verifiedCandidates == [expected], after.unclaimedCandidates.isEmpty
        else { throw DeviceRootOperationError.unknownOutcome }
        return expected
    }

    private static func encodeClaim(_ root: DeviceRootIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(
            Claim(
                version: 1, deviceUID: root.deviceUID, rootFolderUID: root.rootFolderUID,
                incarnation: root.incarnation, location: root.location))
        guard bytes.count <= maxClaimBytes else { throw DeviceRootOperationError.verificationFailed }
        return bytes
    }

    private static func decodeClaim(filename: String, bytes: Data) -> DeviceRootIdentity? {
        guard bytes.count <= maxClaimBytes, filename == Self.filename(for: bytes),
            let claim = try? JSONDecoder().decode(Claim.self, from: bytes),
            claim.version == 1,
            !claim.deviceUID.isEmpty, !claim.rootFolderUID.isEmpty,
            validIncarnation(claim.incarnation)
        else { return nil }
        let root = DeviceRootIdentity(
            deviceUID: claim.deviceUID, rootFolderUID: claim.rootFolderUID,
            incarnation: claim.incarnation, location: claim.location)
        guard (try? encodeClaim(root)) == bytes else { return nil }
        return root
    }

    private static func filename(for bytes: Data) -> String {
        "\(claimPrefix)\(DeviceRootDigest.hex(bytes)).json"
    }

    private static func validIncarnation(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) })
    }
}
