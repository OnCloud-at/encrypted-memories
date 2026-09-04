import AlbumCore
import Foundation
import PhotosCore
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("SDK album catalog")
struct SDKAlbumCatalogBackendTests {
    @Test func ownedCatalogMapsSDKMetadataSortsAndKeepsDegradedNodesVisible() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let z = albumNode(id: "z", name: .success("Zoo"), photoCount: 7, coverID: "cover-z")
        let a = albumNode(
            id: "a",
            name: .failure(ProtonDriveSDKDriveError(message: "name verification failed")),
            photoCount: 2,
            coverID: nil,
            errors: [ProtonDriveSDKDriveError(message: "node warning")]
        )
        await client.configureOwned(
            [z.uid, a.uid],
            nodes: [
                z.uid.sdkCompatibleIdentifier: .init(albumNode: z),
                a.uid.sdkCompatibleIdentifier: .init(albumNode: a),
            ])

        let albums = try await SDKAlbumCatalogBackend(client: client).listAlbums()

        #expect(albums.map(\.id) == ["a", "z"])
        #expect(albums[0].title == L10n.string("upload.album_label"))
        #expect(albums[0].isMetadataDegraded)
        #expect(albums[1].photoCount == 7)
        #expect(albums[1].coverPhotoID == "cover-z")
        #expect(albums[1].coverPhotoUID == PhotoUID(volumeID: "volume", nodeID: "cover-z"))
        #expect(albums[1].volumeID == "volume")
    }

    @Test func ownedCatalogHydratesNodesWithBoundedConcurrency() async throws {
        let client = FakeSDKPhotoCatalogClient(nodeDelay: .milliseconds(30))
        let albums = (0..<8).map {
            albumNode(id: "album-\($0)", name: .success("Album \($0)"), photoCount: Int64($0))
        }
        await client.configureOwned(
            albums.map(\.uid),
            nodes: Dictionary(
                uniqueKeysWithValues: albums.map {
                    ($0.uid.sdkCompatibleIdentifier, DriveNode(albumNode: $0))
                })
        )

        _ = try await SDKAlbumCatalogBackend(
            client: client,
            maximumConcurrentNodeLoads: 2
        ).listAlbums()

        #expect(await client.maximumConcurrentGetNodeCalls == 2)
    }

    @Test func sharedCatalogFiltersPhotosAndMapsOwnerAndSharingState() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let shared = albumNode(
            id: "shared",
            name: .success("Family"),
            photoCount: 11,
            coverID: "cover",
            owner: "owner@example.test",
            isShared: true,
            isSharedByURL: true
        )
        let photo = photoNode(id: "photo", albumIDs: [])
        await client.configureShared(
            [photo.uid, shared.uid],
            nodes: [
                photo.uid.sdkCompatibleIdentifier: .init(photoNode: photo),
                shared.uid.sdkCompatibleIdentifier: .init(albumNode: shared),
            ])

        let albums = try await SDKAlbumCatalogBackend(client: client).listSharedWithMeAlbums()

        #expect(albums.count == 1)
        #expect(albums[0].title == "Family")
        #expect(albums[0].owner == "owner@example.test")
        #expect(albums[0].photoCount == 11)
        #expect(albums[0].coverPhotoUID == PhotoUID(volumeID: "volume", nodeID: "cover"))
        #expect(albums[0].isSharedByURL)
    }

    @Test func sharedCatalogAndSourceDiscoveryJoinOneHydrationSweep() async throws {
        let client = FakeSDKPhotoCatalogClient(nodeDelay: .milliseconds(30))
        let shared = albumNode(
            id: "shared",
            name: .success("Shared"),
            photoCount: 1,
            isShared: true
        )
        await client.configureShared(
            [shared.uid],
            nodes: [shared.uid.sdkCompatibleIdentifier: .init(albumNode: shared)]
        )
        let backend = SDKAlbumCatalogBackend(client: client)

        async let summaries = backend.listSharedWithMeAlbums()
        async let locators = backend.librarySourceLocators()
        let (resolvedSummaries, resolvedLocators) = try await (summaries, locators)

        #expect(resolvedSummaries.map(\.node) == resolvedLocators)
        #expect(await client.sharedEnumerationCalls == 1)
        #expect(await client.getNodeCalls == 1)
    }

    @Test func leavingSharedAlbumInvalidatesTheSharedSnapshot() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let shared = albumNode(
            id: "shared",
            name: .success("Shared"),
            photoCount: 1,
            isShared: true
        )
        await client.configureShared(
            [shared.uid],
            nodes: [shared.uid.sdkCompatibleIdentifier: .init(albumNode: shared)]
        )
        let backend = SDKAlbumCatalogBackend(client: client)

        _ = try await backend.listSharedWithMeAlbums()
        try await backend.leaveSharedAlbum(
            AlbumNodeIdentifier(volumeID: shared.uid.volumeID, nodeID: shared.uid.nodeID)
        )
        _ = try await backend.librarySourceLocators()

        #expect(await client.sharedEnumerationCalls == 2)
        #expect(await client.getNodeCalls == 2)
        #expect(await client.leftSharedNodeIdentifiers == [shared.uid.sdkCompatibleIdentifier])
    }

    @Test func cancellingOneSharedSnapshotWaiterDoesNotCancelTheOther() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let cache = SDKSharedAlbumSnapshotCache()
        let probe = SharedSnapshotLoaderProbe()
        let shared = albumNode(
            id: "shared",
            name: .success("Shared"),
            photoCount: 1,
            isShared: true
        )
        let first = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        while await probe.loadCalls == 0 { await Task.yield() }
        let second = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await probe.loadCalls == 1)

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await probe.finish(with: [shared])

        #expect(
            try await second.value.map { $0.uid.sdkCompatibleIdentifier }
                == [shared.uid.sdkCompatibleIdentifier]
        )
        #expect(await probe.loadCalls == 1)
        await cache.invalidateAll()
    }

    @Test func invalidationRejectsEveryOldSnapshotWaiterAndFencesLateCompletion() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let cache = SDKSharedAlbumSnapshotCache()
        let probe = SharedSnapshotLoaderProbe()
        let stale = albumNode(
            id: "stale",
            name: .success("Stale"),
            photoCount: 1,
            isShared: true
        )
        let current = albumNode(
            id: "current",
            name: .success("Current"),
            photoCount: 1,
            isShared: true
        )
        let first = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        while await probe.loadCalls == 0 { await Task.yield() }
        let second = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await probe.loadCalls == 1)

        await cache.invalidate(client: client)
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }

        let resolved = try await cache.value(client: client) { [current] }
        #expect(
            resolved.map { $0.uid.sdkCompatibleIdentifier }
                == [current.uid.sdkCompatibleIdentifier]
        )
        await probe.finish(with: [stale])
        let cached = try await cache.value(client: client) { [stale] }
        #expect(
            cached.map { $0.uid.sdkCompatibleIdentifier }
                == [current.uid.sdkCompatibleIdentifier]
        )
        await cache.invalidateAll()
    }

    @Test func canceledWaiterCannotObserveAConcurrentSuccessfulCompletion() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let cache = SDKSharedAlbumSnapshotCache()
        let probe = SharedSnapshotLoaderProbe()
        let shared = albumNode(
            id: "shared",
            name: .success("Shared"),
            photoCount: 1,
            isShared: true
        )
        let waiter = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        while await probe.loadCalls == 0 { await Task.yield() }

        waiter.cancel()
        await probe.finish(with: [shared])

        await #expect(throws: CancellationError.self) { try await waiter.value }
        await cache.invalidateAll()
    }

    @Test func shutdownInvalidationJoinsAnOrphanedLoaderAfterImmediateFencing() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let cache = SDKSharedAlbumSnapshotCache()
        let probe = SharedSnapshotLoaderProbe()
        let waiter = Task {
            try await cache.value(client: client) { try await probe.load() }
        }
        while await probe.loadCalls == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        let returned = CatalogShutdownProbe()
        let shutdown = Task {
            await cache.invalidateAll()
            await returned.markReturned()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await returned.hasReturned == false)

        await probe.finish(with: [])
        await shutdown.value
        #expect(await returned.hasReturned)
    }

    @Test func sealedAdmissionJoinsBeforeCacheOwnedSDKWorkAndTeardown() async throws {
        let gate = JoinedShutdownGate()
        let client = FakeSDKPhotoCatalogClient()
        let cache = SDKSharedAlbumSnapshotCache()
        let probe = SharedSnapshotLoaderProbe()
        let operation = Task {
            try await gate.withAdmission {
                try await cache.value(client: client) { try await probe.load() }
            }
        }
        while await probe.loadCalls == 0 { await Task.yield() }

        gate.closeAdmission()
        let returned = CatalogShutdownProbe()
        let shutdown = Task {
            await gate.run {
                await cache.invalidateAll()
                await returned.markReturned()
            }
        }

        await #expect(throws: CancellationError.self) { try await operation.value }
        for _ in 0..<20 { await Task.yield() }
        #expect(await returned.hasReturned == false)

        await probe.finish(with: [])
        await shutdown.value
        #expect(await returned.hasReturned)
    }

    @Test func unresolvedSharedNodeRejectsTheWholeSnapshot() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let unresolved = SDKNodeUid(volumeID: "volume", nodeID: "unresolved")
        await client.configureShared([unresolved], nodes: [:])

        await #expect(throws: SDKAlbumCatalogError.self) {
            try await SDKAlbumCatalogBackend(client: client).librarySourceLocators()
        }
        #expect(await client.sharedEnumerationCalls == 1)
        #expect(await client.getNodeCalls == 1)
    }

    @Test func membershipLookupReturnsLosslessAlbumUIDs() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let photo = photoNode(
            id: "photo",
            albumIDs: [
                SDKNodeUid(volumeID: "volume", nodeID: "one"),
                SDKNodeUid(volumeID: "shared-volume", nodeID: "two"),
            ])
        await client.configureNodes([
            photo.uid.sdkCompatibleIdentifier: .init(photoNode: photo)
        ])

        let uid = PhotoUID(volumeID: "volume", nodeID: "photo")
        let memberships = try await SDKAlbumCatalogBackend(client: client)
            .albumMemberships(for: [uid])

        #expect(
            memberships[uid] == [
                AlbumNodeIdentifier(volumeID: "volume", nodeID: "one"),
                AlbumNodeIdentifier(volumeID: "shared-volume", nodeID: "two"),
            ])
    }

    @Test func sourceInventoryUsesVolumeQualifiedAlbumItemsAndExplicitPartialMetadata() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let shared = albumNode(
            id: "source-album",
            name: .success("Source"),
            photoCount: 1,
            isShared: true
        )
        let photo = AlbumItem(
            nodeUid: SDKNodeUid(volumeID: "shared-volume", nodeID: "photo"),
            captureTime: 42
        )
        await client.configureShared(
            [shared.uid],
            nodes: [shared.uid.sdkCompatibleIdentifier: .init(albumNode: shared)]
        )
        await client.configureAlbumContents([shared.uid.sdkCompatibleIdentifier: [photo]])
        let backend = SDKAlbumCatalogBackend(client: client)

        let locators = try await backend.librarySourceLocators()
        let items = try await backend.librarySourceItems(for: locators[0])

        #expect(locators == [AlbumNodeIdentifier(volumeID: "volume", nodeID: "source-album")])
        #expect(items.count == 1)
        #expect(items[0].uid == PhotoUID(volumeID: "shared-volume", nodeID: "photo"))
        #expect(items[0].item.captureTime == Date(timeIntervalSince1970: 42))
        #expect(items[0].item.mediaType.isEmpty)
        #expect(items[0].knownFields == [.captureTime])
    }

    @Test func invalidSourceCaptureTimeRejectsTheWholeInventory() async throws {
        let client = FakeSDKPhotoCatalogClient()
        let album = AlbumNodeIdentifier(volumeID: "volume", nodeID: "source-album")
        await client.configureAlbumContents([
            "volume~source-album": [
                AlbumItem(
                    nodeUid: SDKNodeUid(volumeID: "volume", nodeID: "photo"),
                    captureTime: .nan
                )
            ]
        ])

        await #expect(throws: SDKAlbumCatalogError.self) {
            try await SDKAlbumCatalogBackend(client: client).librarySourceItems(for: album)
        }
    }

    @Test func cancellingSourceInventoryCancelsItsSDKEnumerationAndPublishesNoPartialResult() async throws {
        let client = FakeSDKPhotoCatalogClient(waitForAlbumContentCancellation: true)
        let backend = SDKAlbumCatalogBackend(client: client)
        let task = Task {
            try await backend.librarySourceItems(
                for: AlbumNodeIdentifier(volumeID: "volume", nodeID: "source-album")
            )
        }

        while await client.albumContentEnumerationToken == nil {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await client.albumContentEnumerationToken == client.cancelledAlbumContentEnumerationToken)
    }

    @Test func cancellingCatalogUsesEnumerationTokenAndPublishesNoPartialResult() async throws {
        let client = FakeSDKPhotoCatalogClient(waitForAlbumCancellation: true)
        let task = Task {
            try await SDKAlbumCatalogBackend(client: client).listAlbums()
        }

        while await client.albumEnumerationToken == nil {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await client.albumEnumerationToken == client.cancelledAlbumEnumerationToken)
    }

    @Test func sharedShutdownAdmissionCancelsAndJoinsPublishedCatalogWork() async throws {
        let gate = JoinedShutdownGate()
        let client = FakeSDKPhotoCatalogClient(
            waitForAlbumCancellation: true,
            deferAlbumCancellationCompletion: true
        )
        let backend = SDKAlbumCatalogBackend(client: client, admission: gate)
        let operation = Task { try await backend.listAlbums() }

        while await client.albumEnumerationToken == nil {
            await Task.yield()
        }

        gate.closeAdmission()
        let shutdownReturned = CatalogShutdownProbe()
        let shutdown = Task {
            await gate.closeAdmissionAndJoin()
            await shutdownReturned.markReturned()
        }

        while await client.cancelledAlbumEnumerationToken == nil {
            await Task.yield()
        }
        #expect(await shutdownReturned.hasReturned == false)
        await #expect(throws: CancellationError.self) {
            try await backend.listAlbums()
        }

        await client.releaseAlbumEnumeration()
        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        await shutdown.value
        #expect(await shutdownReturned.hasReturned)
    }
}

private actor CatalogShutdownProbe {
    private(set) var hasReturned = false

    func markReturned() {
        hasReturned = true
    }
}

private actor SharedSnapshotLoaderProbe {
    private(set) var loadCalls = 0
    private var continuation: CheckedContinuation<[AlbumNode], any Error>?

    func load() async throws -> [AlbumNode] {
        loadCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with nodes: [AlbumNode]) {
        continuation?.resume(returning: nodes)
        continuation = nil
    }
}

private actor FakeSDKPhotoCatalogClient: SDKPhotoCatalogClient {
    private var ownedUIDs: [SDKNodeUid] = []
    private var sharedUIDs: [SDKNodeUid] = []
    private var nodes: [String: DriveNode] = [:]
    private let nodeDelay: Duration
    private let waitForAlbumCancellation: Bool
    private let deferAlbumCancellationCompletion: Bool
    private let waitForAlbumContentCancellation: Bool
    private var albumContinuation: CheckedContinuation<Void, any Error>?
    private var albumContentContinuation: CheckedContinuation<Void, any Error>?
    private var albumItemsByUID: [String: [AlbumItem]] = [:]
    private(set) var albumEnumerationToken: UUID?
    private(set) var cancelledAlbumEnumerationToken: UUID?
    private(set) var albumContentEnumerationToken: UUID?
    private(set) var cancelledAlbumContentEnumerationToken: UUID?
    private(set) var maximumConcurrentGetNodeCalls = 0
    private(set) var getNodeCalls = 0
    private(set) var sharedEnumerationCalls = 0
    private(set) var leftSharedNodeIdentifiers: [String] = []
    private var concurrentGetNodeCalls = 0

    init(
        nodeDelay: Duration = .zero,
        waitForAlbumCancellation: Bool = false,
        deferAlbumCancellationCompletion: Bool = false,
        waitForAlbumContentCancellation: Bool = false
    ) {
        self.nodeDelay = nodeDelay
        self.waitForAlbumCancellation = waitForAlbumCancellation
        self.deferAlbumCancellationCompletion = deferAlbumCancellationCompletion
        self.waitForAlbumContentCancellation = waitForAlbumContentCancellation
    }

    func configureOwned(_ uids: [SDKNodeUid], nodes: [String: DriveNode]) {
        ownedUIDs = uids
        self.nodes = nodes
    }

    func configureShared(_ uids: [SDKNodeUid], nodes: [String: DriveNode]) {
        sharedUIDs = uids
        self.nodes = nodes
    }

    func configureNodes(_ nodes: [String: DriveNode]) {
        self.nodes = nodes
    }

    func configureAlbumContents(_ items: [String: [AlbumItem]]) {
        albumItemsByUID = items
    }

    func enumerateAlbumNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws {
        albumEnumerationToken = cancellationToken
        if waitForAlbumCancellation {
            try await withCheckedThrowingContinuation { continuation in
                albumContinuation = continuation
            }
            return
        }
        for uid in ownedUIDs {
            onNodeUidEnumerated(.success(uid))
        }
    }

    func cancelEnumerateAlbumNodeUids(cancellationToken: UUID) {
        cancelledAlbumEnumerationToken = cancellationToken
        guard !deferAlbumCancellationCompletion else { return }
        releaseAlbumEnumeration()
    }

    func releaseAlbumEnumeration() {
        albumContinuation?.resume(throwing: CancellationError())
        albumContinuation = nil
    }

    func enumerateSharedWithMeNodeUids(
        cancellationToken: UUID,
        onNodeUidEnumerated: @escaping NodeUidCallback
    ) async throws {
        sharedEnumerationCalls += 1
        for uid in sharedUIDs {
            onNodeUidEnumerated(.success(uid))
        }
    }

    func cancelEnumerateSharedWithMeNodeUids(cancellationToken: UUID) {}

    func enumerateAlbum(
        albumUid: SDKNodeUid,
        cancellationToken: UUID,
        onAlbumItemEnumerated: @escaping AlbumItemCallback
    ) async throws {
        albumContentEnumerationToken = cancellationToken
        if waitForAlbumContentCancellation {
            try await withCheckedThrowingContinuation { continuation in
                albumContentContinuation = continuation
            }
            return
        }
        for item in albumItemsByUID[albumUid.sdkCompatibleIdentifier] ?? [] {
            onAlbumItemEnumerated(.success(item))
        }
    }

    func cancelEnumerateAlbum(cancellationToken: UUID) {
        cancelledAlbumContentEnumerationToken = cancellationToken
        albumContentContinuation?.resume(throwing: CancellationError())
        albumContentContinuation = nil
    }

    func getNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws -> DriveNode? {
        getNodeCalls += 1
        concurrentGetNodeCalls += 1
        maximumConcurrentGetNodeCalls = max(maximumConcurrentGetNodeCalls, concurrentGetNodeCalls)
        do {
            if nodeDelay != .zero {
                try await Task.sleep(for: nodeDelay)
            }
            concurrentGetNodeCalls -= 1
            return nodes[nodeUid.sdkCompatibleIdentifier]
        } catch {
            concurrentGetNodeCalls -= 1
            throw error
        }
    }

    func cancelGetNode(cancellationToken: UUID) {}
    func leaveSharedNode(nodeUid: SDKNodeUid, cancellationToken: UUID) async throws {
        leftSharedNodeIdentifiers.append(nodeUid.sdkCompatibleIdentifier)
    }
    func cancelLeaveSharedNode(cancellationToken: UUID) {}
}

private func albumNode(
    id: String,
    name: Result<String, ProtonDriveSDKDriveError>,
    photoCount: Int64,
    coverID: String? = nil,
    owner: String? = nil,
    isShared: Bool = false,
    isSharedByURL: Bool = false,
    errors: [ProtonDriveSDKDriveError] = []
) -> AlbumNode {
    let uid = SDKNodeUid(volumeID: "volume", nodeID: id)
    return AlbumNode(
        uid: uid,
        parentUid: nil,
        name: name,
        creationTime: 10,
        trashTime: nil,
        nameAuthor: Author(emailAddress: owner, signatureVerificationError: nil),
        keyAuthor: Author(emailAddress: owner, signatureVerificationError: nil),
        ownedBy: OwnedBy(email: owner, organization: nil),
        isShared: isShared,
        isSharedByUrl: isSharedByURL,
        errors: errors,
        photoCount: photoCount,
        coverPhotoNodeUid: coverID.map { SDKNodeUid(volumeID: "volume", nodeID: $0) },
        lastActivityTime: 20
    )
}

private func photoNode(id: String, albumIDs: [SDKNodeUid]) -> PhotoNode {
    let uid = SDKNodeUid(volumeID: "volume", nodeID: id)
    let revision = FileRevision(
        uid: SDKRevisionUid(volumeID: "volume", nodeID: id, revisionID: "revision"),
        state: .active,
        creationTime: 1,
        storageSize: 1,
        claimedSize: 1,
        claimedDigests: FileContentDigests(sha1: nil, sha1Verified: false),
        claimedModificationTime: nil,
        thumbnails: [],
        claimedAdditionalMetadata: nil,
        contentAuthor: nil
    )
    return PhotoNode(
        uid: uid,
        parentUid: nil,
        name: .success("\(id).jpg"),
        creationTime: 1,
        trashTime: nil,
        nameAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        keyAuthor: Author(emailAddress: nil, signatureVerificationError: nil),
        ownedBy: OwnedBy(email: nil, organization: nil),
        mediaType: "image/jpeg",
        totalStorageSize: 1,
        activeRevision: revision,
        isShared: false,
        isSharedByUrl: false,
        errors: [],
        captureTime: 1,
        albumUids: albumIDs
    )
}
