import AVFoundation
import Foundation
import Observation
import PhotosCore

public enum LivePhotoMotionLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

/// Owns a Live Photo's paired *motion clip* - its single `AVPlayer`, the fully-preloaded encrypted streaming
/// asset, and the play/stop state the viewer crossfades on. Shared by the macOS and iOS viewers so Live Photo
/// motion behaves identically on both.
///
/// Cloud clips use the same encrypted resource-loader path as regular video
/// (`makeStreamingAsset` using `protonvideo://`). Encrypted blocks are cached locally and decrypted only in
/// RAM, so plaintext motion-video files are never written. Unlike timeline videos, the clip is fully
/// pre-downloaded when its photo becomes current, before `player` is exposed. Without a `player` (still loading), an active play intent
/// is retained until preparation finishes. An ordinary release cancels its press intent. Loops request playback
/// automatically and keep playing through presses and releases; teardown ends either mode.
///
/// Loops set the player's mute flag. This controller does not change the audio session.
@MainActor
@Observable
public final class LivePhotoMotionController {
    /// The motion clip's player once fully prepared, else nil. The viewer overlays it above the still image and
    /// crossfades it in on `isPlaying`.
    public private(set) var player: AVPlayer?

    /// Truthful preparation state for the shared viewer loading presentation. `ready` means the encrypted
    /// clip is fully prefetched and AVFoundation has accepted its player item for playback.
    public private(set) var loadState: LivePhotoMotionLoadState = .idle

    /// True while the motion clip is playing - the viewer crossfades the motion layer in/out on this.
    public private(set) var isPlaying = false

    /// Retains the streaming asset, the strong owner of the range resource-loader. AVFoundation holds it
    /// weakly, so it must live as long as the player.
    private var asset: StreamingVideoAsset?
    private var prepareTask: Task<Void, Never>?
    private var preparingMotionUID: PhotoUID?
    private var isLooping = false
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var preparationGeneration: UInt = 0
    /// Retains an ordinary press during preload. A looping photo requests playback automatically.
    public private(set) var isPlayRequested = false

    public init() {}

    /// Preloads the paired motion clip for a Live Photo. No-op for non-Live items / when no streamer is
    /// available (per `LivePhotoMotionPolicy`). `isStillCurrent` lets the caller abort if the user paged away
    /// mid-load. Repeated preparation of the same clip and playback style reuses its in-flight or ready player.
    /// A clip or playback-style change tears down its predecessor first.
    public func prepare(
        for item: PhotoItem, streamer: VideoStreamProvider?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            let motionUID = item.relatedVideoUID, let streamer, isStillCurrent()
        else {
            teardown()
            return
        }
        let loops = item.isLoopingLivePhoto
        guard preparingMotionUID != motionUID || isLooping != loops || (loadState != .loading && loadState != .ready)
        else { return }
        teardown()
        preparingMotionUID = motionUID
        isLooping = loops
        isPlayRequested = loops
        loadState = .loading
        let generation = preparationGeneration
        prepareTask = Task { [weak self] in
            do {
                // Download the encrypted clip into the local encrypted block cache. No plaintext reaches disk.
                try await streamer.prefetchEncrypted(for: motionUID)
                guard self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true else { return }
                // Build the streaming player. Its resource loader serves entirely from the local encrypted cache.
                let stream = try await streamer.makeStreamingAsset(for: motionUID)
                var adopted = false
                defer { if !adopted { stream.close() } }
                guard self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true else { return }
                let template = AVPlayerItem(asset: stream.asset)
                let player: AVPlayer
                let looper: AVPlayerLooper?
                if loops {
                    let duration = CMTimeGetSeconds(try await stream.asset.load(.duration))
                    guard duration.isFinite, duration > 0,
                        self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true
                    else {
                        self?.markPreparationFailed(generation, isStillCurrent: isStillCurrent)
                        return
                    }
                    let queue = AVQueuePlayer()
                    looper = AVPlayerLooper(player: queue, templateItem: template)
                    player = queue
                } else {
                    looper = nil
                    player = AVPlayer(playerItem: template)
                }
                player.actionAtItemEnd = loops ? .advance : .pause
                player.automaticallyWaitsToMinimizeStalling = false
                // Wait until ready, then preroll - the clip is local + encrypted-cached, so this is fast.
                var tries = 0
                while player.currentItem?.status != .readyToPlay, !Task.isCancelled,
                    player.currentItem?.status != .failed, tries < LivePhotoMotionPolicy.prerollMaxTries
                {
                    try await Task.sleep(for: .milliseconds(LivePhotoMotionPolicy.prerollPollMilliseconds))
                    tries += 1
                }
                guard player.currentItem?.status == .readyToPlay,
                    self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true
                else {
                    self?.markPreparationFailed(generation, isStillCurrent: isStillCurrent)
                    return
                }
                player.preroll(atRate: 1) { _ in }
                // Expose the player only after preparation. An active press starts playback as soon as it is ready.
                guard let self,
                    self.isCurrentPreparation(generation, isStillCurrent: isStillCurrent)
                else { return }
                self.asset = stream
                adopted = true
                self.player = player
                self.looper = looper
                self.loadState = .ready
                self.startPlaybackIfRequested()
            } catch is CancellationError {
                // Teardown already restored `.idle`; a replaced generation must not publish stale state.
            } catch {
                self?.markPreparationFailed(generation, isStillCurrent: isStillCurrent)
            }
        }
    }

    /// Requests ordinary motion once, with sound. An active playback stays active; automatic loops ignore presses.
    public func play() {
        guard !isLooping else { return }
        isPlayRequested = true
        startPlaybackIfRequested()
    }

    /// Reuses the current page's preload. An early press retains playback intent; a failed preload can retry.
    public func play(
        for item: PhotoItem,
        streamer: VideoStreamProvider?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            let streamer, isStillCurrent()
        else { return }
        prepare(for: item, streamer: streamer, isStillCurrent: isStillCurrent)
        guard !isLooping else { return }
        isPlayRequested = true
        startPlaybackIfRequested()
    }

    private func startPlaybackIfRequested() {
        guard isPlayRequested, let player, !isPlaying else { return }
        isPlaying = true
        player.isMuted = isLooping
        player.volume = 1
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        if !isLooping {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.stop() } }
        }
    }

    /// Stops ordinary motion on release or at its end. Automatic loops keep playing until teardown.
    public func stop() {
        guard !isLooping else { return }
        isPlayRequested = false
        guard isPlaying else { return }
        isPlaying = false
        player?.pause()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        removeEndObserver()
    }

    /// Cancels any in-flight preload and releases the player + streaming resource loader (viewer close / paging away).
    public func teardown() {
        preparationGeneration &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        preparingMotionUID = nil
        removeEndObserver()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        (player as? AVQueuePlayer)?.removeAllItems()
        isPlayRequested = false
        isPlaying = false
        player?.replaceCurrentItem(with: nil)
        player = nil
        asset?.close()
        asset = nil
        isLooping = false
        loadState = .idle
    }

    private func isCurrentPreparation(
        _ generation: UInt,
        isStillCurrent: @MainActor () -> Bool
    ) -> Bool {
        !Task.isCancelled && preparationGeneration == generation && isStillCurrent()
    }

    private func markPreparationFailed(
        _ generation: UInt,
        isStillCurrent: @MainActor () -> Bool
    ) {
        guard isCurrentPreparation(generation, isStillCurrent: isStillCurrent) else { return }
        PhotoDiagnostics.shared.increment("viewer.liveMotion.prepareFailure")
        loadState = .failed
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
