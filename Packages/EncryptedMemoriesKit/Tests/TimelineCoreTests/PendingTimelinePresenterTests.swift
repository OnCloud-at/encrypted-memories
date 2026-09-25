import Foundation
import GridCore
import PhotosCore
import Testing
import UploadCore

@testable import TimelineCore

@Suite @MainActor struct PendingTimelinePresenterTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func remote(_ node: String, second: TimeInterval) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: base.addingTimeInterval(second),
            mediaType: "image/jpeg")
    }

    private func tile(
        _ id: String,
        second: TimeInterval,
        handoff: PhotoUID? = nil,
        settled: Bool = false,
        badge: PendingUploadBadge = .waiting
    ) -> PendingTile {
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
        return PendingTile(
            key: key,
            item: PhotoItem(uid: key.localUID, captureTime: base.addingTimeInterval(second), mediaType: "image/heic"),
            revision: UploadBackupRevision(rawValue: 1),
            handoff: handoff,
            isSettled: settled,
            badge: badge,
            displayName: id
        )
    }

    private func pending(
        _ tiles: [PendingTile], membership: UInt64, progress: [PhotoUID: Int] = [:]
    )
        -> PendingBackupSnapshot
    {
        PendingBackupSnapshot(membershipRevision: membership, progressRevision: 0, tiles: tiles, progress: progress)
    }

    private func settle(_ presenter: PendingTimelinePresenter) async -> PendingTimelinePresentation {
        for _ in 0..<200 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return presenter.current
    }

    @Test func trashMergesPendingPhotosNewestFirst() {
        let newest = remote("newest", second: 30)
        let oldest = remote("oldest", second: 0)
        let pending = tile("pending", second: 10).item
        let trash = PendingTrashPresentation(items: [pending])

        #expect(trash.merged(intoNewestFirst: [newest, oldest]).map(\.uid) == [newest.uid, pending.uid, oldest.uid])
        #expect(trash.badges[pending.uid] == .notBackedUp)
        #expect(PendingTrashPresentation.empty.merged(intoNewestFirst: [newest]).map(\.uid) == [newest.uid])
    }

    @Test func editedLocalPhotoGetsANewContentEpochOnceItsImageLoaded() async {
        let presenter = PendingTimelinePresenter()
        var revisedUIDs: [PhotoUID] = []
        presenter.onFeedUpdate = { _, _, revised in revisedUIDs += revised }
        let original = tile("b", second: 10)
        presenter.setPending(pending([original], membership: 1), enabled: true)
        let before = await settle(presenter)
        #expect(before.uploadBadges.contentEpochs.isEmpty)

        let edited = PendingTile(
            key: original.key, item: original.item, revision: UploadBackupRevision(rawValue: 2), handoff: nil,
            isSettled: false, badge: .waiting, displayName: "b")
        presenter.setPending(pending([edited], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(revisedUIDs == [original.item.uid])
        #expect(after.uploadBadges.contentEpochs.isEmpty, "the tile keeps its image until the new one loaded")

        presenter.noteContentRefreshed([original.item.uid, tile("gone", second: 0).item.uid])
        var tracker = PendingContentEpochTracker()
        #expect(tracker.changes(in: presenter.current.uploadBadges.contentEpochs) == [original.item.uid])
        #expect(
            tracker.changes(in: presenter.current.uploadBadges.contentEpochs).isEmpty, "one change invalidates once")
    }

    @Test func pendingPhotosSortIntoTheTimeline() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0), remote("c", second: 20)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid.nodeID) == ["a", "b", "c"])
        #expect(presentation.localUIDs == [PendingSourceKey(kind: .photoLibraryAsset, identifier: "b").localUID])
        #expect(!presentation.isCanonical)
    }

    @Test func handedOverPhotoKeepsThePendingPosition() async {
        // In the same second, the canonical order puts the new Proton photo ("zz") after "m", while the pending
        // tile ("local.photos" volume) sorted before "m". The anchor keeps the pending position.
        let presenter = PendingTimelinePresenter()
        var remotes = [remote("m", second: 5)]
        presenter.setRemote(TimelineSnapshot(orderedItems: remotes))
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "zz")
        presenter.setPending(
            pending([tile("p", second: 5, handoff: uploaded, badge: .uploading(step: 10))], membership: 1),
            enabled: true)
        let before = await settle(presenter)
        #expect(before.items.map(\.uid.volumeID) == ["local.photos", "vol"])

        var presence: Set<PendingSourceKey> = []
        presenter.onRemotePresence = { presence.formUnion($0) }
        remotes.append(PhotoItem(uid: uploaded, captureTime: base.addingTimeInterval(5), mediaType: "image/heic"))
        presenter.setRemote(TimelineSnapshot(orderedItems: remotes))
        let after = await settle(presenter)

        #expect(after.items.map(\.uid) == [uploaded, remotes[0].uid], "the Proton photo takes the tile's place")
        #expect(after.localUIDs.isEmpty)
        #expect(after.uploadBadges[uploaded] == .uploading(step: 10), "a still-uploading source keeps its progress")
        #expect(presence == [PendingSourceKey(kind: .photoLibraryAsset, identifier: "p")])

        // Grids let the Proton photo draw the pending tile's texture, once.
        let local = before.items[0].uid
        #expect(after.uploadBadges.handovers == [uploaded: local])
        var tracker = PendingHandoverTracker()
        #expect(tracker.newHandovers(in: after.uploadBadges.handovers).map(\.remote) == [uploaded])
        #expect(tracker.newHandovers(in: after.uploadBadges.handovers).isEmpty)
    }

    @Test func linkOnlyHandoffResolvesToThePhotosVolume() async {
        let presenter = PendingTimelinePresenter()
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "dup")
        presenter.setRemote(
            TimelineSnapshot(orderedItems: [PhotoItem(uid: uploaded, captureTime: base, mediaType: "image/jpeg")]))
        presenter.setPending(
            pending(
                [tile("d", second: 0, handoff: PhotoUID(volumeID: "", nodeID: "dup"), settled: true, badge: .done)],
                membership: 1),
            enabled: true)
        let presentation = await settle(presenter)
        #expect(presentation.items.map(\.uid) == [uploaded])
        #expect(presentation.uploadBadges[uploaded] == .done)
    }

    @Test func disabledBackupShowsOnlyProtonPhotos() async {
        let presenter = PendingTimelinePresenter()
        let canonical = TimelineSnapshot(orderedItems: [remote("a", second: 0)])
        presenter.setRemote(canonical)
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: false)
        let presentation = await settle(presenter)
        #expect(presentation.snapshot == canonical)
        #expect(presentation.isCanonical)
        #expect(presentation.uploadBadges.isEmpty)
    }

    @Test func progressChangesOnlyTheBadges() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        let pendingTile = tile("b", second: 10)
        presenter.setPending(pending([pendingTile], membership: 1), enabled: true)
        let before = await settle(presenter)

        presenter.setPending(pending([pendingTile], membership: 1, progress: [pendingTile.item.uid: 12]), enabled: true)
        let after = presenter.current
        #expect(after.membershipRevision == before.membershipRevision)
        #expect(after.revision != before.revision)
        #expect(after.uploadBadges[pendingTile.item.uid] == .uploading(step: 12))
    }
}
