import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite @MainActor struct TimelineThumbnailOverlayResolverTests {
    private actor MetadataStub: PhotoMetadataProvider {
        let values: [PhotoUID: Double]
        let delay: Duration
        private var requested: [PhotoUID] = []

        init(values: [PhotoUID: Double], delay: Duration = .zero) {
            self.values = values
            self.delay = delay
        }

        func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
            requested.append(uid)
            if delay > .zero { try await Task.sleep(for: delay) }
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
        // A slow provider keeps the publication behind the test. A fixed number of yields cannot wait for it.
        let provider = MetadataStub(values: [video.uid: 42.4], delay: .milliseconds(50))
        let resolver = TimelineThumbnailOverlayResolver(
            items: [video, known, photo],
            settleDelay: .zero,
            maxConcurrentLoads: 1
        )

        resolver.noteVisible([photo.uid, known.uid, video.uid], metadataProvider: provider)
        #expect(await waitUntil { @MainActor in resolver.overlay(for: video.uid).durationText != nil })

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
        #expect(await waitUntil { @MainActor in resolver.overlay(for: second.uid).durationText != nil })

        #expect(resolver.overlay(for: first.uid).durationText == nil)
        #expect(resolver.overlay(for: second.uid).durationText == "0:20")
        #expect(await provider.requests() == [second.uid])
    }

    @Test func itemRefreshKeepsResolvedDurationWhenEnumerationStillOmitsIt() async {
        let video = item("video", mime: "video/quicktime")
        let provider = MetadataStub(values: [video.uid: 9], delay: .milliseconds(50))
        let resolver = TimelineThumbnailOverlayResolver(
            items: [video],
            settleDelay: .zero,
            maxConcurrentLoads: 1
        )
        resolver.noteVisible([video.uid], metadataProvider: provider)
        #expect(await waitUntil { @MainActor in resolver.overlay(for: video.uid).durationText != nil })

        resolver.update(items: [video])
        #expect(resolver.overlay(for: video.uid).durationText == "0:09")
    }
}
