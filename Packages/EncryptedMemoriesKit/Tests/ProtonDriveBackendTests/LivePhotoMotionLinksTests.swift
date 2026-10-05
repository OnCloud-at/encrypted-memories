import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

/// The listing names the related files of a Live Photo newest first and without a type. An edited Live Photo names its
/// adjustment data, its edited motion, its paired video, and its original photo.
@Suite
struct LivePhotoMotionLinksTests {
    private let types = [
        "plist": "application/xml",
        "paired": "video/quicktime",
        "edited": "video/quicktime",
        "original": "image/heic",
        "other": "application/octet-stream",
    ]

    @Test
    func aLivePhotoWithOneRelatedFileKeepsItWithoutAType() async throws {
        #expect(LivePhotoMotionLinks.motion(among: ["motion"], mimeTypes: [:]) == .video("motion"))
        #expect(LivePhotoMotionLinks.motion(among: [], mimeTypes: [:]) == .unknown)
        var reads = 0
        let answer = try await LivePhotoMotionLinks().types(for: [["motion"], []], evidence: [:]) { _ in
            reads += 1
            return [:]
        }
        #expect(reads == 0, "no read for one related file")
        #expect(answer.complete)
    }

    @Test
    func anEditedLivePhotoPlaysItsFirstVideoInsteadOfItsNewestRelatedFile() {
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "paired", "edited", "original"], mimeTypes: types)
                == .video("paired"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["other", "plist", "paired", "original"], mimeTypes: types)
                == .video("paired"))
        #expect(
            LivePhotoMotionLinks.motion(among: ["plist", "other", "original"], mimeTypes: types) == .noVideo,
            "a Live Photo without a video has no motion")
    }

    @Test
    func anUnknownTypeBeforeTheFirstVideoLeavesTheMotionUnknown() {
        #expect(LivePhotoMotionLinks.motion(among: ["plist", "unknown", "paired"], mimeTypes: types) == .unknown)
    }

    @Test
    func readsOnlyUnknownRelatedFilesOfLivePhotosWithSeveralRelatedFilesOnce() async throws {
        var links = LivePhotoMotionLinks()
        let related = [["single"], ["plist", "paired"], ["paired", "edited", "plist"]]
        let evidence = ["plist": "application/xml"]
        var reads: [[String]] = []

        let first = try await links.types(for: related, evidence: evidence) { linkIDs in
            reads.append(linkIDs)
            return ["paired": "video/quicktime", "plist": "text/plain"]
        }
        links.record(first.read)
        #expect(reads == [["paired", "edited"]])
        #expect(first.complete)
        #expect(first.types == ["plist": "application/xml", "paired": "video/quicktime", "edited": ""])
        #expect(LivePhotoMotionLinks.motion(among: ["edited", "plist"], mimeTypes: first.types) == .noVideo)

        let second = try await links.types(for: related, evidence: evidence) { linkIDs in
            reads.append(linkIDs)
            return [:]
        }
        #expect(reads.count == 1, "a read type stays valid for the session")
        #expect(second.types == first.types)
    }

    @Test
    func aFailedReadLeavesTheMotionUnknownAndReadsAgainNextTime() async throws {
        struct Offline: Error {}
        var links = LivePhotoMotionLinks()
        let related = [["plist", "paired"]]

        let failed = try await links.types(for: related, evidence: [:]) { _ in throw Offline() }
        links.record(failed.read)
        #expect(!failed.complete)
        #expect(failed.read.isEmpty)
        #expect(LivePhotoMotionLinks.motion(among: ["plist", "paired"], mimeTypes: failed.types) == .unknown)

        var reads = 0
        let retried = try await links.types(for: related, evidence: [:]) { _ in
            reads += 1
            return types
        }
        #expect(reads == 1)
        #expect(retried.complete)
        #expect(LivePhotoMotionLinks.motion(among: ["plist", "paired"], mimeTypes: retried.types) == .video("paired"))

        await #expect(throws: CancellationError.self) {
            _ = try await LivePhotoMotionLinks().types(for: related, evidence: [:]) { _ in throw CancellationError() }
        }
    }

    @Test
    func theTimelineShowsTheVideoAsTheMotionAndNoLiveControlWithoutAVideo() throws {
        let live = PhotoTag.livePhotos.rawValue
        let entries = try JSONDecoder().decode(
            [PhotosListEntry].self,
            from: Data(
                #"""
                [{"LinkID":"live","CaptureTime":1,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"paired"},{"LinkID":"original"}]},
                {"LinkID":"novideo","CaptureTime":2,"Tags":[3],"RelatedPhotos":[{"LinkID":"plist"},{"LinkID":"original"}]},
                {"LinkID":"single","CaptureTime":3,"Tags":[3],"RelatedPhotos":[{"LinkID":"motion"}]},
                {"LinkID":"unread","CaptureTime":4,"Tags":[3],"RelatedPhotos":[{"LinkID":"x"},{"LinkID":"y"}]}]
                """#
                .utf8))
        #expect(entries.allSatisfy { $0.tags == [live] })

        let items = DriveSDKBridge.group(entries, volumeID: "v", motionTypes: types).flatMap(\.items)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.uid.nodeID, $0) })

        #expect(byID["live"]?.isLivePhoto == true)
        #expect(byID["live"]?.relatedVideoID == "paired")
        #expect(byID["novideo"]?.isLivePhoto == false)
        #expect(byID["novideo"]?.relatedVideoID == nil)
        #expect(byID["single"]?.relatedVideoID == "motion")
        #expect(byID["unread"]?.isLivePhoto == true, "an unread type keeps the Live tag without a motion")
        #expect(byID["unread"]?.relatedVideoID == nil)
    }
}
