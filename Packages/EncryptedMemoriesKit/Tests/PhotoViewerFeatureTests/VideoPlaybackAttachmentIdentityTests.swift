import AVFoundation
import Foundation
import Testing

@testable import PhotoViewerCore

@Suite("Video playback attachment identity")
struct VideoPlaybackAttachmentIdentityTests {
    @Test func priorAttachmentCannotMatchSameUIDReopen() {
        let oldPlayer = NSObject()
        let oldItem = NSObject()
        let newPlayer = NSObject()
        let newItem = NSObject()
        let current = VideoPlaybackAttachmentIdentity(
            generation: 2,
            player: newPlayer,
            item: newItem
        )

        #expect(!current.matches(generation: 1, player: oldPlayer, item: oldItem))
        #expect(!current.matches(generation: 2, player: oldPlayer, item: oldItem))
        #expect(current.matches(generation: 2, player: newPlayer, item: newItem))
    }

    @Test @MainActor func tuningPreservesNativeAutomaticWaiting() {
        let localItem = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/local-video.mov"))
        let localPlayer = AVPlayer(playerItem: localItem)
        localPlayer.automaticallyWaitsToMinimizeStalling = false

        VideoPlaybackTuning.configure(player: localPlayer, item: localItem, isStreaming: false)

        #expect(localPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(localItem.preferredForwardBufferDuration == 0)

        let streamItem = AVPlayerItem(url: URL(string: "protonvideo://asset/video.mov")!)
        let streamPlayer = AVPlayer(playerItem: streamItem)
        streamPlayer.automaticallyWaitsToMinimizeStalling = false

        VideoPlaybackTuning.configure(player: streamPlayer, item: streamItem, isStreaming: true)

        #expect(streamPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(streamItem.preferredForwardBufferDuration == VideoPlaybackTuning.streamingForwardBuffer)
    }

    @Test @MainActor func controllerKeepsPublicDeadlineLabel() {
        let controller = VideoPlaybackController(firstFrameDeadline: 1)
        #expect(controller.state == .idle)
    }
}
