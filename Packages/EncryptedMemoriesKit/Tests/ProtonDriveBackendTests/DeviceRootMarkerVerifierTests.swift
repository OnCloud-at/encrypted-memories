import DeviceRootCore
import Foundation
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

private let owner = "owner@example.invalid"
private let markerDevice = DeviceRootSDKListedDevice(
    deviceUID: "volume~device", rootFolderUID: "volume~root", name: "Encrypted Memories")
private let markerIncarnation = "550e8400-e29b-41d4-a716-446655440000"

private func folder(
    _ id: String, parent: String? = nil, name: String,
    author: Author = .init(emailAddress: owner, signatureVerificationError: nil),
    keyAuthor: Author = .init(emailAddress: owner, signatureVerificationError: nil),
    trashTime: TimeInterval? = nil
) -> FolderNode {
    FolderNode(
        uid: SDKNodeUid(volumeID: "volume", nodeID: id),
        parentUid: parent.map { SDKNodeUid(volumeID: "volume", nodeID: $0) },
        name: .success(name), creationTime: 0, trashTime: trashTime,
        nameAuthor: author, keyAuthor: keyAuthor,
        ownedBy: .init(email: owner, organization: nil), isShared: false,
        isSharedByUrl: false, directRole: .inherited, membership: nil, errors: [])
}

private func verify(
    device: DeviceRootSDKListedDevice = markerDevice,
    root: FolderNode = folder("root", name: "Encrypted Memories"),
    markers: [FolderNode], failChildRead: Bool = false,
    omitChild: Bool = false, failEnumeration: Bool = false
) async throws -> DeviceRootSDKMarkerStatus {
    let nodes = [root] + markers
    let lookup = Dictionary(
        uniqueKeysWithValues: nodes.map { ($0.uid.sdkCompatibleIdentifier, DriveNode(folderNode: $0)) })
    return try await DeviceRootMarkerVerifier.verify(
        device: device, ownerAddresses: [owner],
        node: { uid in
            if failChildRead, uid.nodeID != "root" { throw MarkerReadFailure() }
            if omitChild, uid.nodeID != "root" { return nil }
            return lookup[uid.sdkCompatibleIdentifier]
        },
        folderChildren: { _ in
            if failEnumeration { throw MarkerReadFailure() }
            return markers.map(\.uid)
        })
}

private struct MarkerReadFailure: Error {}

@Suite("SDK root marker verification")
struct DeviceRootMarkerVerifierTests {
    @Test func verifiedMarkerRequiresOwnerAndExactContext() async throws {
        let name = try #require(DeviceRootMarker.name(for: markerDevice, incarnation: markerIncarnation))
        let result = try await verify(markers: [folder("marker", parent: "root", name: name)])
        #expect(result == .verified(name: name))
        #expect(try await verify(markers: [folder("marker", parent: "root", name: name + "x")]) == .unverified)
        let otherDevice = DeviceRootSDKListedDevice(
            deviceUID: "volume~other", rootFolderUID: "volume~root", name: "Encrypted Memories")
        let otherName = try #require(DeviceRootMarker.name(for: otherDevice, incarnation: markerIncarnation))
        #expect(otherName.count == name.count)
        #expect(try await verify(markers: [folder("marker", parent: "root", name: otherName)]) == .unverified)
    }

    @Test func wrongParentOrTrashedNodeFailsClosed() async throws {
        let name = try #require(DeviceRootMarker.name(for: markerDevice, incarnation: markerIncarnation))
        #expect(try await verify(markers: [folder("marker", parent: "elsewhere", name: name)]) == .unverified)
        #expect(try await verify(markers: [folder("marker", parent: "root", name: name, trashTime: 1)]) == .unverified)
        #expect(
            try await verify(
                root: folder("root", name: "Encrypted Memories", trashTime: 1),
                markers: [folder("marker", parent: "root", name: name)]) == .unverified)
    }

    @Test func signerFailureAndDuplicateMarkerFailClosed() async throws {
        let name = try #require(DeviceRootMarker.name(for: markerDevice, incarnation: markerIncarnation))
        let foreign = Author(emailAddress: "foreign@example.invalid", signatureVerificationError: nil)
        let invalid = Author(emailAddress: owner, signatureVerificationError: "invalid signature")
        #expect(
            try await verify(markers: [folder("marker", parent: "root", name: name, author: foreign)]) == .unverified)
        #expect(
            try await verify(markers: [folder("marker", parent: "root", name: name, keyAuthor: invalid)]) == .unverified
        )
        #expect(
            try await verify(markers: [
                folder("a", parent: "root", name: name), folder("b", parent: "root", name: name),
            ]) == .unverified)
        #expect(
            try await verify(
                root: folder("root", name: "Encrypted Memories", author: foreign),
                markers: [folder("marker", parent: "root", name: name)]) == .unverified)
    }

    @Test func missingAndUnreadableMarkersNeverVerify() async throws {
        let name = try #require(DeviceRootMarker.name(for: markerDevice, incarnation: markerIncarnation))
        #expect(try await verify(markers: []) == .missing)
        await #expect(throws: MarkerReadFailure.self) {
            try await verify(markers: [folder("marker", parent: "root", name: name)], failChildRead: true)
        }
        #expect(
            try await verify(markers: [folder("marker", parent: "root", name: name)], omitChild: true)
                == .unverified)
        await #expect(throws: MarkerReadFailure.self) {
            try await verify(markers: [folder("marker", parent: "root", name: name)], failEnumeration: true)
        }
    }

    @Test func fallbackRootMustHaveExpectedAncestry() async throws {
        let fallback = DeviceRootSDKListedDevice(
            deviceUID: "volume~my-files", rootFolderUID: "volume~root",
            name: "Encrypted Memories", location: .myFiles)
        let name = try #require(DeviceRootMarker.name(for: fallback, incarnation: markerIncarnation))
        let marker = folder("marker", parent: "root", name: name)
        #expect(
            try await verify(
                device: fallback,
                root: folder("root", parent: "my-files", name: "Encrypted Memories"),
                markers: [marker]) == .verified(name: name))
        #expect(try await verify(device: fallback, markers: [marker]) == .unverified)
    }
}
