import AlbumCore
import CryptoKit
import Foundation
import MLSearchCore
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import LibrarySourceRuntime
@testable import ProtonDriveBackend

@Test func sourceAnalysisRuntimeKeepsPrimaryProjectionSeparateFromAuthoritativeAnalysis() async throws {
    let remoteUID = PhotoUID(volumeID: "additional-volume", nodeID: "remote-photo")
    let backend = FakeLibrarySourceBackend(
        locators: [AlbumNodeIdentifier(volumeID: "additional-volume", nodeID: "album")],
        itemsByAlbum: [
            "additional-volume~album": [
                LibrarySourceItem(
                    item: PhotoItem(
                        uid: remoteUID,
                        captureTime: Date(timeIntervalSince1970: 20),
                        mediaType: ""
                    ),
                    knownFields: [.captureTime]
                )
            ]
        ]
    )
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-runtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-test", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let universe = MLAssetUniverse()
    let notifications = NotificationCounter()
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: universe,
        onAssetsChanged: { Task { await notifications.increment() } }
    )
    let primary = PhotoItem(
        uid: PhotoUID(volumeID: "primary-volume", nodeID: "owned-photo"),
        captureTime: Date(timeIntervalSince1970: 10),
        mediaType: "image/jpeg"
    )

    #expect(await runtime.start())
    await runtime.replacePrimaryInventory([primary], authority: .authoritative)
    await runtime.refresh()

    let snapshot = universe.snapshot()
    #expect(snapshot.isAuthoritative)
    #expect(Set(snapshot.uids) == Set([primary.uid, remoteUID]))
    let delivered = ThumbnailDeliveryProbe()
    let result = await coordinator.loadThumbnails(for: [remoteUID], priority: .idleLibraryCrawl) { uid, data in
        delivered.record(uid: uid, data: data)
    }
    #expect(result == .delivered)
    #expect(delivered.data(for: remoteUID) == Data("thumbnail".utf8))

    await runtime.shutdown()
    await coordinator.shutdown()
}

@Test func delayedStartupCannotOverwriteANewerPrimaryInventoryGeneration() async throws {
    let backend = FakeLibrarySourceBackend(locators: [], itemsByAlbum: [:])
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-startup-race-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-startup-race", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let universe = MLAssetUniverse()
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: universe,
        onAssetsChanged: {}
    )
    let stale = PhotoItem(
        uid: PhotoUID(volumeID: "primary", nodeID: "stale"),
        captureTime: Date(timeIntervalSince1970: 1),
        mediaType: "image/jpeg"
    )
    let current = PhotoItem(
        uid: PhotoUID(volumeID: "primary", nodeID: "current"),
        captureTime: Date(timeIntervalSince1970: 2),
        mediaType: "image/jpeg"
    )

    await runtime.replacePrimaryInventory(
        [current],
        authority: .authoritative,
        generation: 2
    )
    #expect(
        await runtime.start(
            primaryItems: [stale],
            authority: .authoritative,
            generation: 1
        )
    )
    await runtime.refresh()

    let snapshot = universe.snapshot()
    #expect(snapshot.isAuthoritative)
    #expect(snapshot.uids == [current.uid])
    let visibleWarm = await feed.warmVisibleDecoded(
        [ThumbnailRequest(uid: current.uid)],
        limit: 1
    )
    #expect(visibleWarm.requested == 1)
    #expect(visibleWarm.queuedNetwork == 1)
    let delivered = ThumbnailDeliveryProbe()
    let result = await coordinator.loadThumbnails(for: [current.uid], priority: .visibleNow) { uid, data in
        delivered.record(uid: uid, data: data)
    }
    #expect(result == .delivered)
    #expect(delivered.data(for: current.uid) == Data("thumbnail".utf8))
    await runtime.shutdown()
    await coordinator.shutdown()
}

@Test func shutdownCancelsAndJoinsTheCoordinatorOwnedRefresh() async throws {
    let backend = CancellationDeferredLibrarySourceBackend()
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-shutdown-barrier-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-shutdown-barrier", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: MLAssetUniverse(),
        onAssetsChanged: {}
    )

    #expect(await runtime.start())
    while await !backend.isDiscoveryWaiting() { await Task.yield() }

    let completion = CompletionProbe()
    let shutdown = Task {
        await runtime.shutdown()
        completion.markCompleted()
    }
    for _ in 0..<1_000 where !backend.cancellationWasObserved {
        await Task.yield()
    }

    #expect(backend.cancellationWasObserved)
    #expect(!completion.isCompleted)
    await backend.releaseDiscovery()
    await shutdown.value
    #expect(completion.isCompleted)
    await coordinator.shutdown()
}

@Test func inactiveRuntimeDefersRemoteRefreshUntilActivated() async throws {
    let locator = AlbumNodeIdentifier(volumeID: "additional-volume", nodeID: "album")
    let remoteUID = PhotoUID(volumeID: "additional-volume", nodeID: "remote-photo")
    let backend = RetryOnceLibrarySourceBackend(
        locator: locator,
        item: LibrarySourceItem(
            item: PhotoItem(
                uid: remoteUID,
                captureTime: Date(timeIntervalSince1970: 1),
                mediaType: "image/jpeg"
            ),
            knownFields: [.captureTime, .mediaType]
        )
    )
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-inactive-refresh-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-inactive-refresh", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let universe = MLAssetUniverse()
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: universe,
        retryDelays: [.zero],
        initiallyActive: false,
        onAssetsChanged: {}
    )

    #expect(
        await runtime.start(
            primaryItems: [],
            authority: .authoritative,
            generation: 1
        )
    )
    await runtime.refresh()
    #expect(await backend.discoveryCalls == 0)

    await runtime.setActive(true)
    for _ in 0..<10_000 {
        if await backend.discoveryCalls >= 2, universe.snapshot().uids == [remoteUID] { break }
        await Task.yield()
    }

    #expect(await backend.discoveryCalls == 2)
    #expect(universe.snapshot().isAuthoritative)
    #expect(universe.snapshot().uids == [remoteUID])
    await runtime.shutdown()
    await coordinator.shutdown()
}

@Test func becomingInactiveCancelsAndJoinsTheCoordinatorOwnedRefresh() async throws {
    let backend = CancellationDeferredLibrarySourceBackend()
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-inactive-barrier-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-inactive-barrier", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: MLAssetUniverse(),
        onAssetsChanged: {}
    )

    #expect(await runtime.start())
    while await !backend.isDiscoveryWaiting() { await Task.yield() }

    let completion = CompletionProbe()
    let suspension = Task {
        await runtime.setActive(false)
        completion.markCompleted()
    }
    for _ in 0..<1_000 where !backend.cancellationWasObserved {
        await Task.yield()
    }

    #expect(backend.cancellationWasObserved)
    #expect(!completion.isCompleted)
    await backend.releaseDiscovery()
    await suspension.value
    #expect(completion.isCompleted)
    await runtime.shutdown()
    await coordinator.shutdown()
}

@Test func transientDiscoveryFailureRetriesWithoutAnotherHostEvent() async throws {
    let locator = AlbumNodeIdentifier(volumeID: "additional-volume", nodeID: "album")
    let remoteUID = PhotoUID(volumeID: "additional-volume", nodeID: "remote-photo")
    let backend = RetryOnceLibrarySourceBackend(
        locator: locator,
        item: LibrarySourceItem(
            item: PhotoItem(
                uid: remoteUID,
                captureTime: Date(timeIntervalSince1970: 1),
                mediaType: "image/jpeg"
            ),
            knownFields: [.captureTime, .mediaType]
        )
    )
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-refresh-retry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-refresh-retry", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let universe = MLAssetUniverse()
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: universe,
        retryDelays: [.zero],
        onAssetsChanged: {}
    )

    #expect(
        await runtime.start(
            primaryItems: [],
            authority: .authoritative,
            generation: 1
        )
    )
    for _ in 0..<10_000 {
        if await backend.discoveryCalls >= 2, universe.snapshot().uids == [remoteUID] { break }
        await Task.yield()
    }

    #expect(await backend.discoveryCalls == 2)
    #expect(universe.snapshot().isAuthoritative)
    #expect(universe.snapshot().uids == [remoteUID])
    await runtime.shutdown()
    await coordinator.shutdown()
}

@Test func failedCacheCleanupPausesWhileInactiveAndRetriesTheSameAuthoritativeScope() async throws {
    let backend = FakeLibrarySourceBackend(locators: [], itemsByAlbum: [:])
    let coordinator = LibrarySourceCoordinator(
        remote: backend,
        thumbnailLoader: backend,
        inventoryStore: nil
    )
    await coordinator.prepare()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-source-cache-retry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ThumbnailCache(namespace: "runtime-cache-retry", rootDirectory: root)
    cache.configure(accountUID: "account", key: SymmetricKey(size: .bits256))
    let orphan = PhotoUID(volumeID: "removed-volume", nodeID: "removed-photo")
    let writer = cache.captureWriterGeneration()
    #expect(
        cache.storeToDisk(
            Data("encrypted-cache-input".utf8),
            for: orphan,
            ifCurrent: writer
        ) == .stored
    )
    let feed = ThumbnailFeedCore(cache: cache, loader: coordinator)
    await feed.setPrefetchEnabled(false)
    let runtime = LibrarySourceAnalysisRuntime(
        coordinator: coordinator,
        feed: feed,
        assets: MLAssetUniverse(),
        retryDelays: [.milliseconds(100), .seconds(1)],
        onAssetsChanged: {}
    )
    #expect(await runtime.start())
    await runtime.refresh()

    let cacheDirectory = cache.diskURL(for: orphan).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
    }

    await runtime.replacePrimaryInventory([], authority: .authoritative)
    #expect(FileManager.default.fileExists(atPath: cache.diskURL(for: orphan).path))
    await runtime.setActive(false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
    try await Task.sleep(for: .milliseconds(150))
    #expect(
        FileManager.default.fileExists(atPath: cache.diskURL(for: orphan).path),
        "inactive runtimes must not perform scheduled cleanup retries"
    )

    await runtime.setActive(true)
    for _ in 0..<300 {
        if !FileManager.default.fileExists(atPath: cache.diskURL(for: orphan).path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!FileManager.default.fileExists(atPath: cache.diskURL(for: orphan).path))
    await runtime.shutdown()
    await coordinator.shutdown()
}

private actor FakeLibrarySourceBackend: LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader {
    let locators: [AlbumNodeIdentifier]
    let itemsByAlbum: [String: [LibrarySourceItem]]

    init(
        locators: [AlbumNodeIdentifier],
        itemsByAlbum: [String: [LibrarySourceItem]]
    ) {
        self.locators = locators
        self.itemsByAlbum = itemsByAlbum
    }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        locators
    }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        itemsByAlbum["\(album.volumeID)~\(album.nodeID)"] ?? []
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids { onLoaded(uid, Data("thumbnail".utf8)) }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadThumbnails(for: uids, onLoaded: onLoaded)
    }
}

private actor RetryOnceLibrarySourceBackend: LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader {
    private let locator: AlbumNodeIdentifier
    private let item: LibrarySourceItem
    private(set) var discoveryCalls = 0

    init(locator: AlbumNodeIdentifier, item: LibrarySourceItem) {
        self.locator = locator
        self.item = item
    }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        discoveryCalls += 1
        if discoveryCalls == 1 { throw RetryOnceLibrarySourceBackendError.transient }
        return [locator]
    }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        album == locator ? [item] : []
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids { onLoaded(uid, Data("thumbnail".utf8)) }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadThumbnails(for: uids, onLoaded: onLoaded)
    }
}

private enum RetryOnceLibrarySourceBackendError: Error {
    case transient
}

private actor NotificationCounter {
    private var value = 0

    func increment() {
        value += 1
    }
}

private actor CancellationDeferredLibrarySourceBackend:
    LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader
{
    private let cancellation = CompletionProbe()
    private var discoveryContinuation: CheckedContinuation<Void, Never>?

    nonisolated var cancellationWasObserved: Bool { cancellation.isCompleted }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                discoveryContinuation = continuation
            }
        } onCancel: { [cancellation] in
            cancellation.markCompleted()
        }
        try Task.checkCancellation()
        return []
    }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        []
    }

    func isDiscoveryWaiting() -> Bool {
        discoveryContinuation != nil
    }

    func releaseDiscovery() {
        discoveryContinuation?.resume()
        discoveryContinuation = nil
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult()
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}

private final class ThumbnailDeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoUID: Data] = [:]

    func record(uid: PhotoUID, data: Data) {
        lock.withLock { values[uid] = data }
    }

    func data(for uid: PhotoUID) -> Data? {
        lock.withLock { values[uid] }
    }
}
