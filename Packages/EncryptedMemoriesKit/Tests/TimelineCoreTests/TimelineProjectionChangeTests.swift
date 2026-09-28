import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineProjectionChangeTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func item(_ node: String, second: TimeInterval, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "vol", nodeID: node), captureTime: base.addingTimeInterval(second),
            mediaType: mediaType)
    }

    private func projection(_ items: [PhotoItem]) -> TimelineContentProjection {
        TimelineContentProjection(sections: [TimelineSection(id: "all", date: base, title: "", items: items)])
    }

    @Test func anUnchangedTimelineReportsNoChange() {
        let shown = projection([item("a", second: 0), item("b", second: 10)])
        let change = TimelineProjectionChange(
            from: shown.snapshot, to: projection([item("a", second: 0), item("b", second: 10)]))

        #expect(!change.contentChanged)
        #expect(!change.identitiesChanged)
        #expect(change.addedUIDs.isEmpty)
        #expect(change.uids == shown.uids)
    }

    @Test func aMetadataChangeKeepsTheIdentities() {
        let shown = projection([item("a", second: 0), item("b", second: 10)])
        let edited = item("b", second: 10, mediaType: "image/heic")
        let change = TimelineProjectionChange(from: shown.snapshot, to: projection([item("a", second: 0), edited]))

        #expect(change.contentChanged)
        #expect(!change.identitiesChanged)
        #expect(change.addedUIDs.isEmpty)
    }

    @Test func newPhotosAreReportedInTimelineOrder() {
        let (a, b, c, d) = (item("a", second: 0), item("b", second: 10), item("c", second: 20), item("d", second: 30))
        let shown = projection([a, c])
        let next = projection([a, b, c, d])
        let change = TimelineProjectionChange(from: shown.snapshot, to: next)

        #expect(change.contentChanged)
        #expect(change.identitiesChanged)
        #expect(change.addedUIDs == [b.uid, d.uid])
        #expect(change.uids == next.uids)
    }

    @Test func aRemovedPhotoChangesTheIdentitiesWithoutAdditions() {
        let shown = projection([item("a", second: 0), item("b", second: 10)])
        let change = TimelineProjectionChange(from: shown.snapshot, to: projection([item("a", second: 0)]))

        #expect(change.contentChanged)
        #expect(change.identitiesChanged)
        #expect(change.addedUIDs.isEmpty)
    }
}
