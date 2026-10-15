import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite("Timeline rebuild from the local store")
struct TimelineLocalRebuildTests {
    private static let cursor = "event-7"
    private static let persistedToken = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: cursor)

    private static func conditions(
        basis: TimelineLoadBasis? = TimelineLoadBasis(
            eventToken: cursor, revisions: TimelineLocalRevisions(mediaType: 1, order: 1)),
        eventToken: String = cursor,
        revisions: TimelineLocalRevisions = TimelineLocalRevisions(mediaType: 2, order: 1),
        pendingUploads: Bool = false,
        unmaterializedEvidence: Bool = false,
        awaitingLibrary: Bool = false,
        continuityRecovery: Bool = false
    ) -> TimelineLocalRebuild.Conditions {
        TimelineLocalRebuild.Conditions(
            basis: basis, currentEventToken: eventToken, currentRevisions: revisions,
            hasPendingLocalUploads: pendingUploads, hasUnmaterializedLocalEvidence: unmaterializedEvidence,
            hasPhotosAwaitingLibrary: awaitingLibrary, continuityRecoveryRequired: continuityRecovery)
    }

    private static func item(
        _ node: String, at time: Double = 100, type: String = "image/jpeg", tags: Set<PhotoTag> = [],
        live: Bool = false, related: String? = nil, burst: [String] = [], duration: Double? = nil
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: Date(timeIntervalSince1970: time),
            mediaType: type, isLivePhoto: live, relatedVideoID: related, durationSeconds: duration, tags: tags,
            burstMemberIDs: burst)
    }

    /// Counts the store reads that a plan makes.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var items = 0
        private var evidence = 0
        var itemReads: Int { lock.withLock { items } }
        var evidenceReads: Int { lock.withLock { evidence } }
        func item() { lock.withLock { items += 1 } }
        func evidenceRead() { lock.withLock { evidence += 1 } }
    }

    private static func plan(
        _ conditions: TimelineLocalRebuild.Conditions,
        storedToken: String? = persistedToken,
        stored: [PhotoItem]? = [item("a")],
        evidence: [String: String] = [:],
        reads: Reads = Reads()
    ) -> [TimelineSection]? {
        TimelineLocalRebuild.plan(
            conditions,
            storedValidationToken: { storedToken },
            storedItems: {
                reads.item()
                return stored
            },
            mediaTypeEvidence: {
                reads.evidenceRead()
                return evidence
            })
    }

    @Test func aRevisionOnlyChangeForTheSameCursorRebuildsFromTheStore() {
        let sections = Self.plan(Self.conditions(), stored: [Self.item("a"), Self.item("b", at: 200)])
        #expect(sections?.first?.items.map(\.uid.nodeID) == ["a", "b"])
        // The order revision alone counts as well.
        #expect(
            Self.plan(Self.conditions(revisions: TimelineLocalRevisions(mediaType: 1, order: 2))) != nil)
    }

    @Test func everyOtherSituationKeepsTheListing() {
        let ineligible: [(String, TimelineLocalRebuild.Conditions)] = [
            ("no earlier load of this backend", Self.conditions(basis: nil)),
            (
                "the server cursor moved",
                Self.conditions(
                    basis: TimelineLoadBasis(
                        eventToken: "event-6", revisions: TimelineLocalRevisions(mediaType: 1, order: 1)))
            ),
            (
                "nothing changed, a plain refresh",
                Self.conditions(revisions: TimelineLocalRevisions(mediaType: 1, order: 1))
            ),
            ("an upload waits for the listing", Self.conditions(pendingUploads: true)),
            ("evidence of an upload waits for the listing", Self.conditions(unmaterializedEvidence: true)),
            ("a trashed photo waits for the listing", Self.conditions(awaitingLibrary: true)),
            ("the event history was reset", Self.conditions(continuityRecovery: true)),
        ]
        for (reason, conditions) in ineligible {
            let reads = Reads()
            #expect(Self.plan(conditions, reads: reads) == nil, "\(reason)")
            // The stored inventory is not even read when the conditions say no.
            #expect(reads.itemReads == 0 && reads.evidenceReads == 0, "\(reason)")
        }
    }

    @Test func aStoredInventoryOfAnotherCursorIsNotUsed() {
        let other = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-6")
        #expect(Self.plan(Self.conditions(), storedToken: other) == nil)
        #expect(Self.plan(Self.conditions(), storedToken: nil) == nil)
        #expect(Self.plan(Self.conditions(), storedToken: Self.cursor) == nil)
    }

    @Test func aFailedOrEmptyStoreReadKeepsTheListing() {
        #expect(Self.plan(Self.conditions(), stored: nil) == nil)
        #expect(Self.plan(Self.conditions(), stored: []) == nil)
        let throwing = TimelineLocalRebuild.plan(
            Self.conditions(), storedValidationToken: { Self.persistedToken },
            storedItems: { throw CocoaError(.fileReadCorruptFile) }, mediaTypeEvidence: { [:] })
        #expect(throwing == nil)
    }

    @Test func theEvidenceIsAppliedLikeAListingDoes() {
        let stored = [
            Self.item("photo-to-video", at: 10, type: "image/jpeg"),
            Self.item("video-to-photo", at: 20, type: "video/quicktime", tags: [.videos, .favorites]),
            Self.item("untouched", at: 30, type: "image/heic", tags: [.favorites]),
        ]
        let items = TimelineLocalRebuild.sections(
            from: stored,
            mediaTypeEvidence: ["photo-to-video": "video/mp4", "video-to-photo": "image/jpeg", "other": "video/mp4"]
        ).flatMap(\.items)
        let byNode = Dictionary(uniqueKeysWithValues: items.map { ($0.uid.nodeID, $0) })
        #expect(byNode["photo-to-video"]?.mediaType == "video/mp4")
        #expect(byNode["photo-to-video"]?.tags == [.videos])
        #expect(byNode["video-to-photo"]?.mediaType == "image/jpeg")
        #expect(byNode["video-to-photo"]?.tags == [.favorites])
        #expect(byNode["untouched"]?.mediaType == "image/heic")
        #expect(byNode["untouched"]?.tags == [.favorites])
    }

    @Test func everythingElseOfAStoredItemSurvivesAndTheShapeMatchesAListing() throws {
        let stored = [
            Self.item("live", at: 300, live: true, related: "motion", duration: 4),
            Self.item("burst", at: 100, burst: ["burst", "burst-2"]),
            Self.item("tie-b", at: 200),
            Self.item("tie-a", at: 200),
        ]
        let sections = TimelineLocalRebuild.sections(from: stored, mediaTypeEvidence: [:])
        let section = try #require(sections.first)
        #expect(sections.count == 1 && section.id == "all" && section.title == "")
        // Canonical timeline order: time, then volume and node.
        #expect(section.items.map(\.uid.nodeID) == ["burst", "tie-a", "tie-b", "live"])
        #expect(section.date == section.items.first?.captureTime)
        let live = try #require(section.items.first { $0.uid.nodeID == "live" })
        #expect(live.isLivePhoto && live.relatedVideoID == "motion")
        #expect(section.items.first { $0.uid.nodeID == "burst" }?.burstMemberIDs == ["burst", "burst-2"])
        // A listing enumerates no duration; a save keeps the one that was learned later.
        #expect(live.durationSeconds == nil)
        #expect(TimelineLocalRebuild.sections(from: [], mediaTypeEvidence: [:]).first?.items.isEmpty == true)
    }

    @Test func aPublishedEvidenceRevisionReachesTheSectionsOfARealStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        let items = [Self.item("a", at: 1), Self.item("b", at: 2), Self.item("c", at: 3)]
        #expect(store.save(items, validationToken: Self.persistedToken).succeeded)
        let before = TimelineLocalRevisions(mediaType: store.mediaTypeEvidenceRevision(), order: 0)
        let basis = TimelineLoadBasis(eventToken: Self.cursor, revisions: before)

        // A background reconciliation learns that "b" is a video and publishes one revision at its end.
        store.recordMediaTypeEvidence(
            [PhotoUID(volumeID: "vol", nodeID: "b"): "video/quicktime"], publishRevision: false)
        #expect(store.publishMediaTypeEvidenceRevision())
        let after = TimelineLocalRevisions(mediaType: store.mediaTypeEvidenceRevision(), order: 0)
        #expect(after != before)

        let conditions = Self.conditions(basis: basis, revisions: after)
        let sections = TimelineLocalRebuild.plan(
            conditions,
            storedValidationToken: { store.validationToken() },
            storedItems: { try store.cachedTimelineSnapshot()?.sections.flatMap(\.items) },
            mediaTypeEvidence: { store.mediaTypeEvidenceForDisplay(volumeID: "vol").types })
        let rebuilt = try #require(sections?.first?.items)
        #expect(rebuilt.map(\.uid.nodeID) == ["a", "b", "c"])
        #expect(rebuilt.map(\.isVideo) == [false, true, false])
        #expect(rebuilt[1].tags.contains(.videos))

        // Once this rebuild is the basis, the same revisions are a plain refresh again.
        let next = TimelineLoadBasis(eventToken: Self.cursor, revisions: after)
        #expect(
            !TimelineLocalRebuild.isEligible(
                Self.conditions(basis: next, revisions: after), storedValidationToken: store.validationToken()))
        // A save for another cursor makes the stored inventory unusable.
        #expect(store.save(items, validationToken: "photos-inventory-v2:event-8").succeeded)
        #expect(!TimelineLocalRebuild.isEligible(conditions, storedValidationToken: store.validationToken()))
    }

    @Test func theSourcePolicyChoosesTheStoreOnlyWhereTheSDKCacheWasChosen() {
        func source(
            cached: String?, current: String = "photos-inventory-v2:event-7", pending: Bool = false,
            unmaterialized: Bool = false, local: Bool
        ) -> TimelineInventorySource {
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: cached, currentEventToken: current, hasPendingLocalUploads: pending,
                hasUnmaterializedLocalEvidence: unmaterialized, canRebuildLocally: local)
        }
        let same = "photos-inventory-v2:event-7"
        #expect(source(cached: same, local: true) == .localStore)
        #expect(source(cached: same, local: false) == .sdkCache)
        // Whatever sent the load to a listing before still does.
        #expect(source(cached: "photos-inventory-v2:event-6", local: true) == .authoritativePhotosList)
        #expect(source(cached: nil, local: true) == .authoritativePhotosList)
        #expect(source(cached: same, pending: true, local: true) == .authoritativePhotosList)
        #expect(source(cached: same, unmaterialized: true, local: true) == .authoritativePhotosList)
    }
}
