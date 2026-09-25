import Foundation
import MediaFeedCore
import Observation
import PhotosCore
import TimelineCore
import UploadCore

/// One account's pending grid, shared by iOS, iPadOS and macOS: the pending store, the coordinator that
/// follows the backup queue, and the presenter that merges pending photos into the timeline.
///
/// Hosts create the store first and hand it to `PhotoLibraryBackupController`, then build this session. They
/// attach their thumbnail feed, feed the session the canonical Proton timeline, show `presenter.current` in
/// the grid and viewer, and forward deletes, restores, favorites and album adds of local photos.
@MainActor
public final class PendingGridSession {
    public let presenter = PendingTimelinePresenter()
    /// The latest coordinator snapshot, including the trash and excluded lists.
    public private(set) var pendingSnapshot = PendingBackupSnapshot.empty
    /// Called after `pendingSnapshot` changed.
    public var onPendingChange: ((PendingBackupSnapshot) -> Void)?
    /// Local photos in "Zuletzt gelöscht" while pending photos show; empty otherwise.
    public private(set) var trash = PendingTrashPresentation.empty
    /// Excluded photos for the Backup settings list, newest deletion first; empty while pending photos do
    /// not show.
    public private(set) var excludedTiles: [PendingTile] = []
    /// Called after `trash` or `excludedTiles` changed.
    public var onListsChange: (() -> Void)?
    private var gridLocalUIDs = Set<PhotoUID>()
    /// The local photos the feed may load: the grid, "Zuletzt gelöscht" and the excluded list.
    private var authorizedLocalUIDs = Set<PhotoUID>()
    private var feed: ThumbnailFeedCore?
    /// Feed updates run in order, so an older authorization never replaces a newer one.
    private var feedUpdate: Task<Void, Never>?
    private weak var photoBackup: PhotoLibraryBackupController?

    private let coordinator: PendingBackupCoordinator
    private let volume: PhotosVolumeBox
    private var snapshotTask: Task<Void, Never>?
    private var isBackupEnabled = false
    private var started = false

    /// Opens the device-local pending store in the account data directory. Nil when it cannot open; backup
    /// then reports itself unavailable, because deleted pending photos could otherwise upload.
    public static func openStore(
        accountDataDirectory: URL, policy: LibraryDatabasePolicy
    ) -> PendingBackupManifestStore? {
        PendingBackupManifestStore(
            url: accountDataDirectory.appendingPathComponent(PendingBackupManifestStore.databaseFileName),
            policy: policy
        )
    }

    public init?(
        store: PendingBackupManifestStore,
        photoBackup: PhotoLibraryBackupController,
        remote: any PendingRemoteEffects
    ) {
        guard let recorder = photoBackup.pendingRecorder,
            let queue = photoBackup.pendingQueue,
            let metadata = photoBackup.pendingMetadataProvider
        else { return nil }
        let volume = PhotosVolumeBox()
        self.volume = volume
        coordinator = PendingBackupCoordinator(
            store: store,
            queues: [.photoLibraryAsset: queue],
            metadataProvider: metadata,
            effects: SessionEffects(photoBackup: photoBackup, remote: remote, volume: volume),
            recorder: recorder
        )
        self.photoBackup = photoBackup
        presenter.onRemotePresence = { [coordinator] keys in
            Task { await coordinator.noteRemotePresence(keys) }
        }
        presenter.onFeedUpdate = { [weak self] localUIDs, adoptions, revised in
            guard let self else { return }
            // Before the presentation reaches the grid, so its next upload reads the new content.
            if !revised.isEmpty { self.feed?.invalidateLocal(revised) }
            self.gridLocalUIDs = localUIDs
            self.publishFeedAuthorization(adoptions: adoptions)
        }
    }

    /// Lets `feed` load thumbnails of local photos from Apple Photos, and keeps its authorization current.
    /// `imageRequest` is the platform's `PhotoKitPlatformImages.request`.
    public func attachFeed(_ feed: ThumbnailFeedCore, imageRequest: @escaping PhotoKitImageRequest) {
        guard feed !== self.feed else { return }
        let previous = self.feed
        self.feed = feed
        let authorized = authorizedLocalUIDs
        enqueueFeedUpdate {
            if let previous { await Self.detach(previous) }
            await feed.setLocalThumbnailLoader(PhotoKitLocalThumbnailLoader(request: imageRequest))
            await feed.setLocalAuthorization(authorized)
        }
    }

    private func publishFeedAuthorization(adoptions: [(local: PhotoUID, remote: PhotoUID)] = []) {
        var nextAuthorized = gridLocalUIDs
        if isBackupEnabled {
            nextAuthorized.formUnion(pendingSnapshot.trashTiles.map(\.item.uid))
            nextAuthorized.formUnion(pendingSnapshot.excludedTiles.map(\.item.uid))
        }
        let authorized = nextAuthorized
        guard authorized != authorizedLocalUIDs || !adoptions.isEmpty else { return }
        authorizedLocalUIDs = authorized
        guard let feed else { return }
        // The Proton photo shows the decoded pending image until its own thumbnail arrives.
        enqueueFeedUpdate { await feed.setLocalAuthorization(authorized, adoptions: adoptions) }
    }

    private func enqueueFeedUpdate(_ work: @escaping @Sendable () async -> Void) {
        let previous = feedUpdate
        feedUpdate = Task {
            await previous?.value
            await work()
        }
    }

    private static func detach(_ feed: ThumbnailFeedCore) async {
        await feed.setLocalAuthorization([])
        await feed.setLocalThumbnailLoader(nil)
    }

    /// Follows the backup switch and availability of the controller: pending photos show only while backup
    /// is on and able to run.
    private func observeBackupState() {
        guard let photoBackup else { return }
        let enabled = withObservationTracking {
            photoBackup.isEnabled && photoBackup.isAvailable && photoBackup.accessState.allowsBackup
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeBackupState() }
        }
        setBackupEnabled(enabled)
    }

    public func start() {
        guard !started else { return }
        started = true
        observeBackupState()
        let coordinator = self.coordinator
        snapshotTask = Task { [weak self] in
            await coordinator.start()
            for await snapshot in coordinator.snapshots {
                guard let self else { return }
                let membershipChanged = snapshot.membershipRevision != self.pendingSnapshot.membershipRevision
                self.pendingSnapshot = snapshot
                self.presenter.setPending(snapshot, enabled: self.isBackupEnabled)
                // Progress ticks leave the lists unchanged; only membership changes can change authorization.
                if membershipChanged {
                    self.publishFeedAuthorization()
                    self.refreshLists()
                }
                self.onPendingChange?(snapshot)
            }
        }
    }

    /// The canonical whole-library Proton timeline.
    public func setRemote(_ snapshot: TimelineSnapshot) {
        if let volumeID = snapshot.items.first?.uid.volumeID { volume.set(volumeID) }
        presenter.setRemote(snapshot)
    }

    /// Pending photos show only while backup is on and able to run.
    private func setBackupEnabled(_ enabled: Bool) {
        guard enabled != isBackupEnabled else { return }
        isBackupEnabled = enabled
        presenter.setPending(pendingSnapshot, enabled: enabled)
        publishFeedAuthorization()
        refreshLists()
    }

    private func refreshLists() {
        let trashItems = isBackupEnabled ? pendingSnapshot.trashTiles.map(\.item) : []
        let excluded = isBackupEnabled ? pendingSnapshot.excludedTiles : []
        guard Set(trashItems.map(\.uid)) != trash.localUIDs || excluded != excludedTiles else { return }
        trash = PendingTrashPresentation(items: trashItems)
        excludedTiles = excluded
        onListsChange?()
    }

    /// Whether pending photos show now (backup on, available, and allowed to read the Photos library).
    public var isShowingPendingPhotos: Bool { isBackupEnabled }

    /// Favorites as the app shows them: Proton favorites plus the desired states of pending photos, which the
    /// backup applies after the upload.
    public func displayedFavorites(_ remote: Set<PhotoUID>) -> Set<PhotoUID> {
        let intents = pendingSnapshot.favoriteIntents
        guard !intents.isEmpty else { return remote }
        var result = remote
        for (uid, favorite) in intents {
            if favorite { result.insert(uid) } else { result.remove(uid) }
        }
        return result
    }

    // MARK: - Person actions on local photos

    @discardableResult
    public func delete(_ uids: [PhotoUID]) async -> Bool { await coordinator.exclude(uids) }

    @discardableResult
    public func restore(_ uids: [PhotoUID]) async -> Bool { await coordinator.restore(uids) }

    /// A Proton photo came back from the trash; a pending delete that trashed it is undone as well.
    public func restoreSources(ofRemote uids: [PhotoUID]) async { await coordinator.restoreSources(ofRemote: uids) }

    @discardableResult
    public func removeFromTrashList(_ uids: [PhotoUID]) async -> Bool { await coordinator.removeFromTrashList(uids) }

    @discardableResult
    public func setFavorite(_ uids: [PhotoUID], favorite: Bool) async -> Bool {
        await coordinator.setFavorite(uids, favorite: favorite)
    }

    @discardableResult
    public func addToAlbum(_ uids: [PhotoUID], albumID: String) async -> Bool {
        await coordinator.addToAlbum(uids, albumID: albumID)
    }

    public func recordSavedFromApp(localIdentifier: String, remote: PhotoUID) async {
        await coordinator.recordSavedFromApp(localIdentifier: localIdentifier, remote: remote)
    }

    public func close() async {
        snapshotTask?.cancel()
        snapshotTask = nil
        await coordinator.close()
        presenter.reset()
        pendingSnapshot = .empty
        gridLocalUIDs = []
        authorizedLocalUIDs = []
        trash = .empty
        excludedTiles = []
        onListsChange?()
        if let feed {
            self.feed = nil
            enqueueFeedUpdate { await Self.detach(feed) }
        }
        await feedUpdate?.value
        feedUpdate = nil
    }
}

/// The photos volume seen in the Proton timeline, for link-only handoffs.
private final class PhotosVolumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ volumeID: String) { lock.withLock { value = volumeID } }
    func get() -> String? { lock.withLock { value } }
}

private struct SessionEffects: PendingBackupEffects {
    let photoBackup: PhotoLibraryBackupController
    let remote: any PendingRemoteEffects
    let volume: PhotosVolumeBox

    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        guard kind == .photoLibraryAsset else { return true }
        return await photoBackup.removeFromBackup(identifiers: identifiers)
    }

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool {
        let identifiers = keys.filter { $0.kind == .photoLibraryAsset }.map(\.identifier)
        guard !identifiers.isEmpty else { return true }
        return await photoBackup.returnToBackup(identifiers: identifiers)
    }

    func photosVolumeID() async -> String? { volume.get() }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingEffectResult { await remote.trash(uids) }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingEffectResult { await remote.restore(uids) }

    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        await remote.setFavorite(uid, favorite: favorite)
    }

    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        await remote.addToAlbum(uid, albumID: albumID)
    }
}
