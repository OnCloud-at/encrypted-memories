import AlbumCore
import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Library source coordinator")
struct LibrarySourceCoordinatorTests {
    @Test func additionalInventoryParticipatesInAnalysisButNotThePrimaryProjection() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([
            AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album"): [Self.item(remoteUID)]
        ])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        let primaryUID = PhotoUID(volumeID: "primary-volume", nodeID: "primary-photo")
        await coordinator.replacePrimaryInventory([
            PhotoItem(
                uid: primaryUID,
                captureTime: Date(timeIntervalSince1970: 1),
                mediaType: "image/jpeg"
            )
        ], authority: .authoritative)

        await coordinator.refresh()

        let change = try #require(await recorder.latest())
        #expect(change.selectedScope.uids == [primaryUID])
        #expect(change.analysisScope.uids == [primaryUID, remoteUID])
        #expect(change.thumbnailRetentionScope.uids == [primaryUID, remoteUID])
        #expect(change.selectedProjection.timeline.uids == [primaryUID])
        await coordinator.shutdown()
    }

    @Test func removedSourceRejectsThumbnailBytesWhichArriveAfterRevocation() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend(blockThumbnailLoads: true)
        await backend.setSources([
            AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album"): [Self.item(remoteUID)]
        ])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        await coordinator.refresh()
        let delivered = ThumbnailDeliveryRecorder()
        let load = Task {
            await coordinator.loadThumbnails(for: [remoteUID]) { uid, data in
                delivered.store(data, for: uid)
            }
        }
        while await !backend.isThumbnailLoadWaiting() {
            await Task.yield()
        }

        await backend.setSources([:])
        await coordinator.refresh()
        await backend.releaseThumbnailLoad()
        let result = await load.value

        #expect(delivered.data(for: remoteUID) == nil)
        #expect(result.itemErrors[remoteUID] == "source authorization changed")
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossImmediatelyRemovesDerivedDataMembership() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        #expect(await recorder.latest()?.analysisScope.uids == [remoteUID])

        await coordinator.revokeAdditionalSource(for: locator)

        let revoked = try #require(await recorder.latest())
        #expect(revoked.analysisScope.uids.isEmpty)
        #expect(revoked.analysisScope.isAuthoritative)
        #expect(revoked.thumbnailRetentionScope.uids.isEmpty)
        #expect(revoked.orphanedUIDs == [remoteUID])
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossRejectsAnInFlightInventoryResult() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        await backend.blockNextItemEnumeration(for: locator)
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)

        let refresh = Task { await coordinator.refresh() }
        while await !backend.isItemEnumerationWaiting() {
            await Task.yield()
        }

        await coordinator.revokeAdditionalSource(for: locator)
        await backend.releaseItemEnumeration()
        await refresh.value

        let change = try #require(await recorder.latest())
        #expect(change.analysisScope.uids.isEmpty)
        #expect(change.analysisScope.isAuthoritative)
        #expect(change.thumbnailRetentionScope.uids.isEmpty)
        #expect(!change.analysisScope.sourceIDs.contains(where: { $0.rawValue.hasPrefix("additional:") }))
        #expect(await backend.itemEnumerationCalls == 1)
        await coordinator.shutdown()
    }

    @Test func unchangedAndTransientRefreshesDoNotRepublishConsumerWork() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        #expect(await coordinator.refresh() == .complete)
        let baseline = await recorder.count()

        #expect(await coordinator.refresh() == .complete)
        #expect(await recorder.count() == baseline)

        await backend.setDiscoveryFailure(true)
        #expect(await coordinator.refresh() == .retryableFailure)
        #expect(await recorder.count() == baseline)

        await backend.setDiscoveryFailure(false)
        #expect(await coordinator.refresh() == .complete)
        #expect(await recorder.count() == baseline)

        let addedUID = PhotoUID(volumeID: "remote-volume", nodeID: "added-photo")
        await backend.setSources([locator: [Self.item(remoteUID), Self.item(addedUID)]])
        await coordinator.refresh()
        #expect(await recorder.count() == baseline + 1)
        let latest = try #require(await recorder.latest())
        #expect(latest.analysisScope.uids.contains(addedUID))
        await coordinator.shutdown()
    }

    @Test func cancelledCallerCannotAdmitANewRemoteRefresh() async {
        let backend = ControlledLibrarySourceBackend()
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let admission = CancelledTaskAdmissionGate()
        let refresh = Task {
            await admission.wait()
            await coordinator.refresh()
        }
        while await !admission.isWaiting { await Task.yield() }

        refresh.cancel()
        await admission.release()
        await refresh.value

        #expect(await backend.discoveryCalls == 0)
        await coordinator.shutdown()
    }

    @Test func refreshRequestedWhileARefreshIsActiveRunsOneCoalescedFollowUp() async throws {
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        await backend.blockNextItemEnumeration(for: locator)
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()

        let first = Task { await coordinator.refresh() }
        while await !backend.isItemEnumerationWaiting() { await Task.yield() }
        let secondStarted = SynchronousCompletionProbe()
        let second = Task {
            secondStarted.markCompleted()
            return await coordinator.refresh()
        }
        while !secondStarted.isCompleted { await Task.yield() }
        // Give the already-unblocked coordinator actor a scheduling turn before the remote result resumes.
        try await Task.sleep(for: .milliseconds(10))
        await backend.releaseItemEnumeration()

        #expect(await first.value == .complete)
        #expect(await second.value == .complete)
        #expect(await backend.discoveryCalls == 2)
        #expect(await backend.itemEnumerationCalls == 2)
        await coordinator.shutdown()
    }

    @Test func oneFinalRefreshProjectionPreservesLastReferenceRemoval() async throws {
        let removedUID = PhotoUID(volumeID: "remote-volume", nodeID: "removed-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(removedUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        let baselineCount = await recorder.count()

        await backend.setSources([locator: []])
        await coordinator.refresh()

        let change = try #require(await recorder.latest())
        #expect(await recorder.count() == baselineCount + 1)
        #expect(change.analysisScope.uids.isEmpty)
        #expect(change.analysisScope.isAuthoritative)
        #expect(change.orphanedUIDs == [removedUID])
        await coordinator.shutdown()
    }

    @Test func membershipFailurePublishesAuthorityDowngradeAndRetainsCachedIdentity() async throws {
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])
        let coordinator = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: nil
        )
        await coordinator.prepare()
        let recorder = LibrarySourceChangeRecorder()
        _ = await coordinator.attach { change in await recorder.store(change) }
        await coordinator.replacePrimaryInventory([], authority: .authoritative)
        await coordinator.refresh()
        let baseline = await recorder.count()

        await backend.setItemEnumerationFailure(true)
        await coordinator.refresh()

        let degraded = try #require(await recorder.latest())
        #expect(await recorder.count() == baseline + 1)
        #expect(degraded.analysisScope.uids == [remoteUID])
        #expect(!degraded.analysisScope.isAuthoritative)

        await backend.setItemEnumerationFailure(false)
        await coordinator.refresh()
        #expect(await recorder.count() == baseline + 2)
        #expect(await recorder.latest()?.analysisScope.isAuthoritative == true)
        await coordinator.shutdown()
    }

    @Test func confirmedAccessLossRemainsFencedAcrossRestartUntilRemoteAbsence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EncryptedMemories-SourceCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(data: Data(repeating: 0x31, count: 32))
        let remoteUID = PhotoUID(volumeID: "remote-volume", nodeID: "remote-photo")
        let locator = AlbumNodeIdentifier(volumeID: "remote-volume", nodeID: "album")
        let backend = ControlledLibrarySourceBackend()
        await backend.setSources([locator: [Self.item(remoteUID)]])

        let first = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await first.prepare()
        await first.replacePrimaryInventory([], authority: .authoritative)
        await first.refresh()
        #expect(await backend.itemEnumerationCalls == 1)
        let persistenceBarrier = BlockingLibrarySourceChangeSink()
        _ = await first.attach { change in await persistenceBarrier.receive(change) }
        await persistenceBarrier.blockNextChange()
        let revoke = Task { await first.revokeAdditionalSource(for: locator) }
        while await !persistenceBarrier.isWaiting { await Task.yield() }
        let shutdownCompleted = SynchronousCompletionProbe()
        let shutdown = Task {
            await first.shutdown()
            shutdownCompleted.markCompleted()
        }
        for _ in 0..<1_000 where !shutdownCompleted.isCompleted { await Task.yield() }
        #expect(!shutdownCompleted.isCompleted)

        await persistenceBarrier.release()
        await revoke.value
        await shutdown.value
        #expect(shutdownCompleted.isCompleted)

        let second = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await second.prepare()
        let secondRecorder = LibrarySourceChangeRecorder()
        _ = await second.attach { change in await secondRecorder.store(change) }
        await second.replacePrimaryInventory([], authority: .authoritative)
        await second.refresh()
        #expect(await secondRecorder.latest()?.analysisScope.uids.isEmpty == true)
        #expect(await backend.itemEnumerationCalls == 1)

        await backend.setSources([:])
        await second.refresh()
        await second.shutdown()

        await backend.setSources([locator: [Self.item(remoteUID)]])
        let third = LibrarySourceCoordinator(
            remote: backend,
            thumbnailLoader: backend,
            inventoryStore: LibrarySourceInventoryStore(
                directory: directory,
                accountUID: "account",
                encryptionKey: key
            )
        )
        await third.prepare()
        let thirdRecorder = LibrarySourceChangeRecorder()
        _ = await third.attach { change in await thirdRecorder.store(change) }
        await third.replacePrimaryInventory([], authority: .authoritative)
        await third.refresh()

        #expect(await thirdRecorder.latest()?.analysisScope.uids == [remoteUID])
        #expect(await backend.itemEnumerationCalls == 2)
        await third.shutdown()
    }

    private static func item(_ uid: PhotoUID) -> LibrarySourceItem {
        LibrarySourceItem(
            item: PhotoItem(
                uid: uid,
                captureTime: Date(timeIntervalSince1970: 2),
                mediaType: ""
            ),
            knownFields: [.captureTime]
        )
    }
}

private actor ControlledLibrarySourceBackend: LibrarySourceRemoteBackend, PriorityThumbnailBatchLoader {
    private var sources: [AlbumNodeIdentifier: [LibrarySourceItem]] = [:]
    private var discoveryFails = false
    private var itemEnumerationFails = false
    private(set) var discoveryCalls = 0
    private(set) var itemEnumerationCalls = 0
    private var blockedItemEnumeration: AlbumNodeIdentifier?
    private var itemEnumerationContinuation: CheckedContinuation<Void, Never>?
    private let blockThumbnailLoads: Bool
    private var thumbnailContinuation: CheckedContinuation<Void, Never>?

    init(blockThumbnailLoads: Bool = false) {
        self.blockThumbnailLoads = blockThumbnailLoads
    }

    func setSources(_ sources: [AlbumNodeIdentifier: [LibrarySourceItem]]) {
        self.sources = sources
    }

    func setDiscoveryFailure(_ fails: Bool) {
        discoveryFails = fails
    }

    func setItemEnumerationFailure(_ fails: Bool) {
        itemEnumerationFails = fails
    }

    func blockNextItemEnumeration(for locator: AlbumNodeIdentifier) {
        blockedItemEnumeration = locator
    }

    func librarySourceLocators() async throws -> [AlbumNodeIdentifier] {
        discoveryCalls += 1
        if discoveryFails { throw ControlledLibrarySourceBackendError.discoveryFailed }
        return sources.keys.sorted {
            if $0.volumeID != $1.volumeID { return $0.volumeID < $1.volumeID }
            return $0.nodeID < $1.nodeID
        }
    }

    func librarySourceItems(for album: AlbumNodeIdentifier) async throws -> [LibrarySourceItem] {
        itemEnumerationCalls += 1
        if blockedItemEnumeration == album {
            blockedItemEnumeration = nil
            await withCheckedContinuation { continuation in
                itemEnumerationContinuation = continuation
            }
        }
        if itemEnumerationFails { throw ControlledLibrarySourceBackendError.itemEnumerationFailed }
        return sources[album] ?? []
    }

    func isItemEnumerationWaiting() -> Bool {
        itemEnumerationContinuation != nil
    }

    func releaseItemEnumeration() {
        itemEnumerationContinuation?.resume()
        itemEnumerationContinuation = nil
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        if blockThumbnailLoads {
            await withCheckedContinuation { continuation in
                thumbnailContinuation = continuation
            }
        }
        for uid in uids {
            onLoaded(uid, Data("thumbnail".utf8))
        }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        await loadThumbnails(for: uids, onLoaded: onLoaded)
    }

    func isThumbnailLoadWaiting() -> Bool {
        thumbnailContinuation != nil
    }

    func releaseThumbnailLoad() {
        thumbnailContinuation?.resume()
        thumbnailContinuation = nil
    }
}

private actor CancelledTaskAdmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LibrarySourceChangeRecorder {
    private var changes: [LibrarySourceChange] = []

    func store(_ change: LibrarySourceChange) {
        changes.append(change)
    }

    func latest() -> LibrarySourceChange? {
        changes.last
    }

    func count() -> Int {
        changes.count
    }
}

private actor BlockingLibrarySourceChangeSink {
    private var shouldBlockNextChange = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func blockNextChange() {
        shouldBlockNextChange = true
    }

    func receive(_ change: LibrarySourceChange) async {
        _ = change
        guard shouldBlockNextChange else { return }
        shouldBlockNextChange = false
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ControlledLibrarySourceBackendError: Error {
    case discoveryFailed
    case itemEnumerationFailed
}

private final class ThumbnailDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoUID: Data] = [:]

    func store(_ data: Data, for uid: PhotoUID) {
        lock.withLock { values[uid] = data }
    }

    func data(for uid: PhotoUID) -> Data? {
        lock.withLock { values[uid] }
    }
}

private final class SynchronousCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}
