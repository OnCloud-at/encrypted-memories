import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class PendingBackupStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PendingBackupManifestStore!
    private let date = Date(timeIntervalSince1970: 1_750_000_000)
    private let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-1")
    private let remote = PhotoUID(volumeID: "vol", nodeID: "link-1")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-backup-store-\(UUID().uuidString)", isDirectory: true)
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    private func presentation(_ name: String = "IMG_0001.HEIC") -> PendingPresentationMetadata {
        PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: name)
    }

    // MARK: - Desired state

    func testDeleteThenRestoreRunsTheQueueSyncOfTheNewestGeneration() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        ).first
        XCTAssertEqual(excluded?.desired, .excluded)
        XCTAssertEqual(excluded?.generation, 1)
        XCTAssertEqual(excluded?.needsQueueSync, true)
        XCTAssertEqual(excluded?.needsRemoteTrash, false)
        XCTAssertEqual(excluded?.listedInTrash, true)
        XCTAssertEqual(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1", "other"]), ["asset-1"])

        let included = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(included?.desired, .included)
        XCTAssertEqual(included?.generation, 2)

        // A late completion of the delete's queue sync must not clear the restore's request.
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 1, at: date))
        XCTAssertEqual(store.sourceState(for: key)?.needsQueueSync, true)

        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 2, at: date))
        XCTAssertNil(store.sourceState(for: key), "an included source without due effects leaves the store")
        XCTAssertEqual(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1"]), [])
    }

    func testDeleteOfAnUploadedPhotoTrashesItAndShowsOnlyTheProtonTrashEntry() throws {
        let state = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        ).first
        XCTAssertEqual(state?.needsRemoteTrash, true)
        XCTAssertEqual(state?.listedInTrash, false, "the Proton trash represents a photo that was uploaded")
        XCTAssertEqual(state?.remote, remote)

        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let trashed = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(trashed.remoteTrashed)
        XCTAssertFalse(trashed.needsRemoteTrash)
        XCTAssertEqual(trashed.desired, .excluded, "a later edit of the photo must still not upload")

        let restored = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(restored?.needsRemoteRestore, true)
        XCTAssertTrue(store.completeEffect(.remoteRestore, for: key, generation: 2, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 2, at: date))
        XCTAssertNil(store.sourceState(for: key))
    }

    func testTrashThatFinishesAfterARestoreSchedulesTheRemoteRestore() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.include([key], at: date)
        XCTAssertEqual(store.sourceState(for: key)?.needsRemoteRestore, false, "nothing was trashed yet")

        // The trash request was already in flight and completes now.
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(state.desired, .included)
        XCTAssertTrue(state.needsRemoteRestore, "a stale trash must never undo the newer restore")
    }

    func testRestoreThatFinishesAfterANewDeleteSchedulesTheTrashAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.completeEffect(.remoteTrash, for: key, generation: 1, at: date)
        _ = store.include([key], at: date)
        let deletedAgain = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date)
        ).first
        XCTAssertEqual(deletedAgain?.needsRemoteTrash, false, "the photo is still in the Proton trash")
        XCTAssertEqual(deletedAgain?.generation, 3)
        XCTAssertNotNil(deletedAgain?.presentation, "a delete without metadata keeps the stored presentation")

        // The restore request of generation 2 was in flight and completes now.
        XCTAssertTrue(store.completeEffect(.remoteRestore, for: key, generation: 2, at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertTrue(state.needsRemoteTrash, "a stale restore must never undo the newer delete")
    }

    func testCommitThatRacesADeleteSchedulesTheTrashInTheSameTransaction() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        let handoff = PendingHandoff(
            key: key,
            revision: UploadBackupRevision(rawValue: 5),
            remote: remote,
            kind: .uploaded,
            createdAt: date
        )

        XCTAssertEqual(store.recordHandoff(handoff), .excludedRemoteNeedsTrash)
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(state.needsRemoteTrash)
        XCTAssertEqual(state.remote, remote)
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])
    }

    func testDeleteFindsACommitWhoseEventHasNotArrivedYet() throws {
        let revision = UploadBackupRevision(rawValue: 3)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)

        let state = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: presentation(), remote: nil, revision: revision)],
                at: date)
        ).first
        XCTAssertEqual(state?.remote, remote)
        XCTAssertEqual(state?.needsRemoteTrash, true, "the committed photo must still go to the trash")
    }

    func testUndoDuringATrashRequestRestoresEvenAfterACrash() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        )
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])

        // Undo arrives while the trash request is on the wire; the app then ends before completion.
        let restored = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(restored?.needsRemoteRestore, true, "the trash may have happened, so a restore is owed")
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        let reopened = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(reopened.needsRemoteRestore)
        XCTAssertEqual(reopened.remoteOperation, .remoteTrash)
    }

    func testDeleteDuringARestoreRequestTrashesAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.completeEffect(.remoteTrash, for: key, generation: 1, at: date)
        let included = try XCTUnwrap(store.include([key], at: date))
        XCTAssertEqual(store.beginRemoteOperation(.remoteRestore, for: included), [key])

        let deleted = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date)
        ).first
        XCTAssertEqual(deleted?.needsRemoteTrash, true, "the restore may have happened, so a trash is owed")
    }

    func testStaleDispatchIsNeverMarkedOrSent() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        )
        // Undo lands while the reconciler still looks up the photos volume.
        _ = store.include([key], at: date)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [])
        XCTAssertNil(store.sourceState(for: key)?.remoteOperation)
    }

    func testDeferredEffectsBackOffAndBecomeDueAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        XCTAssertEqual(store.dueSourceStates(by: date).map(\.key), [key])
        XCTAssertTrue(store.deferEffects(for: key, at: date))
        XCTAssertTrue(store.dueSourceStates(by: date).isEmpty)
        XCTAssertEqual(store.nextEffectDate(), date.addingTimeInterval(60))
        XCTAssertEqual(store.dueSourceStates(by: date.addingTimeInterval(60)).map(\.key), [key])
    }

    func testRemovingATrashEntryKeepsTheExclusion() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        XCTAssertTrue(store.unlistFromTrash([key], at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertFalse(state.listedInTrash)
        XCTAssertEqual(state.desired, .excluded)
    }

    // MARK: - Evidence and handoffs

    func testEvidenceAndHandoffsSurviveReopening() throws {
        let revision = UploadBackupRevision(rawValue: 42)
        XCTAssertTrue(store.recordUploadEvidence(key, revision: revision, at: date))
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        store.close()

        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL), "a current store reopens")
        XCTAssertEqual(store.evidenceRevisions(), [key: [revision]])
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])

        XCTAssertTrue(store.acknowledgeHandoffs([(key, revision)]))
        XCTAssertTrue(store.unacknowledgedHandoffs().isEmpty)
        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.acknowledged, true)
        XCTAssertEqual(store.handoffs(forRemoteLinkIDs: ["link-1"]).map(\.key), [key])
        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(1)))
        XCTAssertTrue(store.latestHandoffs(for: [key]).isEmpty)
    }

    func testClosedStoreCannotConfirmExclusions() {
        store.close()
        XCTAssertNil(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1"]))
        XCTAssertFalse(store.isOperational())
    }

    // MARK: - Deferred actions

    func testFavoriteToggleReplacesTheEarlierRequest() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        let first = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: false, at: date.addingTimeInterval(1)))

        XCTAssertTrue(store.completeAction(first), "completing a replaced request is harmless")
        XCTAssertEqual(store.actions().map(\.desired), [false], "the newer request survives")
    }

    func testFailedActionRetriesWithBackoffUntilPermanentlyFailed() throws {
        XCTAssertTrue(store.addAlbumIntent(key, albumID: "album-1", at: date))
        let action = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.retryAction(action, at: date))
        XCTAssertTrue(store.dueActions(by: date).isEmpty)
        XCTAssertEqual(store.nextActionDate(), date.addingTimeInterval(60))
        XCTAssertEqual(store.dueActions(by: date.addingTimeInterval(60)).count, 1)

        XCTAssertTrue(store.failAction(action))
        XCTAssertTrue(store.dueActions(by: date.addingTimeInterval(1_000_000)).isEmpty)
        XCTAssertNil(store.nextActionDate())
        XCTAssertEqual(store.actions().first?.failed, true)
    }

    func testStaleActionOutcomeNeverTouchesTheNewerRequest() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        let first = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: false, at: date.addingTimeInterval(1)))

        XCTAssertTrue(store.failAction(first))
        XCTAssertTrue(store.retryAction(first, at: date))
        let current = try XCTUnwrap(store.actions().first)
        XCTAssertFalse(current.failed)
        XCTAssertEqual(current.attempts, 0)
        XCTAssertFalse(current.desired)
    }

    func testHandoffOfAnUnfinishedActionSurvivesPruning() throws {
        let revision = UploadBackupRevision(rawValue: 1)
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        _ = store.recordHandoff(handoff)
        _ = store.acknowledgeHandoffs([(key, revision)])
        XCTAssertTrue(store.addAlbumIntent(key, albumID: "album", at: date))

        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(1)))
        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.remote, remote)
    }

    func testSavedFromAppIdentifiersPersist() {
        XCTAssertTrue(store.recordSavedFromApp(localIdentifier: "saved-1", remote: remote, at: date))
        XCTAssertEqual(store.savedFromAppIdentifiers(), ["saved-1"])
    }
}

final class PendingQueueIntegrationTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-queue-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ id: String, state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
            revision: UploadBackupRevision(rawValue: 7),
            originalFilename: "\(id).heic",
            state: state,
            updatedAt: date
        )
    }

    func testQueueWritesNotifyTheObserverAfterTheyCommit() {
        let changes = LockedChanges()
        queue.setChangeObserver { changes.append($0) }

        XCTAssertTrue(queue.upsert(entry("a", state: .discovered)))
        XCTAssertTrue(
            queue.updateState(
                source: entry("a", state: .discovered).source,
                revision: UploadBackupRevision(rawValue: 7),
                state: .queuedForUpload,
                attempts: nil,
                lastError: nil,
                updatedAt: date
            ))
        XCTAssertEqual(queue.removeSources(kind: .photoLibraryAsset, identifiers: ["a"]), 1)
        XCTAssertEqual(queue.makeRetryableWorkEligible(updatedAt: date), 0, "an empty bulk update stays silent")

        let expected = UploadBackupSyncQueueChange.sources([.photoLibraryAsset: ["a"]])
        XCTAssertEqual(changes.values, [expected, expected, expected])
    }

    func testUnsettledRowsLeaveTerminalOutcomesOut() {
        XCTAssertTrue(
            queue.upsertBatch([
                entry("waiting", state: .discovered),
                entry("done", state: .completed),
                entry("dup", state: .alreadyBackedUp),
                entry("failed", state: .failedPermanent),
            ]))
        XCTAssertEqual(Set(queue.unsettledRows().map(\.source.identifier)), ["waiting", "failed"])
        XCTAssertEqual(queue.rows(kind: .photoLibraryAsset, identifiers: ["done"]).map(\.state), [.completed])
    }

    func testEngineDropsExcludedPhotosAndRefusesWithoutAnAnswer() async throws {
        let exclusions = StubExclusions(excluded: ["excluded"])
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: EmptyStateStore()),
            queue: queue,
            exclusions: exclusions,
            now: { [date] in date }
        )
        _ = try await engine.enqueueBatch([candidate("kept"), candidate("excluded")])
        XCTAssertEqual(Set(queue.unsettledRows().map(\.source.identifier)), ["kept"])

        exclusions.available = false
        do {
            _ = try await engine.enqueueBatch([candidate("later")])
            XCTFail("an unknown exclusion state must never enqueue a photo")
        } catch {}
        XCTAssertFalse(queue.unsettledRows().contains { $0.source.identifier == "later" })
    }

    private func candidate(_ id: String) -> UploadBackupAssetCandidate {
        UploadBackupAssetCandidate(
            snapshot: UploadBackupAssetSnapshot(
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
                revision: UploadBackupRevision(rawValue: 7),
                resourceCount: 1
            ),
            originalFilename: "\(id).heic"
        )
    }
}

private final class LockedChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UploadBackupSyncQueueChange] = []
    var values: [UploadBackupSyncQueueChange] { lock.withLock { stored } }
    func append(_ change: UploadBackupSyncQueueChange) { lock.withLock { stored.append(change) } }
}

private final class StubExclusions: UploadBackupExclusionFiltering, @unchecked Sendable {
    private let lock = NSLock()
    private let excluded: Set<String>
    private var isAvailable = true

    init(excluded: Set<String>) {
        self.excluded = excluded
    }

    var available: Bool {
        get { lock.withLock { isAvailable } }
        set { lock.withLock { isAvailable = newValue } }
    }

    func excludedIdentifiers(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> Set<String>? {
        guard available else { return nil }
        return excluded.intersection(identifiers)
    }
}

private final class EmptyStateStore: UploadBackupStateStore, @unchecked Sendable {
    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? { nil }
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { false }
    func upsert(_ record: UploadBackupAssetRecord) -> Bool { true }
    func count() -> Int { 0 }
}
