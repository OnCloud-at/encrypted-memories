import DeviceRootCore
import Foundation
import Testing

@testable import ProtonDriveBackend

private let listedDevice = DeviceRootSDKListedDevice(
    deviceUID: "volume~device", rootFolderUID: "volume~folder", name: "Encrypted Memories")
private let listedFallback = DeviceRootSDKListedDevice(
    deviceUID: "volume~my-files", rootFolderUID: "volume~fallback", name: "Encrypted Memories",
    location: .myFiles)
private let incarnationA = "550e8400-e29b-41d4-a716-446655440000"
private let incarnationB = "550e8400-e29b-41d4-a716-446655440001"

private actor RootTransport: DeviceRootSDKTransport {
    var listed: [DeviceRootSDKListedDevice] = []
    var fallbackFolders: [DeviceRootSDKListedDevice] = []
    var computerUnavailable = false
    var partialComputerFailure = false
    var myFilesFailuresRemaining = 0
    var computerClaimUnavailable = false
    var markers: [String: DeviceRootSDKMarkerStatus] = [:]
    var createCount = 0
    var markerCount = 0
    var loseMarkerResponse = false
    var markerCollision = false

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

    func marker(for device: DeviceRootSDKListedDevice) async throws -> DeviceRootSDKMarkerStatus {
        if computerClaimUnavailable, device.location == .computer {
            throw DeviceRootOperationError.unavailable
        }
        return markers[device.rootFolderUID] ?? .missing
    }

    func createMarker(for device: DeviceRootSDKListedDevice, name: String) async throws {
        markerCount += 1
        if markerCollision { throw MarkerCollision() }
        markers[device.rootFolderUID] = .verified(name: name)
        if loseMarkerResponse { throw CancellationError() }
    }

    func add(_ device: DeviceRootSDKListedDevice) { listed.append(device) }
    func rename(_ device: DeviceRootSDKListedDevice, to name: String) {
        listed = listed.map {
            $0.deviceUID == device.deviceUID
                ? .init(deviceUID: $0.deviceUID, rootFolderUID: $0.rootFolderUID, name: name)
                : $0
        }
    }
    func setMarker(_ status: DeviceRootSDKMarkerStatus, for device: DeviceRootSDKListedDevice) {
        markers[device.rootFolderUID] = status
    }
    func loseNextMarkerResponse() { loseMarkerResponse = true }
    func setMarkerCollision() { markerCollision = true }
    func setComputerUnavailable() { computerUnavailable = true }
    func setPartialComputerFailure() { partialComputerFailure = true }
    func failNextMyFilesListing() { myFilesFailuresRemaining = 1 }
    func setComputerClaimUnavailable() { computerClaimUnavailable = true }
    func counts() -> (Int, Int) { (createCount, markerCount) }
}

private struct MarkerCollision: Error {}

@Suite("SDK device root enrollment")
struct SDKDeviceRootEnrollmentBackendTests {
    @Test func markerIsBoundToItsContainerAndIncarnation() {
        let incarnation = "550e8400-e29b-41d4-a716-446655440000"
        let name = DeviceRootMarker.name(for: listedDevice, incarnation: incarnation) ?? ""
        #expect(!name.isEmpty)
        #expect(DeviceRootMarker.incarnation(from: name, for: listedDevice) == incarnation)
        #expect(DeviceRootMarker.incarnation(from: name, for: listedFallback) == nil)
        #expect(DeviceRootMarker.incarnation(from: name + "x", for: listedDevice) == nil)
        #expect(DeviceRootMarker.name(for: listedDevice, incarnation: "claim-a") == nil)
    }

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
        let claimed = try await backend.ensureClaim(for: folder, incarnation: incarnationA)
        #expect(claimed.location == .myFiles)
        #expect(claimed.rootFolderUID == listedFallback.rootFolderUID)
        #expect(try await backend.inventory().verifiedCandidates == [claimed])
    }

    @Test func existingFallbackRemainsVerifiableWhenComputerEndpointDisappears() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let folder = try await backend.createFallbackFolder()
        let claimed = try await backend.ensureClaim(for: folder, incarnation: incarnationA)
        await transport.setComputerUnavailable()

        let inventory = try await backend.inventory(location: .myFiles)
        #expect(inventory.verifiedCandidates == [claimed])
    }

    @Test func firstFallbackCanClaimWithoutComputerEnumeration() async throws {
        let transport = RootTransport()
        await transport.setComputerUnavailable()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let folder = try await backend.createFallbackFolder()

        let claimed = try await backend.ensureClaim(for: folder, incarnation: incarnationA)
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
            incarnation: incarnationB)
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

    @Test func markerCreateIsCheckedAfterLostResponseBeforeAnyRetry() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.loseNextMarkerResponse()
        await #expect(throws: (any Error).self) {
            try await backend.ensureClaim(for: device, incarnation: incarnationA)
        }

        let recovered = try await backend.ensureClaim(for: device, incarnation: incarnationA)
        #expect(recovered.deviceUID == device.deviceUID)
        #expect(recovered.incarnation == incarnationA)
        #expect((await transport.counts()).1 == 1)
        #expect(try await backend.inventory().verifiedCandidates == [recovered])
    }

    @Test func damagedMarkerNeverBecomesVerified() async throws {
        let transport = RootTransport()
        await transport.add(listedDevice)
        await transport.setMarker(.verified(name: "em-root-v1-bad"), for: listedDevice)
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
        let claimed = try await backend.ensureClaim(for: device, incarnation: incarnationA)
        await transport.rename(listedDevice, to: "Renamed computer")

        let inventory = try await backend.inventory()
        #expect(inventory.verifiedCandidates == [claimed])
        #expect(inventory.unclaimedCandidates.isEmpty)
    }

    @Test func renamedClaimAndNamedCandidateBothAppear() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        let claimed = try await backend.ensureClaim(for: device, incarnation: incarnationA)
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

    @Test func markerCollisionRemainsUnresolved() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.setMarkerCollision()

        await #expect(throws: MarkerCollision.self) {
            try await backend.ensureClaim(for: device, incarnation: incarnationA)
        }
        #expect(try await backend.inventory().unclaimedCandidates == [device])
    }

    @Test func knownUnclaimedDeviceRecoversAfterRename() async throws {
        let transport = RootTransport()
        let backend = SDKDeviceRootEnrollmentBackend(transport: transport)
        let device = try await backend.createDevice()
        await transport.rename(listedDevice, to: "Renamed before claim")

        let recovered = try await backend.ensureClaim(for: device, incarnation: incarnationA)
        #expect(recovered.deviceUID == device.deviceUID)
        #expect(try await backend.inventory().verifiedCandidates == [recovered])
        #expect((await transport.counts()).0 == 1)
    }
}
