import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class PendingBackupCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var store: PendingBackupManifestStore!
    private var recorder: PendingBackupEventRecorder!
    private var metadata: FakePendingMetadata!
    private var effects: FakePendingEffects!
    private var coordinator: PendingBackupCoordinator!
    private let date = Date(timeIntervalSince1970: 1_750_000_000.75)
    private let revision = UploadBackupRevision(rawValue: 9)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-coordinator-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let storeURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        recorder = PendingBackupEventRecorder(store: store, now: { [date] in date })
        metadata = FakePendingMetadata()
        effects = FakePendingEffects()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        await coordinator.close()
        recorder.finish()
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        checkmarkDuration: Duration = .seconds(60),
        uncheckedAdmissionLimit: Int = 64
    ) -> PendingBackupCoordinator {
        PendingBackupCoordinator(
            store: store,
            queues: [.photoLibraryAsset: queue],
            metadataProvider: metadata,
            effects: effects,
            recorder: recorder,
            configuration: .init(
                membershipInterval: .zero,
                progressInterval: .milliseconds(1),
                doneLinger: .milliseconds(20),
                checkmarkDuration: checkmarkDuration,
                uncheckedAdmissionLimit: uncheckedAdmissionLimit
            ),
            now: { [date] in date }
        )
    }

    private func source(_ id: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary)
    }

    private func key(_ id: String) -> PendingSourceKey {
        PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
    }

    private func enqueue(_ id: String, state: UploadBackupSyncQueueState, captureOffset: TimeInterval = 0) {
        metadata.set(
            key(id),
            PendingPresentationMetadata(
                captureTime: date.addingTimeInterval(captureOffset),
                mediaType: "image/heic",
                displayName: "\(id).heic"
            ))
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision,
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: date
                )))
    }

    private func setState(_ id: String, _ state: UploadBackupSyncQueueState) {
        XCTAssertTrue(
            queue.updateState(
                source: source(id), revision: revision, state: state, attempts: nil, lastError: nil, updatedAt: date))
    }

    @discardableResult
    private func waitForSnapshot(
        _ description: String,
        _ predicate: @escaping @Sendable (PendingBackupSnapshot) -> Bool
    ) async -> PendingBackupSnapshot {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let snapshot = await coordinator.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(predicate(snapshot), description)
        return snapshot
    }

    private func tileIDs(_ snapshot: PendingBackupSnapshot) -> [String] {
        snapshot.tiles.map(\.key.identifier)
    }

    // MARK: - Admission

    func testFewNewPhotosShowAtOnceBeforeTheirCheck() async throws {
        enqueue("a", state: .discovered)
        enqueue("b", state: .discovered, captureOffset: 1)
        enqueue("c", state: .checking, captureOffset: 2)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["a", "b", "c"], "a few new photos show together, each with an empty ring")
        XCTAssertTrue(snapshot.tiles.allSatisfy { $0.badge == .waiting })
    }

    func testLargeScanShowsPhotosOnlyAfterTheirCheck() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 1)
        enqueue("shown", state: .discovered)
        await coordinator.start()
        await waitForSnapshot("a small scan shows at once") { $0.tiles.count == 1 }

        // A large scan (a first backup, or a second device of an iCloud library) waits for each check, so copies
        // of photos already in Proton never flood the grid. The tile that already showed stays.
        for id in ["x", "y", "z"] { enqueue(id, state: .discovered, captureOffset: 5) }
        try await Task.sleep(for: .milliseconds(100))
        let large = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(large), ["shown"])

        recorder.recordUploadEvidence(source: source("x"), revision: revision)
        await waitForSnapshot("evidence admits a checked photo") {
            Set($0.tiles.map(\.key.identifier)) == ["shown", "x"]
        }
    }

    func testUncheckedPhotoShowsOnceItsCheckPassed() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 0)
        enqueue("fresh", state: .discovered)
        await coordinator.start()
        let initial = await coordinator.currentSnapshot()
        XCTAssertTrue(initial.tiles.isEmpty, "an unchecked photo of a large scan can be a copy of a Proton photo")

        recorder.recordUploadEvidence(source: source("fresh"), revision: revision)
        let snapshot = await waitForSnapshot("evidence admits the tile") { $0.tiles.count == 1 }
        let tile = try XCTUnwrap(snapshot.tiles.first)
        XCTAssertEqual(tile.item.uid, PhotoUID(localPending: .photoLibrary, identifier: "fresh"))
        XCTAssertEqual(tile.badge, .waiting)
        XCTAssertEqual(
            tile.item.captureTime.timeIntervalSince1970, 1_750_000_000,
            "the capture time is floored to whole seconds, as Proton stores it")
    }

    func testCheckedStatesShowWithoutStoredEvidence() async {
        enqueue("queued", state: .queuedForUpload)
        enqueue("dup", state: .alreadyBackedUp)
        enqueue("gone", state: .skippedRemoteDeletion)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["queued"])
    }

    func testPhotoSavedByTheAppNeverShows() async {
        enqueue("saved", state: .queuedForUpload)
        await coordinator.start()
        await coordinator.recordSavedFromApp(localIdentifier: "saved", remote: PhotoUID(volumeID: "v", nodeID: "n"))
        await waitForSnapshot("a saved photo leaves the grid") { $0.tiles.isEmpty }
    }

    func testInaccessiblePhotoNeverShows() async {
        enqueue("hidden", state: .queuedForUpload)
        metadata.remove(key("hidden"))
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.tiles.isEmpty)
    }

    func testTilesFollowTimelineOrder() async {
        enqueue("late", state: .queuedForUpload, captureOffset: 60)
        enqueue("early", state: .queuedForUpload, captureOffset: -60)
        enqueue("middle", state: .queuedForUpload)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["early", "middle", "late"])

        enqueue("first", state: .queuedForUpload, captureOffset: -120)
        await waitForSnapshot("an incremental insert keeps the order") {
            $0.tiles.map(\.key.identifier) == ["first", "early", "middle", "late"]
        }
    }

    // MARK: - Progress and handoff

    func testProgressUpdatesOnlyTheProgressMap() async throws {
        enqueue("up", state: .uploading)
        await coordinator.start()
        let before = await coordinator.currentSnapshot()

        recorder.reportProgress(source: source("up"), revision: revision, step: 7)
        let during = await waitForSnapshot("the step arrives") { !$0.progress.isEmpty }
        XCTAssertEqual(during.membershipRevision, before.membershipRevision, "progress must not rebuild tiles")
        let tile = try XCTUnwrap(during.tiles.first)
        XCTAssertEqual(during.badge(for: tile), .uploading(step: 7))

        recorder.reportProgress(source: source("up"), revision: revision, step: nil)
        await waitForSnapshot("the progress ends") { $0.progress.isEmpty }
    }

    func testSettledSourceRetiresOnlyAfterItsProtonPhotoIsListed() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-done")
        recorder.recordHandoff(source: source("done"), revision: revision, remote: remote, kind: .uploaded)
        setState("done", .completed)

        let settled = await waitForSnapshot("the tile shows the checkmark") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(settled.tiles.first?.badge, .done)
        XCTAssertEqual(settled.tiles.first?.handoff, remote)

        await coordinator.noteRemotePresence([key("done")])
        await waitForSnapshot("the tile retires after the checkmark lingered") { $0.tiles.isEmpty }
        XCTAssertTrue(store.unacknowledgedHandoffs().isEmpty)
    }

    func testSettledRowKeepsItsTileBeforeTheHandoffEventArrives() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        await waitForSnapshot("uploading") { $0.tiles.count == 1 }
        // The runner writes the handoff first; its event travels on another stream than the queue change.
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-done")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key("done"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        setState("done", .completed)

        let settled = await waitForSnapshot("the tile keeps its place") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(tileIDs(settled), ["done"], "a settled row must never hide its tile for a moment")
        XCTAssertEqual(settled.tiles.first?.handoff, remote)
    }

    func testNewRevisionKeepsItsTileWhileItsMetadataLoads() async throws {
        enqueue("p", state: .uploading)
        await coordinator.start()
        await waitForSnapshot("shown") { $0.tiles.count == 1 }

        // The camera finished processing the photo: a new revision arrives before the catalog knows it.
        metadata.remove(key("p"))
        let finished = UploadBackupRevision(rawValue: 10)
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("p"), revision: finished, originalFilename: "p.heic", state: .discovered,
                    updatedAt: date)))
        await waitForSnapshot("the tile follows the new revision") { $0.tiles.first?.revision == finished }
        for _ in 0..<20 {
            let snapshot = await coordinator.currentSnapshot()
            XCTAssertEqual(tileIDs(snapshot), ["p"], "the tile must never leave while its metadata loads")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCheckmarkShowsOnlyBriefly() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(checkmarkDuration: .milliseconds(30))
        enqueue("done", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("done"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "l"), kind: .uploaded)
        setState("done", .completed)
        await waitForSnapshot("the checkmark shows") { $0.tiles.first?.badge == .done }
        let later = await waitForSnapshot("then the tile shows no badge") { $0.tiles.first?.badge == .backedUp }
        XCTAssertEqual(tileIDs(later), ["done"], "the tile stays until its Proton photo takes over")
    }

    func testPhotoDeletedInApplePhotosLeavesTheGrid() async throws {
        enqueue("gone", state: .queuedForUpload)
        enqueue("kept", state: .queuedForUpload)
        await coordinator.start()
        await waitForSnapshot("both show") { $0.tiles.count == 2 }

        await coordinator.noteSourcesMissing([
            PhotoUID(localPending: .photoLibrary, identifier: "gone"), PhotoUID(volumeID: "vol", nodeID: "remote"),
        ])
        let snapshot = await waitForSnapshot("the deleted photo leaves") { $0.tiles.count == 1 }
        XCTAssertEqual(tileIDs(snapshot), ["kept"])
    }

    func testUnlistedHandoffSurvivesARestart() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("done"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "l"), kind: .uploaded)
        setState("done", .completed)
        await waitForSnapshot("settled") { $0.tiles.first?.isSettled == true }
        await coordinator.close()
        recorder.finish()

        // A relaunch builds a new recorder and coordinator over the same stores.
        recorder = PendingBackupEventRecorder(store: store, now: { [date] in date })
        coordinator = makeCoordinator()
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["done"], "a completed photo whose Proton photo is not listed stays")
    }

    // MARK: - Delete and restore

    func testDeleteRemovesFromBackupAndRestoreReturnsIt() async throws {
        enqueue("pick", state: .queuedForUpload)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "pick")

        let excluded = await coordinator.exclude([uid])
        XCTAssertTrue(excluded)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.tiles.isEmpty)
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [uid])
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [uid])
        XCTAssertEqual(effects.removed, [["pick"]])
        XCTAssertEqual(store.sourceState(for: key("pick"))?.needsQueueSync, false)

        let restored = await coordinator.restore([uid])
        XCTAssertTrue(restored)
        XCTAssertEqual(effects.returned, [[key("pick")]])
        snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty)
        XCTAssertNil(store.sourceState(for: key("pick")), "a finished restore leaves no state behind")
    }

    func testDeleteOfACommittedUploadTrashesTheProtonPhoto() async throws {
        enqueue("sent", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("sent"), revision: revision, remote: PhotoUID(volumeID: "", nodeID: "link-sent"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }

        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "sent")])

        XCTAssertEqual(effects.trashed, [[PhotoUID(volumeID: "photos-volume", nodeID: "link-sent")]])
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty, "the Proton trash entry represents the photo")
        XCTAssertEqual(store.sourceState(for: key("sent"))?.remoteTrashed, true)
    }

    func testCommitThatRacesADeleteMovesThePhotoToTheTrash() async throws {
        enqueue("race", state: .uploading)
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "race")])
        XCTAssertTrue(effects.trashed.isEmpty)

        let outcome = recorder.recordHandoff(
            source: source("race"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "late"),
            kind: .uploaded)
        XCTAssertEqual(outcome, .excludedRemoteNeedsTrash)
        let deadline = ContinuousClock.now + .seconds(5)
        while effects.trashed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.trashed, [[PhotoUID(volumeID: "vol", nodeID: "late")]])
    }

    func testFailedRemovalStaysDueAndRetries() async throws {
        enqueue("stuck", state: .queuedForUpload)
        effects.removeSucceeds = false
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "stuck")])
        let state = try XCTUnwrap(store.sourceState(for: key("stuck")))
        XCTAssertTrue(state.needsQueueSync, "a failed removal must never be forgotten")
        XCTAssertEqual(state.attempts, 1)
    }

    func testTrashListRemovalKeepsThePhotoExcluded() async throws {
        enqueue("bin", state: .queuedForUpload)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "bin")
        await coordinator.exclude([uid])

        let removed = await coordinator.removeFromTrashList([uid])
        XCTAssertTrue(removed)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty)
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [uid])
    }

    // MARK: - Deferred actions

    func testFavoriteOnAPendingPhotoAppliesAfterItsProtonPhotoIsListed() async throws {
        enqueue("fav", state: .uploading)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "fav")
        let stored = await coordinator.setFavorite([uid], favorite: true)
        XCTAssertTrue(stored)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.favoriteIntents[uid], true, "the heart shows at once")

        recorder.recordHandoff(
            source: source("fav"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "fav-link"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        await coordinator.noteRemotePresence([key("fav")])

        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "fav-link")])
        XCTAssertTrue(store.actions().isEmpty)
    }

    func testActionRunsAfterTheCommitWithoutWaitingForTheGrid() async throws {
        enqueue("quiet", state: .uploading)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "quiet")
        _ = await coordinator.setFavorite([uid], favorite: true)
        recorder.recordHandoff(
            source: source("quiet"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "q"),
            kind: .uploaded)

        let deadline = ContinuousClock.now + .seconds(5)
        while effects.favorites.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "q")])
    }

    func testRestoreResumesAnActionThatWaitedWhileExcluded() async throws {
        enqueue("paused", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("paused"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "p"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "paused")
        await coordinator.exclude([uid])
        _ = await coordinator.setFavorite([uid], favorite: true)
        XCTAssertTrue(effects.favorites.isEmpty, "an excluded photo receives no deferred action")

        await coordinator.restore([uid])
        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "p")])
    }

    func testRestoreBringsTheProtonPhotoBackBeforeTheBackupSeesIt() async throws {
        enqueue("back", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("back"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "b"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "back")
        await coordinator.exclude([uid])
        XCTAssertEqual(effects.trashed.count, 1)

        await coordinator.restore([uid])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
    }

    func testRetryableActionFailureKeepsTheAction() async throws {
        enqueue("album", state: .uploading)
        effects.albumResult = .retry
        await coordinator.start()
        _ = await coordinator.addToAlbum([PhotoUID(localPending: .photoLibrary, identifier: "album")], albumID: "a1")
        recorder.recordHandoff(
            source: source("album"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "x"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        await coordinator.noteRemotePresence([key("album")])

        let action = try XCTUnwrap(store.actions().first)
        XCTAssertFalse(action.failed)
        XCTAssertEqual(action.attempts, 1)
    }
}

private final class FakePendingMetadata: PendingSourceMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PendingSourceKey: PendingPresentationMetadata] = [:]

    func set(_ key: PendingSourceKey, _ value: PendingPresentationMetadata) {
        lock.withLock { values[key] = value }
    }

    func remove(_ key: PendingSourceKey) {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        lock.withLock { values.filter { keys.contains($0.key) } }
    }
}

private final class FakePendingEffects: PendingBackupEffects, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [[String]] = []
    private var _returned: [[PendingSourceKey]] = []
    private var _trashed: [[PhotoUID]] = []
    private var _favorites: [PhotoUID] = []
    private var _removeSucceeds = true
    private var _albumResult = PendingEffectResult.done
    private var _order: [String] = []

    var order: [String] { lock.withLock { _order } }

    var removed: [[String]] { lock.withLock { _removed } }
    var returned: [[PendingSourceKey]] { lock.withLock { _returned } }
    var trashed: [[PhotoUID]] { lock.withLock { _trashed } }
    var favorites: [PhotoUID] { lock.withLock { _favorites } }
    var removeSucceeds: Bool {
        get { lock.withLock { _removeSucceeds } }
        set { lock.withLock { _removeSucceeds = newValue } }
    }
    var albumResult: PendingEffectResult {
        get { lock.withLock { _albumResult } }
        set { lock.withLock { _albumResult = newValue } }
    }

    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        lock.withLock {
            _removed.append(identifiers.sorted())
            return _removeSucceeds
        }
    }

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool {
        lock.withLock {
            _returned.append(keys.sorted())
            _order.append("return")
        }
        return true
    }

    func photosVolumeID() async -> String? { "photos-volume" }

    func trashRemote(_ uids: [PhotoUID]) async -> PendingEffectResult {
        lock.withLock {
            _trashed.append(uids)
            _order.append("trash")
        }
        return .done
    }

    func restoreRemote(_ uids: [PhotoUID]) async -> PendingEffectResult {
        lock.withLock { _order.append("restore") }
        return .done
    }

    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        lock.withLock { _favorites.append(uid) }
        return .done
    }

    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        lock.withLock { _albumResult }
    }
}
