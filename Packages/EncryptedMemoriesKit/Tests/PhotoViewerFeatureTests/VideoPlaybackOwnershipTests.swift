import AVFoundation
import Foundation
import PhotosCore
import Testing

@testable import PhotoViewerCore

@Suite("Video playback ownership", .serialized)
struct VideoPlaybackOwnershipTests {
    @Test @MainActor func oldFailureCannotFailSameUIDReopenButCurrentFailureClosesOwner() async throws {
        let runtime = LibraryRuntimeState()
        let controller = VideoPlaybackController(runtimeState: runtime)
        let uid = PhotoUID(volumeID: "test", nodeID: "same")
        let oldOwner = HeldVideoLoader()
        let old = heldStream(owner: oldOwner)
        controller.playStreaming(asset: old.asset, retaining: old, uid: uid)
        let oldItem = try #require(controller.player?.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)

        let currentOwner = HeldVideoLoader()
        let current = heldStream(owner: currentOwner)
        controller.playStreaming(asset: current.asset, retaining: current, uid: uid)
        let currentPlayer = try #require(controller.player)
        defer { controller.teardown() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.player === currentPlayer)
        #expect(controller.state.error == nil)
        #expect(oldOwner.closeCount == 1)
        #expect(currentOwner.closeCount == 0)

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime, object: currentPlayer.currentItem)
        for _ in 0..<100 where controller.player != nil { await Task.yield() }
        #expect(controller.player == nil)
        #expect(controller.state.error != nil)
        #expect(currentOwner.closeCount == 1)
        #expect(runtime.snapshot().activeVideoPlaybackCount == 0)
    }

    @Test @MainActor func nativePauseBeforeFirstPlaybackDoesNotTimeOutOrResume() async throws {
        let controller = VideoPlaybackController(firstFrameDeadline: 0.03, runtimeState: LibraryRuntimeState())
        let owner = HeldVideoLoader()
        let stream = heldStream(owner: owner)
        controller.playStreaming(
            asset: stream.asset, retaining: stream, uid: PhotoUID(volumeID: "test", nodeID: "pause"))
        let player = try #require(controller.player)
        player.pause()
        defer { controller.teardown() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.player === player)
        #expect(player.timeControlStatus == .paused)
        #expect(controller.state.error == nil)
        #expect(!controller.state.isBusy)
        #expect(owner.closeCount == 0)
    }

    @Test @MainActor func teardownClosesItsAssetWhileAnotherPlayerStaysActive() {
        let runtime = LibraryRuntimeState()
        let initial = runtime.snapshot().activeVideoPlaybackCount
        let firstOwner = VideoOwnerProbe()
        let secondOwner = VideoOwnerProbe()
        let first = makeStream(owner: firstOwner)
        let second = makeStream(owner: secondOwner)
        let a = VideoPlaybackController(runtimeState: runtime)
        let b = VideoPlaybackController(runtimeState: runtime)
        let uid = PhotoUID(volumeID: "test", nodeID: "same")
        defer {
            a.teardown()
            b.teardown()
        }

        a.playStreaming(asset: first.asset, retaining: first, uid: uid)
        b.playStreaming(asset: second.asset, retaining: second, uid: uid)
        #expect(runtime.snapshot().activeVideoPlaybackCount == initial + 2)
        a.teardown()
        a.teardown()
        #expect(firstOwner.closeCount == 1)
        #expect(secondOwner.closeCount == 0)
        #expect(runtime.snapshot().activeVideoPlaybackCount == initial + 1)
        b.fail(.timedOut, uid: uid)
        #expect(secondOwner.closeCount == 1)
        #expect(runtime.snapshot().activeVideoPlaybackCount == initial)
        withExtendedLifetime((first, second)) {}
    }

    private func makeStream(owner: VideoOwnerProbe) -> StreamingVideoAsset {
        StreamingVideoAsset(
            asset: AVURLAsset(url: URL(string: "protonvideo://ownership/video.mov")!),
            retaining: owner
        )
    }

    private func heldStream(owner: HeldVideoLoader) -> StreamingVideoAsset {
        let asset = AVURLAsset(url: URL(string: "protonvideo://held/\(UUID().uuidString).mov")!)
        asset.resourceLoader.setDelegate(owner, queue: DispatchQueue(label: "video-owner-test"))
        return StreamingVideoAsset(asset: asset, retaining: owner)
    }
}

private final class VideoOwnerProbe: VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var closeCount: Int { lock.withLock { count } }
    func close() { lock.withLock { count += 1 } }
}

/// Keeps the real AVPlayer in preparation without network access or synthetic item-state overrides.
private final class HeldVideoLoader: NSObject, AVAssetResourceLoaderDelegate, VideoStreamLifetime, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var requests: [AVAssetResourceLoadingRequest] = []
    var closeCount: Int { lock.withLock { count } }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let closed = lock.withLock {
            guard count == 0 else { return true }
            requests.append(request)
            return false
        }
        if closed { request.finishLoading(with: CancellationError()) }
        return true
    }

    func close() {
        let pending = lock.withLock {
            count += 1
            let pending = requests
            requests.removeAll()
            return pending
        }
        for request in pending where !request.isCancelled && !request.isFinished {
            request.finishLoading(with: CancellationError())
        }
    }
}
