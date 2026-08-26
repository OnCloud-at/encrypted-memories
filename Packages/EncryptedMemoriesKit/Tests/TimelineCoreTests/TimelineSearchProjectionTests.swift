import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineSearchProjectionTests {
    @Test func favoritesAndSemanticMatchesShareOneCanonicalProjection() {
        let favorite = item("favorite", seconds: 1)
        let semantic = item("semantic", seconds: 2)
        let other = item("other", seconds: 3)
        let sections = [section([favorite, semantic, other])]
        let key = TimelineSearchProjectionKey(
            sourceRevision: 7,
            query: "favorites",
            context: TimelineSearchContext(favoriteUIDs: [favorite.uid]),
            semanticMatches: [semantic.uid]
        )

        let projection = TimelineSearchProjection(key: key, sections: sections)

        #expect(projection.snapshot.items.map(\.uid) == [favorite.uid, semantic.uid])
        #expect(projection.sections.flatMap(\.items) == projection.snapshot.items)
    }

    @Test func emptyQueryPreservesCanonicalTimeline() {
        let a = item("a", seconds: 1)
        let b = item("b", seconds: 2)
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "   ",
            context: TimelineSearchContext(),
            semanticMatches: [b.uid]
        )

        let projection = TimelineSearchProjection(key: key, sections: [section([a, b])])

        #expect(projection.snapshot.items.map(\.uid) == [a.uid, b.uid])
    }

    @Test func coordinatorDropsSupersededLargeLibraryResult() async {
        let items = (0..<30_000).map { item("item-\($0)", seconds: Double($0)) }
        let sections = [section(items)]
        let coordinator = TimelineSearchProjectionCoordinator()
        let staleKey = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "does-not-exist",
            context: TimelineSearchContext(),
            semanticMatches: nil
        )
        let newestKey = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "item-29999",
            context: TimelineSearchContext(),
            semanticMatches: nil
        )

        let staleTask = Task { await coordinator.resolve(sections: sections, key: staleKey) }
        await Task.yield()
        let newest = await coordinator.resolve(sections: sections, key: newestKey)
        let stale = await staleTask.value

        #expect(stale == nil)
        #expect(newest?.key == newestKey)
        #expect(newest?.snapshot.items.map(\.uid.nodeID) == ["item-29999"])
    }

    @Test func cancelReleasesCachedProjection() async {
        let coordinator = TimelineSearchProjectionCoordinator()
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "item",
            context: TimelineSearchContext(),
            semanticMatches: nil
        )
        let sections = [section([item("item", seconds: 1)])]

        let first = await coordinator.resolve(sections: sections, key: key)
        await coordinator.cancel()
        let rebuilt = await coordinator.resolve(sections: sections, key: key)

        #expect(first?.revision == 1)
        #expect(rebuilt?.revision == 3)
    }

    @Test func refinementStacksFavoritesAndVideoWithAndSemantics() {
        let favoriteVideo = item("favorite-video", seconds: 1, mediaType: "video/quicktime")
        let favoritePhoto = item("favorite-photo", seconds: 2)
        let plainVideo = item("plain-video", seconds: 3, mediaType: "video/quicktime")
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "",
            context: TimelineSearchContext(favoriteUIDs: [favoriteVideo.uid, favoritePhoto.uid]),
            semanticMatches: nil,
            refinement: TimelineRefinement(favoritesOnly: true, mediaKinds: [.video])
        )

        let projection = TimelineSearchProjection(
            key: key,
            sections: [section([favoriteVideo, favoritePhoto, plainVideo])]
        )

        #expect(projection.snapshot.items.map(\.uid) == [favoriteVideo.uid])
    }

    @Test func mediaKindsUseOrSemanticsAndPreserveSelectionIdentity() {
        let photo = item("photo", seconds: 1)
        let video = item("video", seconds: 2, mediaType: "video/quicktime")
        let refinement = TimelineRefinement(mediaKinds: [.photo, .video])
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "",
            context: TimelineSearchContext(),
            semanticMatches: nil,
            refinement: refinement
        )

        let projection = TimelineSearchProjection(key: key, sections: [section([photo, video])])

        #expect(refinement.isActive)
        #expect(projection.snapshot.items.map(\.uid) == [photo.uid, video.uid])
        #expect(projection.presentationItems.map(\.uid) == [video.uid, photo.uid])
    }

    @Test func favoriteRefinementUsesAuthoritativeMembershipNotOptionalTags() {
        let contextFavorite = item("context-favorite", seconds: 1)
        let taggedFavorite = item("tagged-favorite", seconds: 2, tags: [.favorites])
        let plain = item("plain", seconds: 3)
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "",
            context: TimelineSearchContext(favoriteUIDs: [contextFavorite.uid]),
            semanticMatches: nil,
            refinement: TimelineRefinement(favoritesOnly: true)
        )

        let projection = TimelineSearchProjection(
            key: key,
            sections: [section([contextFavorite, taggedFavorite, plain])]
        )

        #expect(projection.snapshot.items.map(\.uid) == [contextFavorite.uid])
    }

    @Test func refinementRemainsAnAndConstraintForLexicalAndSemanticMatches() {
        let lexicalPhoto = item("holiday", seconds: 1)
        let semanticVideo = item("clip", seconds: 2, mediaType: "video/quicktime")
        let lexicalVideo = item("holiday-movie", seconds: 3, mediaType: "video/quicktime")
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "holiday",
            context: TimelineSearchContext(),
            semanticMatches: [semanticVideo.uid],
            refinement: TimelineRefinement(mediaKinds: [.video])
        )

        let projection = TimelineSearchProjection(
            key: key,
            sections: [section([lexicalPhoto, semanticVideo, lexicalVideo])]
        )

        #expect(projection.snapshot.items.map(\.uid) == [semanticVideo.uid, lexicalVideo.uid])
    }

    private func item(
        _ id: String,
        seconds: Double,
        mediaType: String = "image/jpeg",
        tags: Set<PhotoTag> = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: seconds),
            mediaType: mediaType,
            tags: tags
        )
    }

    private func section(_ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: "library", date: .distantPast, title: "", items: items)
    }
}
