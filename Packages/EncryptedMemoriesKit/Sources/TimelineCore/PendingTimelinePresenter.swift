import Foundation
import GridCore
import PhotosCore
import UploadCore

/// Upload badges of the grid. The base map changes only with membership; progress ticks replace the small
/// `progress` overlay, so a tick never copies or compares a map with one entry per pending photo.
public struct PendingUploadBadges: Sendable, Equatable {
    /// Identity of this value; hosts compare it instead of the maps.
    private let id: UUID
    package let base: [PhotoUID: GridUploadBadge]
    /// Progress steps of the few photos whose bytes move now, keyed by grid UID.
    package let progress: [PhotoUID: Int]
    /// Local photos whose content changed in Apple Photos during this session, with a growing epoch per
    /// change. The map is cumulative, so a grid that skips a presentation still sees every change and
    /// uploads the new thumbnail. Sparse: only edited photos.
    package let contentEpochs: [PhotoUID: UInt64]
    /// Proton photos that took over a pending tile this session -> that tile's local UID. Grids let the
    /// Proton photo draw the pending tile's texture, so the handover shows no upload and no fade.
    package let handovers: [PhotoUID: PhotoUID]

    package init(
        base: [PhotoUID: GridUploadBadge] = [:],
        progress: [PhotoUID: Int] = [:],
        contentEpochs: [PhotoUID: UInt64] = [:],
        handovers: [PhotoUID: PhotoUID] = [:]
    ) {
        id = UUID()
        self.base = base
        self.progress = progress
        self.contentEpochs = contentEpochs
        self.handovers = handovers
    }

    public static let empty = PendingUploadBadges()

    package var isEmpty: Bool { base.isEmpty }

    package subscript(uid: PhotoUID) -> GridUploadBadge? {
        guard let badge = base[uid] else { return nil }
        return progress[uid].map { .uploading(step: $0) } ?? badge
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Follows `PendingUploadBadges.handovers` for one grid and reports each handover once.
package struct PendingHandoverTracker {
    private var applied = Set<PhotoUID>()

    package init() {}

    package mutating func newHandovers(in handovers: [PhotoUID: PhotoUID]) -> [(local: PhotoUID, remote: PhotoUID)] {
        if applied.count > handovers.count { applied.formIntersection(handovers.keys) }
        var result: [(local: PhotoUID, remote: PhotoUID)] = []
        for (remote, local) in handovers where applied.insert(remote).inserted { result.append((local, remote)) }
        return result
    }
}

/// Follows `PendingUploadBadges.contentEpochs` for one grid and reports the photos whose resident texture
/// shows old content.
package struct PendingContentEpochTracker {
    private var applied: [PhotoUID: UInt64] = [:]

    package init() {}

    package mutating func changes(in epochs: [PhotoUID: UInt64]) -> [PhotoUID] {
        var changed: [PhotoUID] = []
        for (uid, epoch) in epochs where applied[uid].map({ epoch > $0 }) ?? true {
            changed.append(uid)
            applied[uid] = epoch
        }
        if applied.count > epochs.count { applied = applied.filter { epochs[$0.key] != nil } }
        return changed
    }
}

/// The whole-library timeline as the grid shows it: Proton photos plus local photos that the backup has not
/// uploaded yet. Hosts on iOS, iPadOS and macOS keep their canonical Proton snapshot for every remote-only
/// consumer and show this presentation in the grid and viewer.
public struct PendingTimelinePresentation: Sendable {
    /// Changes with every publication, including badge-only updates.
    public let revision: UInt64
    /// Changes only when the item list changes; grids rebuild content only for this one.
    public let membershipRevision: UInt64
    /// Grid order. Photos that replaced a pending tile keep that tile's position for the session.
    public let snapshot: TimelineSnapshot
    /// Local pending photos in the presentation; the thumbnail feed may load exactly these from the device.
    public let localUIDs: Set<PhotoUID>
    /// Desired favorite states of pending photos, shown before the upload applies them.
    public let favoriteIntents: [PhotoUID: Bool]
    /// Upload badges for the grid; opaque outside the package.
    public let uploadBadges: PendingUploadBadges
    /// True when no pending photo shows; hosts can then use their canonical snapshot directly.
    public let isCanonical: Bool

    public var items: [PhotoItem] { snapshot.items }

    package init(
        revision: UInt64,
        membershipRevision: UInt64,
        snapshot: TimelineSnapshot,
        localUIDs: Set<PhotoUID>,
        favoriteIntents: [PhotoUID: Bool],
        uploadBadges: PendingUploadBadges,
        isCanonical: Bool
    ) {
        self.revision = revision
        self.membershipRevision = membershipRevision
        self.snapshot = snapshot
        self.localUIDs = localUIDs
        self.favoriteIntents = favoriteIntents
        self.uploadBadges = uploadBadges
        self.isCanonical = isCanonical
    }

    public static let empty = PendingTimelinePresentation(
        revision: 0,
        membershipRevision: 0,
        snapshot: TimelineSnapshot(),
        localUIDs: [],
        favoriteIntents: [:],
        uploadBadges: .empty,
        isCanonical: true
    )
}

/// Merges pending backup tiles into the Proton timeline, shared by all platforms.
///
/// Membership changes (a photo appears, uploads, or hands over) rebuild the presentation off the main actor
/// in O(n + m) without a sort. Progress changes only replace the small badge map. When a Proton photo takes
/// over from a pending tile, it inherits the tile's sort key for the rest of the session: `TimelineOrder`
/// breaks ties within one second by volume and node ID, which both change at the handoff, so without the
/// anchor a photo could move by one position in front of the person.
@MainActor
public final class PendingTimelinePresenter {
    /// A new presentation; the host installs it in its grid and viewer.
    public var onChange: ((PendingTimelinePresentation) -> Void)?
    /// Sources whose Proton photo is listed now. The host forwards them to the pending coordinator.
    public var onRemotePresence: ((Set<PendingSourceKey>) -> Void)?
    /// Local photos the feed may load, and decoded images to hand to the Proton photos that replaced them.
    /// `revised` photos changed content in Apple Photos; their decoded images are out of date.
    public var onFeedUpdate:
        (
            (
                _ localUIDs: Set<PhotoUID>, _ adoptions: [(local: PhotoUID, remote: PhotoUID)],
                _ revised: [PhotoUID]
            ) -> Void
        )?

    private var remote = TimelineSnapshot()
    private var pending = PendingBackupSnapshot.empty
    private var isEnabled = false
    /// Session anchors: Proton photo -> the sort key of the pending tile it replaced.
    private var anchors: [PhotoUID: PhotoItem] = [:]
    /// Content revisions of the pending tiles in the last merge.
    private var tileRevisions: [PhotoUID: UploadBackupRevision] = [:]
    private var contentEpochs: [PhotoUID: UInt64] = [:]
    private var contentEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var membershipRevision: UInt64 = 0
    private var computeTask: Task<Void, Never>?
    private var computeGeneration: UInt64 = 0
    private var presentation = PendingTimelinePresentation.empty
    private var lastMembershipRevision: UInt64?

    public init() {}

    public var current: PendingTimelinePresentation { presentation }

    /// The canonical Proton timeline of the whole-library route.
    public func setRemote(_ snapshot: TimelineSnapshot) {
        guard snapshot != remote else { return }
        remote = snapshot
        rebuild()
    }

    /// The latest pending snapshot. `enabled` is false while backup is off or unavailable: then no local
    /// photo shows and the feed forgets every local image.
    public func setPending(_ snapshot: PendingBackupSnapshot, enabled: Bool) {
        let membershipChanged =
            enabled != isEnabled || snapshot.membershipRevision != pending.membershipRevision
            || lastMembershipRevision == nil
        pending = snapshot
        isEnabled = enabled
        if membershipChanged {
            rebuild()
        } else {
            refreshBadges()
        }
    }

    /// Ends the session: pending tiles and anchors belong to one account.
    public func reset() {
        computeTask?.cancel()
        computeTask = nil
        computeGeneration &+= 1
        remote = TimelineSnapshot()
        pending = .empty
        isEnabled = false
        anchors.removeAll()
        tileRevisions.removeAll()
        contentEpochs.removeAll()
        lastMembershipRevision = nil
        revision &+= 1
        membershipRevision &+= 1
        presentation = PendingTimelinePresentation(
            revision: revision, membershipRevision: membershipRevision, snapshot: TimelineSnapshot(), localUIDs: [],
            favoriteIntents: [:], uploadBadges: .empty, isCanonical: true)
        onFeedUpdate?([], [], [])
        onChange?(presentation)
    }

    // MARK: - Membership

    private func rebuild() {
        computeGeneration &+= 1
        let generation = computeGeneration
        let input = MergeInput(
            remote: remote,
            pending: isEnabled ? pending : .empty,
            anchors: anchors,
            revisions: tileRevisions
        )
        lastMembershipRevision = pending.membershipRevision
        computeTask?.cancel()
        computeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.merge(input)
            guard !Task.isCancelled else { return }
            await self?.apply(result, generation: generation)
        }
    }

    private func apply(_ result: MergeResult, generation: UInt64) {
        guard generation == computeGeneration else { return }
        computeTask = nil
        for (remoteUID, anchor) in result.newAnchors { anchors[remoteUID] = anchor }
        // Anchors of Proton photos that left the timeline are no longer needed.
        if !anchors.isEmpty {
            anchors = anchors.filter { result.snapshot.index(of: $0.key) != nil }
        }
        tileRevisions = result.revisions
        // A revised photo keeps its current image; `noteContentRefreshed` bumps its epoch once the new
        // image is loaded, so the tile never shows black in between.
        if !contentEpochs.isEmpty { contentEpochs = contentEpochs.filter { result.localUIDs.contains($0.key) } }
        revision &+= 1
        if result.snapshot != presentation.snapshot { membershipRevision &+= 1 }
        let shown = isEnabled ? pending : .empty
        presentation = PendingTimelinePresentation(
            revision: revision,
            membershipRevision: membershipRevision,
            snapshot: result.snapshot,
            localUIDs: result.localUIDs,
            favoriteIntents: shown.favoriteIntents.filter { result.localUIDs.contains($0.key) },
            uploadBadges: PendingUploadBadges(
                base: result.baseBadges, progress: Self.progress(of: shown, gridUIDs: result.presentLocal),
                contentEpochs: contentEpochs, handovers: anchors.mapValues(\.uid)),
            isCanonical: result.localUIDs.isEmpty && anchors.isEmpty
        )
        onFeedUpdate?(result.localUIDs, result.adoptions, result.revised)
        if !result.presentKeys.isEmpty { onRemotePresence?(result.presentKeys) }
        presentLocal = result.presentLocal
        onChange?(presentation)
    }

    /// The feed holds new images for these revised photos; grids upload them in place of the old textures.
    public func noteContentRefreshed(_ uids: [PhotoUID]) {
        let shown = uids.filter { presentation.localUIDs.contains($0) }
        guard !shown.isEmpty else { return }
        for uid in shown {
            contentEpoch &+= 1
            contentEpochs[uid] = contentEpoch
        }
        let badges = PendingUploadBadges(
            base: presentation.uploadBadges.base, progress: presentation.uploadBadges.progress,
            contentEpochs: contentEpochs, handovers: presentation.uploadBadges.handovers)
        revision &+= 1
        presentation = PendingTimelinePresentation(
            revision: revision,
            membershipRevision: membershipRevision,
            snapshot: presentation.snapshot,
            localUIDs: presentation.localUIDs,
            favoriteIntents: presentation.favoriteIntents,
            uploadBadges: badges,
            isCanonical: presentation.isCanonical
        )
        onChange?(presentation)
    }

    /// Local UIDs of tiles whose Proton photo is listed -> that photo, from the last merge.
    private var presentLocal: [PhotoUID: PhotoUID] = [:]

    /// A progress tick: O(uploads in flight), never O(pending photos).
    private func refreshBadges() {
        let progress = Self.progress(of: isEnabled ? pending : .empty, gridUIDs: presentLocal)
        guard progress != presentation.uploadBadges.progress else { return }
        let badges = PendingUploadBadges(
            base: presentation.uploadBadges.base, progress: progress,
            contentEpochs: presentation.uploadBadges.contentEpochs, handovers: presentation.uploadBadges.handovers)
        revision &+= 1
        presentation = PendingTimelinePresentation(
            revision: revision,
            membershipRevision: membershipRevision,
            snapshot: presentation.snapshot,
            localUIDs: presentation.localUIDs,
            favoriteIntents: presentation.favoriteIntents,
            uploadBadges: badges,
            isCanonical: presentation.isCanonical
        )
        onChange?(presentation)
    }

    // MARK: - Pure merge (off main)

    private struct MergeInput: Sendable {
        let remote: TimelineSnapshot
        let pending: PendingBackupSnapshot
        let anchors: [PhotoUID: PhotoItem]
        let revisions: [PhotoUID: UploadBackupRevision]
    }

    private struct MergeResult: Sendable {
        let snapshot: TimelineSnapshot
        let localUIDs: Set<PhotoUID>
        let presentKeys: Set<PendingSourceKey>
        let newAnchors: [PhotoUID: PhotoItem]
        let adoptions: [(local: PhotoUID, remote: PhotoUID)]
        let baseBadges: [PhotoUID: GridUploadBadge]
        let presentLocal: [PhotoUID: PhotoUID]
        let revisions: [PhotoUID: UploadBackupRevision]
        /// Visible local photos whose content revision changed since the last merge.
        let revised: [PhotoUID]
    }

    private nonisolated static func merge(_ input: MergeInput) -> MergeResult {
        let remoteItems = input.remote.items
        // Owned photos share one volume; link-only handoffs resolve to it.
        let photosVolume = remoteItems.first?.uid.volumeID
        var anchors = input.anchors
        var newAnchors: [PhotoUID: PhotoItem] = [:]
        var present: [PhotoUID: PendingTile] = [:]
        var presentKeys = Set<PendingSourceKey>()
        var adoptions: [(local: PhotoUID, remote: PhotoUID)] = []
        var visible: [PhotoItem] = []
        visible.reserveCapacity(input.pending.tiles.count)
        for tile in input.pending.tiles {
            guard let handoff = tile.handoff,
                let remoteUID = resolve(handoff, photosVolume: photosVolume),
                input.remote.index(of: remoteUID) != nil
            else {
                visible.append(tile.item)
                continue
            }
            // The Proton photo is listed: it takes over the tile, in the tile's position.
            present[remoteUID] = tile
            presentKeys.insert(tile.key)
            if anchors[remoteUID] == nil {
                anchors[remoteUID] = tile.item
                newAnchors[remoteUID] = tile.item
                adoptions.append((tile.item.uid, remoteUID))
            }
        }
        let localUIDs = Set(visible.map(\.uid))
        var revisions: [PhotoUID: UploadBackupRevision] = [:]
        var revised: [PhotoUID] = []
        for tile in input.pending.tiles where localUIDs.contains(tile.item.uid) {
            guard let revision = tile.revision else { continue }
            revisions[tile.item.uid] = revision
            if let previous = input.revisions[tile.item.uid], previous != revision { revised.append(tile.item.uid) }
        }
        let presentLocal = Dictionary(uniqueKeysWithValues: present.map { ($0.value.item.uid, $0.key) })
        let baseBadges = badges(for: input.pending, gridUIDs: presentLocal)
        guard !visible.isEmpty || !anchors.isEmpty else {
            return MergeResult(
                snapshot: input.remote, localUIDs: [], presentKeys: presentKeys,
                newAnchors: newAnchors, adoptions: adoptions, baseBadges: baseBadges, presentLocal: presentLocal,
                revisions: revisions, revised: revised)
        }

        // Three streams sorted by one presentation key; a linear merge keeps their total order.
        var anchored: [(key: PhotoItem, item: PhotoItem)] = []
        var canonical: [PhotoItem] = []
        canonical.reserveCapacity(remoteItems.count)
        for item in remoteItems {
            if let key = anchors[item.uid] {
                anchored.append((key, item))
            } else {
                canonical.append(item)
            }
        }
        anchored.sort { TimelineOrder.areInIncreasingOrder($0.key, $1.key) }

        var merged: [PhotoItem] = []
        merged.reserveCapacity(canonical.count + visible.count + anchored.count)
        var c = 0
        var v = 0
        var a = 0
        while c < canonical.count || v < visible.count || a < anchored.count {
            var bestKey: PhotoItem?
            var source = 0
            if c < canonical.count {
                bestKey = canonical[c]
                source = 0
            }
            if v < visible.count, bestKey.map({ TimelineOrder.areInIncreasingOrder(visible[v], $0) }) ?? true {
                bestKey = visible[v]
                source = 1
            }
            if a < anchored.count,
                bestKey.map({ TimelineOrder.areInIncreasingOrder(anchored[a].key, $0) }) ?? true
            {
                source = 2
            }
            switch source {
            case 0:
                merged.append(canonical[c])
                c += 1
            case 1:
                merged.append(visible[v])
                v += 1
            default:
                merged.append(anchored[a].item)
                a += 1
            }
        }
        return MergeResult(
            snapshot: TimelineSnapshot(trustingOrderOf: merged),
            localUIDs: localUIDs,
            presentKeys: presentKeys,
            newAnchors: newAnchors,
            adoptions: adoptions,
            baseBadges: baseBadges,
            presentLocal: presentLocal,
            revisions: revisions,
            revised: revised
        )
    }

    private nonisolated static func resolve(_ handoff: PhotoUID, photosVolume: String?) -> PhotoUID? {
        guard handoff.volumeID.isEmpty else { return handoff }
        return photosVolume.map { PhotoUID(volumeID: $0, nodeID: handoff.nodeID) }
    }

    /// Badges of visible pending tiles, and of Proton photos that took over from a tile that is still
    /// uploading (a Live Photo video) or shows its checkmark. Progress stays out; see `progress(of:gridUIDs:)`.
    private nonisolated static func badges(
        for snapshot: PendingBackupSnapshot,
        gridUIDs: [PhotoUID: PhotoUID]
    ) -> [PhotoUID: GridUploadBadge] {
        var badges: [PhotoUID: GridUploadBadge] = [:]
        badges.reserveCapacity(snapshot.tiles.count)
        for tile in snapshot.tiles {
            guard let badge = gridBadge(tile.badge) else { continue }
            badges[gridUIDs[tile.item.uid] ?? tile.item.uid] = badge
        }
        return badges
    }

    /// Progress steps keyed by grid UID. O(uploads in flight).
    private nonisolated static func progress(
        of snapshot: PendingBackupSnapshot,
        gridUIDs: [PhotoUID: PhotoUID]
    ) -> [PhotoUID: Int] {
        var progress: [PhotoUID: Int] = [:]
        for (local, step) in snapshot.progress { progress[gridUIDs[local] ?? local] = step }
        return progress
    }

    /// Nil once the checkmark has shown: a backed-up photo looks like any other photo.
    private nonisolated static func gridBadge(_ badge: PendingUploadBadge) -> GridUploadBadge? {
        switch badge {
        case .waiting: .waiting
        case .uploading(let step): .uploading(step: step)
        case .attention: .attention
        case .done: .done
        case .backedUp: nil
        }
    }
}
