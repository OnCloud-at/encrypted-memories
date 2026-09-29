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
        badge: PendingUploadBadge = .waiting,
        replaces: [PhotoUID] = []
    ) -> PendingTile {
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
        return PendingTile(
            key: key,
            item: PhotoItem(uid: key.localUID, captureTime: base.addingTimeInterval(second), mediaType: "image/heic"),
            revision: UploadBackupRevision(rawValue: 1),
            handoff: handoff,
            isSettled: settled,
            badge: badge,
            displayName: id,
            replaces: replaces
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

    // MARK: - Edits of backed-up photos

    /// Proton photos in the same second as the edited photo, so only the anchor decides the place.
    private func sameSecond(_ nodes: [String]) -> [PhotoItem] {
        nodes.map { remote($0, second: 10) }.sorted(by: TimelineOrder.areInIncreasingOrder)
    }

    @Test func theTileOfAnEditTakesThePlaceOfItsEarlierPhotoAndHidesIt() async {
        let presenter = PendingTimelinePresenter()
        let listed = sameSecond(["a", "earlier", "z"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let edit = tile("p", second: 10, replaces: [PhotoUID(volumeID: "", nodeID: "earlier")])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        let presentation = await settle(presenter)

        #expect(
            presentation.items.map(\.uid) == listed.map { $0.uid.nodeID == "earlier" ? edit.item.uid : $0.uid },
            "one photo, at the earlier photo's place")
        #expect(!presentation.isCanonical)
    }

    @Test func theProtonPhotoOfAnEditKeepsThePlaceAndContinuesTheTileImage() async {
        let presenter = PendingTimelinePresenter()
        let listed = sameSecond(["a", "earlier", "z"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let edit = tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 10), replaces: [earlier])
        presenter.setPending(pending([edit], membership: 1), enabled: true)
        _ = await settle(presenter)

        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("0-new", second: 10)]))
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid) == listed.map { $0.uid == earlier ? uploaded : $0.uid })
        #expect(
            presentation.uploadBadges.handovers[uploaded] == edit.item.uid,
            "the Proton photo continues the tile's texture, never the earlier photo's")
    }

    @Test func aTrashedEarlierPhotoStaysHiddenUntilTheListingDropsIt() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["a", "earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let done = tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])
        presenter.setPending(pending([done], membership: 1), enabled: true)
        _ = await settle(presenter)

        // The tile retires, but the listing still returns the trashed photo.
        presenter.setPending(pending([], membership: 2), enabled: true)
        let lagging = await settle(presenter)
        #expect(!lagging.items.map(\.uid).contains(earlier))
        #expect(lagging.items.map(\.uid).contains(uploaded))

        let withoutEarlier = listed.filter { $0.uid != earlier }
        presenter.setRemote(TimelineSnapshot(orderedItems: withoutEarlier))
        _ = await settle(presenter)
        // The person restores it from Recently Deleted: it shows again.
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let restored = await settle(presenter)
        #expect(restored.items.map(\.uid).contains(earlier))
    }

    @Test func aTrashedPhotoThatThePersonRestoredShowsAgainAtTheLatestAfterTheLimit() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let presenter = PendingTimelinePresenter(now: { clock.now })
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])],
                membership: 1),
            enabled: true)
        _ = await settle(presenter)
        presenter.setPending(pending([], membership: 2), enabled: true)
        let hidden = await settle(presenter)
        #expect(hidden.items.map(\.uid) == [uploaded])

        // Restored on another device before the listing dropped it: the listing keeps returning it.
        clock.now = clock.now.addingTimeInterval(PendingTimelinePresenter.trashedHideLimit + 1)
        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("b", second: 20)]))
        let restored = await settle(presenter)
        #expect(restored.items.map(\.uid).contains(earlier))
    }

    @Test func aTrashedPhotoRestoredInThisAppShowsAtOnce() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        let done = tile("p", second: 10, handoff: uploaded, settled: true, badge: .done, replaces: [earlier])
        presenter.setPending(pending([done], membership: 1), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == [uploaded])

        presenter.showRestored([earlier])
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier, uploaded], "while the tile still shows")
        presenter.setPending(pending([], membership: 2), enabled: true)
        #expect(Set(await settle(presenter).items.map(\.uid)) == [earlier, uploaded], "and after it retired")
    }

    @Test func aSecondEditTakesThePlaceWhereTheFirstEditShows() async {
        let presenter = PendingTimelinePresenter()
        let original = PhotoUID(volumeID: "vol", nodeID: "m-original")
        let first = PhotoUID(volumeID: "vol", nodeID: "z-first")
        let second = PhotoUID(volumeID: "vol", nodeID: "0-second")
        let listed = sameSecond(["a", "m-original", "q"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: first, badge: .uploading(step: 5), replaces: [original])],
                membership: 1),
            enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: listed + [remote("z-first", second: 10)]))
        let firstEdit = await settle(presenter)
        let place = listed.map { $0.uid == original ? first : $0.uid }
        #expect(firstEdit.items.map(\.uid) == place)

        // The first tile retired and the listing dropped the original; then the photo is edited again.
        let afterFirst = sameSecond(["a", "q", "z-first"])
        presenter.setRemote(TimelineSnapshot(orderedItems: afterFirst))
        presenter.setPending(pending([], membership: 2), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == place)
        let edit = tile("p", second: 10, replaces: [first])
        presenter.setPending(pending([edit], membership: 3), enabled: true)
        #expect(await settle(presenter).items.map(\.uid) == listed.map { $0.uid == original ? edit.item.uid : $0.uid })

        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: second, badge: .uploading(step: 5), replaces: [first])],
                membership: 4),
            enabled: true)
        presenter.setRemote(TimelineSnapshot(orderedItems: afterFirst + [remote("0-second", second: 10)]))
        #expect(await settle(presenter).items.map(\.uid) == listed.map { $0.uid == original ? second : $0.uid })
    }

    @Test func anEarlierPhotoThatTheReplacementKeptShowsAgain() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        let uploaded = PhotoUID(volumeID: "vol", nodeID: "0-new")
        let listed = sameSecond(["earlier", "0-new"])
        presenter.setRemote(TimelineSnapshot(orderedItems: listed))
        presenter.setPending(
            pending(
                [tile("p", second: 10, handoff: uploaded, badge: .uploading(step: 5), replaces: [earlier])],
                membership: 1),
            enabled: true)
        let uploading = await settle(presenter)
        #expect(uploading.items.map(\.uid) == [uploaded])

        presenter.setPending(
            pending([tile("p", second: 10, handoff: uploaded, settled: true, badge: .done)], membership: 2),
            enabled: true)
        let kept = await settle(presenter)
        #expect(Set(kept.items.map(\.uid)) == [earlier, uploaded])
    }

    @Test func anUndoThatHandsOverToTheEarlierPhotoKeepsIt() async {
        let presenter = PendingTimelinePresenter()
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
        presenter.setRemote(TimelineSnapshot(orderedItems: sameSecond(["earlier"])))
        presenter.setPending(
            pending([tile("p", second: 10, handoff: earlier, badge: .done, replaces: [earlier])], membership: 1),
            enabled: true)
        let presentation = await settle(presenter)

        #expect(presentation.items.map(\.uid) == [earlier])
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

    @Test func aBadgeChangeKeepsTheGridMembership() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let before = await settle(presenter)

        presenter.setPending(pending([tile("b", second: 10, badge: .done)], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(after.revision != before.revision)
        #expect(after.membershipRevision == before.membershipRevision)
        #expect(after.snapshot == before.snapshot)
        #expect(after.uploadBadges[tile("b", second: 10).item.uid] == .done)
    }

    @Test func aNewPendingPhotoChangesTheGridMembership() async {
        let presenter = PendingTimelinePresenter()
        presenter.setRemote(TimelineSnapshot(orderedItems: [remote("a", second: 0)]))
        presenter.setPending(pending([tile("b", second: 10)], membership: 1), enabled: true)
        let before = await settle(presenter)

        let (b, c) = (tile("b", second: 10), tile("c", second: 20))
        presenter.setPending(pending([b, c], membership: 2), enabled: true)
        let after = await settle(presenter)

        #expect(after.membershipRevision != before.membershipRevision)
        #expect(after.items.map(\.uid) == [remote("a", second: 0).uid, b.item.uid, c.item.uid])
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
