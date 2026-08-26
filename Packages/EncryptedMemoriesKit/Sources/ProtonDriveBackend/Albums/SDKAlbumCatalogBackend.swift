import AlbumCore
import Foundation
import PhotosCore
import ProtonDriveSDK

/// Narrow testable surface over the SDK actor. Keeping the protocol here avoids leaking SDK types
/// into AlbumCore while allowing catalog/cancellation/partial-result behavior to be tested without
/// constructing a signed-in Proton client.
protocol SDKPhotoCatalogClient: Sendable {
    func enumerateAlbumNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws
    func cancelEnumerateAlbumNodeUids(cancellationToken: UUID) async throws
    func enumerateSharedWithMeNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws
    func cancelEnumerateSharedWithMeNodeUids(cancellationToken: UUID) async throws
    func getNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws -> DriveNode?
    func cancelGetNode(cancellationToken: UUID) async throws
    func leaveSharedNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws
    func cancelLeaveSharedNode(cancellationToken: UUID) async throws
}

extension EncryptedMemoriesClient: SDKPhotoCatalogClient {}

enum SDKAlbumCatalogError: LocalizedError {
    case missingNode(AlbumNodeIdentifier)
    case unexpectedOwnedNode(AlbumNodeIdentifier)
    case unexpectedPhotoNode(AlbumNodeIdentifier)

    var errorDescription: String? {
        switch self {
        case .missingNode(let node):
            "SDK returned no node for \(node.volumeID)~\(node.nodeID)"
        case .unexpectedOwnedNode(let node):
            "SDK album catalog returned a non-album node for \(node.volumeID)~\(node.nodeID)"
        case .unexpectedPhotoNode(let node):
            "SDK membership lookup returned a non-photo node for \(node.volumeID)~\(node.nodeID)"
        }
    }
}

/// SDK 0.24.0 catalog/sharing/membership adapter. Enumerations publish only after their native
/// callback stream completes, and node hydration uses a bounded task group so a large catalog
/// cannot create one unbounded task per album.
struct SDKAlbumCatalogBackend: AlbumCatalogBackend {
    private let client: any SDKPhotoCatalogClient
    private let maximumConcurrentNodeLoads: Int
    private let admission: JoinedShutdownGate?

    init(
        client: any SDKPhotoCatalogClient,
        maximumConcurrentNodeLoads: Int = 4,
        admission: JoinedShutdownGate? = nil
    ) {
        self.client = client
        self.maximumConcurrentNodeLoads = max(1, maximumConcurrentNodeLoads)
        self.admission = admission
    }

    func listAlbums() async throws -> [AlbumSummary] {
        try await withAdmission {
            try await self.performListAlbums()
        }
    }

    private func performListAlbums() async throws -> [AlbumSummary] {
        let uids = try await enumerateAlbumUIDs()
        let nodes = try await loadNodes(uids)
        let albums = try nodes.compactMap { uid, node -> AlbumSummary? in
            guard let node else {
                throw SDKAlbumCatalogError.missingNode(Self.identifier(uid))
            }
            guard case .album(let album) = node else {
                throw SDKAlbumCatalogError.unexpectedOwnedNode(Self.identifier(uid))
            }
            guard album.trashTime == nil else { return nil }
            return Self.ownedSummary(album)
        }
        return albums.sorted(by: Self.ownedAlbumOrder)
    }

    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        try await withAdmission {
            try await self.performListSharedWithMeAlbums()
        }
    }

    private func performListSharedWithMeAlbums() async throws -> [SharedAlbumSummary] {
        let uids = try await enumerateSharedWithMeUIDs()
        let nodes = try await loadNodes(uids)
        let albums = nodes.compactMap { _, node -> SharedAlbumSummary? in
            guard case .album(let album)? = node, album.trashTime == nil else { return nil }
            return Self.sharedSummary(album)
        }
        return albums.sorted(by: Self.sharedAlbumOrder)
    }

    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        try await withAdmission {
            try await self.performLeaveSharedAlbum(album)
        }
    }

    private func performLeaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws {
        let uid = SDKNodeUid(volumeID: album.volumeID, nodeID: album.nodeID)
        try await SDKCancellableOperation.run { token in
            try await client.leaveSharedNode(nodeUid: uid, cancellationToken: token)
        } cancel: { token in
            try? await client.cancelLeaveSharedNode(cancellationToken: token)
        }
    }

    func albumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        try await withAdmission {
            try await self.performAlbumMemberships(for: photoUIDs)
        }
    }

    private func performAlbumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        let uniqueUIDs = Array(Set(photoUIDs))
        let sdkUIDs = uniqueUIDs.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let nodes = try await loadNodes(sdkUIDs)
        var result: [PhotoUID: Set<AlbumNodeIdentifier>] = [:]
        result.reserveCapacity(nodes.count)
        for (sdkUID, node) in nodes {
            guard let node else {
                throw SDKAlbumCatalogError.missingNode(Self.identifier(sdkUID))
            }
            guard case .photo(let photo) = node else {
                throw SDKAlbumCatalogError.unexpectedPhotoNode(Self.identifier(sdkUID))
            }
            let uid = PhotoUID(volumeID: sdkUID.volumeID, nodeID: sdkUID.nodeID)
            result[uid] = Set(photo.albumUids.map(Self.identifier))
        }
        return result
    }

    private func withAdmission<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let admission else { return try await operation() }
        return try await admission.withAdmission(operation)
    }

    private func enumerateAlbumUIDs() async throws -> [SDKNodeUid] {
        let collector = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateAlbumNodeUids(
                cancellationToken: token,
                onNodeUidEnumerated: { result in collector.receive(result) }
            )
            return try collector.collected()
        } cancel: { token in
            try? await client.cancelEnumerateAlbumNodeUids(cancellationToken: token)
        }
    }

    private func enumerateSharedWithMeUIDs() async throws -> [SDKNodeUid] {
        let collector = SDKEnumerationCollector<SDKNodeUid>()
        return try await SDKCancellableOperation.run { token in
            try await client.enumerateSharedWithMeNodeUids(
                cancellationToken: token,
                onNodeUidEnumerated: { result in collector.receive(result) }
            )
            return try collector.collected()
        } cancel: { token in
            try? await client.cancelEnumerateSharedWithMeNodeUids(cancellationToken: token)
        }
    }

    private func loadNodes(_ uids: [SDKNodeUid]) async throws -> [(SDKNodeUid, DriveNode?)] {
        guard !uids.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: (Int, SDKNodeUid, DriveNode?).self,
            returning: [(SDKNodeUid, DriveNode?)].self
        ) { group in
            var nextIndex = 0
            var ordered = [(SDKNodeUid, DriveNode?)?](repeating: nil, count: uids.count)

            func addNext() {
                guard nextIndex < uids.count else { return }
                let index = nextIndex
                let uid = uids[index]
                nextIndex += 1
                group.addTask {
                    let node = try await SDKCancellableOperation.run { token in
                        try await client.getNode(nodeUid: uid, cancellationToken: token)
                    } cancel: { token in
                        try? await client.cancelGetNode(cancellationToken: token)
                    }
                    return (index, uid, node)
                }
            }

            for _ in 0..<min(maximumConcurrentNodeLoads, uids.count) {
                addNext()
            }
            while let (index, uid, node) = try await group.next() {
                ordered[index] = (uid, node)
                addNext()
            }
            return ordered.compactMap { $0 }
        }
    }

    private static func ownedSummary(_ album: AlbumNode) -> AlbumSummary {
        let name = resolvedName(album.name)
        return AlbumSummary(
            id: album.uid.nodeID,
            volumeID: album.uid.volumeID,
            title: name.value,
            photoCount: Int(clamping: album.photoCount),
            coverPhotoID: album.coverPhotoNodeUid?.nodeID,
            coverPhotoUID: album.coverPhotoNodeUid.map(Self.photoUID),
            lastActivityTime: album.lastActivityTime.map(Date.init(timeIntervalSince1970:)),
            isShared: album.isShared,
            isSharedByURL: album.isSharedByUrl,
            isMetadataDegraded: name.isDegraded || !album.errors.isEmpty
        )
    }

    private static func sharedSummary(_ album: AlbumNode) -> SharedAlbumSummary {
        let name = resolvedName(album.name)
        return SharedAlbumSummary(
            node: identifier(album.uid),
            title: name.value,
            photoCount: Int(clamping: album.photoCount),
            coverPhotoID: album.coverPhotoNodeUid?.nodeID,
            coverPhotoUID: album.coverPhotoNodeUid.map(Self.photoUID),
            owner: album.ownedBy.email ?? album.ownedBy.organization,
            lastActivityTime: album.lastActivityTime.map(Date.init(timeIntervalSince1970:)),
            isSharedByURL: album.isSharedByUrl,
            isMetadataDegraded: name.isDegraded || !album.errors.isEmpty
        )
    }

    private static func resolvedName(
        _ result: Result<String, ProtonDriveSDKDriveError>
    ) -> (value: String, isDegraded: Bool) {
        switch result {
        case .success(let value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            (value, false)
        default:
            (L10n.string("upload.album_label"), true)
        }
    }

    private static func ownedAlbumOrder(_ lhs: AlbumSummary, _ rhs: AlbumSummary) -> Bool {
        let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
        return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
    }

    private static func sharedAlbumOrder(_ lhs: SharedAlbumSummary, _ rhs: SharedAlbumSummary) -> Bool {
        let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.node.volumeID != rhs.node.volumeID { return lhs.node.volumeID < rhs.node.volumeID }
        return lhs.node.nodeID < rhs.node.nodeID
    }

    private static func identifier(_ uid: SDKNodeUid) -> AlbumNodeIdentifier {
        AlbumNodeIdentifier(volumeID: uid.volumeID, nodeID: uid.nodeID)
    }

    private static func photoUID(_ uid: SDKNodeUid) -> PhotoUID {
        PhotoUID(volumeID: uid.volumeID, nodeID: uid.nodeID)
    }
}
