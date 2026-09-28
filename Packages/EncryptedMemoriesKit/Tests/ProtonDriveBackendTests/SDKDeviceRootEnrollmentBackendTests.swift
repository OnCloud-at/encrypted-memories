import DeviceRootCore
import Foundation
import Testing

@testable import ProtonDriveBackend

private let listedDevice = DeviceRootSDKListedDevice(
    deviceUID: "volume~device", rootFolderUID: "volume~folder", name: "Encrypted Memories")
private let listedFallback = DeviceRootSDKListedDevice(
    deviceUID: "volume~my-files", rootFolderUID: "volume~fallback", name: "Encrypted Memories",
    location: .myFiles)

private actor RootTransport: DeviceRootSDKTransport {
    var listed: [DeviceRootSDKListedDevice] = []
    var fallbackFolders: [DeviceRootSDKListedDevice] = []
    var computerUnavailable = false
    var partialComputerFailure = false
    var myFilesFailuresRemaining = 0
    var computerClaimUnavailable = false
    var claims: [String: DeviceRootSDKClaimStatus] = [:]
    var createCount = 0
    var uploadCount = 0
    var loseUploadResponse = false
    var foreignDraft = false
    var draftOverridden = false

    func devices() async throws -> [DeviceRootSDKListedDevice] {
        if computerUnavailable { throw DeviceRootOperationError.unsupported }
        if partialComputerFailure { throw DeviceRootOperationError.verificationFailed }
        return listed
    }
    func myFilesFolders() async throws -> [DeviceRootSDKListedDevice] {
        if myFilesFailuresRemaining > 0 {
            myFilesFailuresRemaining -= 1
            throw DeviceRootOperationError.unavailable
        }
        return fallbackFolders
    }

    func createDevice(name: String) async throws -> DeviceRootSDKListedDevice {
        #expect(name == "Encrypted Memories")
        createCount += 1
        listed.append(listedDevice)
        return listedDevice
    }

    func createMyFilesFolder(name: String) async throws -> DeviceRootSDKListedDevice {
        #expect(name == "Encrypted Memories")
        fallbackFolders.append(listedFallback)
        return listedFallback
    }

    func claim(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKClaimStatus {
        if computerClaimUnavailable, device.location == .computer {
            throw DeviceRootOperationError.unavailable
        }
        return claims[device.rootFolderUID] ?? .missing
    }

    func uploadClaim(
        for device: DeviceRootSDKListedDevice, filename: String, bytes: Data,
        overrideExistingDraft: Bool
    ) async throws {
        uploadCount += 1
        if foreignDraft {
            guard overrideExistingDraft else { throw DraftCollision() }
            draftOverridden = true
        }
        claims[device.rootFolderUID] = .verified(filename: filename, bytes: bytes)
        if loseUploadResponse { throw CancellationError() }
    }

    func add(_ device: DeviceRootSDKListedDevice) { listed.append(device) }
    func rename(_ device: DeviceRootSDKListedDevice, to name: String) {
        listed = listed.map {
            $0.deviceUID == device.deviceUID
                ? .init(deviceUID: $0.deviceUID, rootFolderUID: $0.rootFolderUID, name: name)
                : $0
        }
    }
    func setClaim(_ status: DeviceRootSDKClaimStatus, for device: DeviceRootSDKListedDevice) {
        claims[device.rootFolderUID] = status
    }
    func loseNextUploadResponse() { loseUploadResponse = true }
    func setForeignDraft() { foreignDraft = true }
    func setComputerUnavailable() { computerUnavailable = true }
    func setPartialComputerFailure() { partialComputerFailure = true }
    func failNextMyFilesListing() { myFilesFailuresRemaining = 1 }
    func setComputerClaimUnavailable() { computerClaimUnavailable = true }
    func wasDraftOverridden() -> Bool { draftOverridden }
    func counts() -> (Int, Int) { (createCount, uploadCount) }
}

private struct DraftCollision: Error {}

@Suite("SDK device root enrollment")
struct SDKDeviceRootEnrollmentBackendTests {
    @Test func listingDoesNotCreateARoot() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        let inventory = try await backend.inventory()
        #expect(inventory.isComplete)
        #expect(inventory.verifiedCandidates.isEmpty)
        #expect(inventory.unclaimedCandidates.isEmpty)
        #expect((await transport.counts()).0 == 0)
    }

    @Test func myFilesFallbackUsesItsOwnClaimAndLocation() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        let folder = try await backend.createFallbackFolder()
        #expect(folder.location == .myFiles)
        let claimed = try await backend.ensureClaim(for: folder, incarnation: "fallback")
        #expect(claimed.location == .myFiles)
        #expect(claimed.rootFolderUID == listedFallback.rootFolderUID)
        #expect(try await backend.inventory().verifiedCandidates == [claimed])
    }

    @Test func existingFallbackRemainsVerifiableWhenComputerEndpointDisappears() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let folder = try await backend.createFallbackFolder()
        let claimed = try await backend.ensureClaim(for: folder, incarnation: "fallback")
        await transport.setComputerUnavailable()

        let inventory = try await backend.inventory(location: .myFiles)
        #expect(inventory.verifiedCandidates == [claimed])
    }

    @Test func firstFallbackCanClaimWithoutComputerEnumeration() async throws {
        let transport = RootTransport()
        await transport.setComputerUnavailable()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let folder = try await backend.createFallbackFolder()

        let claimed = try await backend.ensureClaim(for: folder, incarnation: "fallback")
        #expect(claimed.location == .myFiles)
        #expect(try await backend.inventory(location: .myFiles).verifiedCandidates == [claimed])
    }

    @Test func explicitFallbackDoesNotMaskMyFilesFailureAfterComputerListing() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        await transport.failNextMyFilesListing()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        await #expect(throws: DeviceRootOperationError.unavailable) {
            try await backend.inventoryForExplicitFallback()
        }
    }

    @Test func explicitFallbackDoesNotMaskComputerClaimReadFailure() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        await transport.setComputerClaimUnavailable()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        await #expect(throws: DeviceRootOperationError.unavailable) {
            try await backend.inventoryForExplicitFallback()
        }
    }

    @Test func explicitFallbackDoesNotDiscardPartialComputerEnumeration() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        await transport.setPartialComputerFailure()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        await #expect(throws: DeviceRootOperationError.verificationFailed) {
            try await backend.inventoryForExplicitFallback()
        }
    }

    @Test func fallbackRecoveryIncludesComputerWhenItIsAvailable() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let computer = try await backend.ensureClaim(
            for: .init(deviceUID: listedDevice.deviceUID, rootFolderUID: listedDevice.rootFolderUID),
            incarnation: "computer")
        let folder = try await backend.createFallbackFolder()

        let inventory = try await backend.inventoryIncludingKnown(folder)
        #expect(inventory.verifiedCandidates == [computer])
        #expect(inventory.unclaimedCandidates == [folder])
    }

    @Test func missingClaimLeavesCandidateUnclaimed() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        let inventory = try await backend.inventory()
        #expect(
            inventory.unclaimedCandidates == [
                DeviceRootUnclaimedDevice(
                    deviceUID: listedDevice.deviceUID, rootFolderUID: listedDevice.rootFolderUID)
            ])
        #expect(inventory.verifiedCandidates.isEmpty)
    }

    @Test func claimUploadIsCheckedAfterLostResponseBeforeAnyRetry() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.loseNextUploadResponse()
        await #expect(throws: (any Error).self) {
            try await backend.ensureClaim(for: device, incarnation: "claim-a")
        }

        let recovered = try await backend.ensureClaim(for: device, incarnation: "claim-a")
        #expect(recovered.deviceUID == device.deviceUID)
        #expect(recovered.incarnation == "claim-a")
        #expect((await transport.counts()).1 == 1)
        #expect(try await backend.inventory().verifiedCandidates == [recovered])
    }

    @Test func damagedClaimNeverBecomesVerified() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        await transport.setClaim(.verified(filename: "em-root-bad.json", bytes: Data("bad".utf8)), for: listedDevice)
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        let inventory = try await backend.inventory()
        #expect(inventory.hasUnverifiedCandidate)
        #expect(inventory.verifiedCandidates.isEmpty)
        #expect(inventory.unclaimedCandidates.isEmpty)
    }

    @Test func unknownDeviceNameFailsClosed() async throws {
        let transport = RootTransport()
        await transport.add(
            .init(
                deviceUID: "volume~unknown", rootFolderUID: "volume~other", name: nil))
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)

        let inventory = try await backend.inventory()
        #expect(inventory.hasUnverifiedCandidate)
    }

    @Test func renamedDeviceKeepsItsVerifiedClaim() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        let claimed = try await backend.ensureClaim(for: device, incarnation: "claim-a")
        await transport.rename(listedDevice, to: "Renamed computer")

        let inventory = try await backend.inventory()
        #expect(inventory.verifiedCandidates == [claimed])
        #expect(inventory.unclaimedCandidates.isEmpty)
    }

    @Test func renamedClaimAndNamedCandidateBothAppear() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        let claimed = try await backend.ensureClaim(for: device, incarnation: "claim-a")
        await transport.rename(listedDevice, to: "Renamed computer")
        let second = DeviceRootSDKListedDevice(
            deviceUID: "volume~second", rootFolderUID: "volume~second-folder",
            name: "Encrypted Memories")
        await transport.add(second)

        let inventory = try await backend.inventory()
        #expect(inventory.verifiedCandidates == [claimed])
        #expect(
            inventory.unclaimedCandidates == [
                .init(deviceUID: second.deviceUID, rootFolderUID: second.rootFolderUID)
            ])
    }

    @Test func foreignDraftRemainsUntouchedAfterClaimCollision() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.setForeignDraft()

        await #expect(throws: DraftCollision.self) {
            try await backend.ensureClaim(for: device, incarnation: "claim-a")
        }
        #expect(!(await transport.wasDraftOverridden()))
        #expect(try await backend.inventory().unclaimedCandidates == [device])
    }

    @Test func knownUnclaimedDeviceRecoversAfterRename() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.rename(listedDevice, to: "Renamed before claim")

        let recovered = try await backend.ensureClaim(for: device, incarnation: "claim-a")
        #expect(recovered.deviceUID == device.deviceUID)
        #expect(try await backend.inventory().verifiedCandidates == [recovered])
        #expect((await transport.counts()).0 == 1)
    }
}
