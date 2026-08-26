import Foundation
import PhotosCore
import Testing
import TimelineCore

@Suite struct TimelineThumbnailOverlayPolicyTests {
    private func item(
        mediaType: String,
        duration: Double? = nil,
        tags: Set<PhotoTag> = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: UUID().uuidString),
            captureTime: .distantPast,
            mediaType: mediaType,
            durationSeconds: duration,
            tags: tags
        )
    }

    @Test func videoDurationUsesCompactPositionalFormatting() {
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: 645) == "10:45")
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: 3_661) == "1:01:01")
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: 59.6) == "1:00")
    }

    @Test func invalidOrMissingDurationsDoNotCreateMisleadingLabels() {
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: nil) == nil)
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: 0) == nil)
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: -.infinity) == nil)
        #expect(TimelineThumbnailOverlayPolicy.durationText(for: .nan) == nil)
    }

    @Test func photoDomainMappingIsSharedAndTypeAware() {
        let video = TimelineThumbnailOverlayPolicy.overlay(
            for: item(mediaType: "video/quicktime", duration: 645)
        )
        let raw = TimelineThumbnailOverlayPolicy.overlay(
            for: item(mediaType: "image/x-adobe-dng", duration: 645)
        )
        let taggedRAW = TimelineThumbnailOverlayPolicy.overlay(
            for: item(mediaType: "image/jpeg", tags: [.raw])
        )

        #expect(video.durationText == "10:45")
        #expect(video.showsRAW == false)
        #expect(raw.durationText == nil)
        #expect(raw.showsRAW)
        #expect(taggedRAW.showsRAW)
    }
}
