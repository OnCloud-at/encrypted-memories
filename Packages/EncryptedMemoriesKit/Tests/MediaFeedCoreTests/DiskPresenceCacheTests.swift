import PhotosCore
import Testing

@testable import MediaFeedCore

/// `PhotoUID` keys preserve coverage counts and prevent aliasing for IDs containing the `~` separator.
@Suite struct DiskPresenceCacheTests {
    private func uid(_ vol: String, _ node: String) -> PhotoUID { PhotoUID(volumeID: vol, nodeID: node) }

    @Test func tracksPresentSubset() {
        let cache = DiskPresenceCache()
        cache.beginTracking([uid("v", "a"), uid("v", "b"), uid("v", "c")])
        cache.set(uid("v", "a"), present: true)
        cache.set(uid("v", "b"), present: true)
        let cov = cache.coverage()
        #expect(cov.present == 2 && cov.total == 3)
        #expect(abs(cov.percent - 2.0 / 3.0) < 1e-12)
    }

    @Test func presenceSetBeforeTrackingIsCountedAtBeginTracking() {
        let cache = DiskPresenceCache()
        cache.set(uid("v", "a"), present: true)  // learned during a prior crawl pass
        cache.beginTracking([uid("v", "a"), uid("v", "b")])
        let cov = cache.coverage()
        #expect(cov.present == 1 && cov.total == 2)
    }

    @Test func replacingInventoryDropsOldPresenceButKeepsCurrentUnreportedItems() {
        let cache = DiskPresenceCache()
        let removed = uid("v", "removed")
        let retained = uid("v", "retained")
        cache.beginTracking([removed, retained])
        cache.set(removed, present: true)
        cache.set(retained, present: true)

        cache.beginTracking([retained], reporting: [])
        #expect(cache.coverage().total == 0)
        cache.beginTracking([removed, retained])
        #expect(cache.coverage().present == 1)
        #expect(cache.coverage().total == 2)
    }

    @Test func togglingPresenceDecrements() {
        let cache = DiskPresenceCache()
        cache.beginTracking([uid("v", "a")])
        cache.set(uid("v", "a"), present: true)
        #expect(cache.coverage().present == 1)
        cache.set(uid("v", "a"), present: false)  // e.g. evicted
        #expect(cache.coverage().present == 0)
    }

    @Test func emptyTrackingReportsFullCoverage() {
        // No tracked items means full coverage (percent 1).
        let cov = DiskPresenceCache().coverage()
        #expect(cov.present == 0 && cov.total == 0 && cov.percent == 1)
    }

    /// Two UIDs collide under separator concatenation; PhotoUID identity must keep them distinct.
    @Test func collidingStringKeysStayDistinctUnderPhotoUID() {
        let cache = DiskPresenceCache()
        let u1 = uid("a~b", "c")
        let u2 = uid("a", "b~c")
        cache.beginTracking([u1, u2])
        #expect(cache.coverage().total == 2)

        cache.set(u1, present: true)
        #expect(cache.coverage().present == 1, "marking u1 present must NOT also mark the aliasing u2 present")

        cache.set(u2, present: true)
        #expect(cache.coverage().present == 2)
    }
}
