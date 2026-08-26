import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite @MainActor struct TimelineThumbnailOverlayResolverTests {
    private actor MetadataStub: PhotoMetadataProvider {
        let values: [PhotoUID: Double]
        private var requested: [PhotoUID] = []

        init(values: [PhotoUID: Double]) {
            self.values = values
        }

        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            requested.append(uid)
            return PhotoMetadata(durationSeconds: values[uid])
        }

        func requests() -> [PhotoUID] { requested }
    }

    private func item(
        _ node: String,
        mime: String,
        duration: Double? = nil
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: node),
            captureTime: .distantPast,
            mediaType: mime,
            durationSeconds: duration
        )
    }

    @Test func settledVisibleVideoResolvesMissingDurationOnly() async throws {
        let video = item("video", mime: "video/quicktime")
        let known = item("known", mime: "video/quicktime", duration: 15)
        let photo = item("photo", mime: "image/jpeg")
        let provider = MetadataStub(values: [video.uid: 42.4])
        let resolver = TimelineThumbnailOverlayResolver(
            items: [video, known, photo],
            settleDelay: .zero,
            maxConcurrentLoads: 1
        )

        resolver.noteVisible([photo.uid, known.uid, video.uid], metadataProvider: provider)
        for _ in 0..<100 where resolver.overlay(for: video.uid).durationText == nil {
            await Task.yield()
        }

        #expect(resolver.overlay(for: video.uid).durationText == "0:42")
        #expect(resolver.overlay(for: known.uid).durationText == "0:15")
        #expect(await provider.requests() == [video.uid])
    }

    @Test func changingViewportCancelsUnsettledMetadataWork() async throws {
        let first = item("first", mime: "video/quicktime")
        let second = item("second", mime: "video/quicktime")
        let provider = MetadataStub(values: [first.uid: 10, second.uid: 20])
        let resolver = TimelineThumbnailOverlayResolver(
            items: [first, second],
            settleDelay: .milliseconds(20),
            maxConcurrentLoads: 1
        )

        resolver.noteVisible([first.uid], metadataProvider: provider)
        resolver.noteVisible([second.uid], metadataProvider: provider)
        // This verifies cancellation and identity. Allow scheduler contention without duplicate requests.
        let timeout = ContinuousClock.now.advanced(by: .seconds(5))
        while resolver.overlay(for: second.uid).durationText == nil, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(resolver.overlay(for: first.uid).durationText == nil)
        #expect(resolver.overlay(for: second.uid).durationText == "0:20")
        #expect(await provider.requests() == [second.uid])
    }

    @Test func itemRefreshKeepsResolvedDurationWhenEnumerationStillOmitsIt() async {
        let video = item("video", mime: "video/quicktime")
        let provider = MetadataStub(values: [video.uid: 9])
        let resolver = TimelineThumbnailOverlayResolver(
            items: [video],
            settleDelay: .zero,
            maxConcurrentLoads: 1
        )
        resolver.noteVisible([video.uid], metadataProvider: provider)
        for _ in 0..<100 where resolver.overlay(for: video.uid).durationText == nil {
            await Task.yield()
        }

        resolver.update(items: [video])
        #expect(resolver.overlay(for: video.uid).durationText == "0:09")
    }
}
