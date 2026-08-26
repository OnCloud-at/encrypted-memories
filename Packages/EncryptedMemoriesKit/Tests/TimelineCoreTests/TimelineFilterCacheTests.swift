import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineFilterCacheTests {
    @Test func evictsLeastRecentlyUsedFilteredRoute() {
        var cache = TimelineFilterCache(maximumEntries: 2)
        let first = route("first")
        let second = route("second")
        let third = route("third")

        cache.insert(sections("first"), for: first, activeRoute: first)
        cache.insert(sections("second"), for: second, activeRoute: second)
        #expect(cache.load(first, activeRoute: first) != nil)

        cache.insert(sections("third"), for: third, activeRoute: third)

        #expect(cache.count == 2)
        #expect(cache.snapshot(for: first) != nil)
        #expect(cache.snapshot(for: second) == nil)
        #expect(cache.snapshot(for: third) != nil)
        #expect(cache.routesByRecency == [first, third])
    }

    @Test func activeRouteRemainsWhenItIsTheOnlyAllowedEntry() {
        var cache = TimelineFilterCache(maximumEntries: 1)
        let first = route("first")
        let second = route("second")

        cache.insert(sections("first"), for: first, activeRoute: first)
        cache.insert(sections("second"), for: second, activeRoute: second)

        #expect(cache.routes == Set([second]))
        #expect(cache.snapshot(for: first) == nil)
        #expect(cache.snapshot(for: second) != nil)
    }

    @Test func wholeLibraryAndTransientMapRoutesAreNotDuplicated() {
        var cache = TimelineFilterCache(maximumEntries: 2)

        cache.insert(sections("all"), for: .all, activeRoute: .all)
        cache.insert(sections("map"), for: .map, activeRoute: .map)

        #expect(cache.count == 0)
        #expect(cache.routes.isEmpty)
    }

    private func route(_ id: String) -> PhotoFilter {
        .album(id: id, title: id)
    }

    private func sections(_ id: String) -> [TimelineSection] {
        [
            TimelineSection(
                id: id,
                date: Date(timeIntervalSince1970: 1),
                title: id,
                items: [
                    PhotoItem(
                        uid: PhotoUID(volumeID: "volume", nodeID: id),
                        captureTime: Date(timeIntervalSince1970: 1),
                        mediaType: "image/jpeg"
                    )
                ]
            )
        ]
    }
}
