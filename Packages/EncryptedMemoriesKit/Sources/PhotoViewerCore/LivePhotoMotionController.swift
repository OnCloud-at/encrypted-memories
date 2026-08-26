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
/// E2EE-safe: the clip uses the encrypted resource-loader path as regular video
/// (`makeStreamingAsset` using `protonvideo://`). Encrypted blocks are cached locally and decrypted only in
/// RAM, so plaintext motion-video files are never written. Unlike timeline videos, the clip is fully
/// pre-downloaded after the user requests playback, before `player` is exposed. Without a `player` (still loading), an active play intent
/// is retained until preparation finishes; `stop()` cancels that intent.
///
/// Deliberately carries no audio-session configuration: on macOS a plain `AVPlayer` mixes with system audio and
/// never ducks; on iOS the default (`.soloAmbient`) session already gives Live-Photo-correct behavior (obeys the
/// silence switch, plays through the speaker). Adding a category here is the one thing that would cause ducking.
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
    private var endObserver: NSObjectProtocol?
    private var preparationGeneration: UInt = 0
    /// Retains a press that began while the encrypted clip was still being prepared. Without this intent,
    /// `play()` was a permanent no-op until `player` existed, so pressing during the normal preload window
    /// could never start motion even when the player became ready while the finger was still down.
    public private(set) var isPlayRequested = false

    public init() {}

    /// Preloads the paired motion clip for a Live Photo. No-op for non-Live items / when no streamer is
    /// available (per `LivePhotoMotionPolicy`). `isStillCurrent` lets the caller abort if the user paged away
    /// mid-load, so a swiped-past item never attaches a player; any prior clip is torn down first.
    public func prepare(
        for item: PhotoItem, streamer: VideoStreamProvider?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        teardown()
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            let motionUID = item.relatedVideoUID, let streamer
        else { return }
        loadState = .loading
        let generation = preparationGeneration
        prepareTask = Task { [weak self] in
            do {
                // Download the encrypted clip into the local encrypted block cache. No plaintext reaches disk.
                try await streamer.prefetchEncrypted(for: motionUID)
                guard self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true else { return }
                // Build the streaming player. Its resource loader serves entirely from the local encrypted cache.
                let stream = try await streamer.makeStreamingAsset(for: motionUID)
                guard self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true else { return }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset))
                player.actionAtItemEnd = .pause
                player.automaticallyWaitsToMinimizeStalling = false
                // Wait until ready, then preroll - the clip is local + encrypted-cached, so this is fast.
                if let item = player.currentItem {
                    var tries = 0
                    while item.status == .unknown, !Task.isCancelled,
                        tries < LivePhotoMotionPolicy.prerollMaxTries
                    {
                        try await Task.sleep(
                            for: .milliseconds(LivePhotoMotionPolicy.prerollPollMilliseconds)
                        )
                        tries += 1
                    }
                    guard item.status == .readyToPlay,
                        self?.isCurrentPreparation(generation, isStillCurrent: isStillCurrent) == true
                    else {
                        self?.markPreparationFailed(generation, isStillCurrent: isStillCurrent)
                        return
                    }
                    player.preroll(atRate: 1) { _ in }
                }
                // Expose the player only after preparation. An active press starts playback as soon as it is ready.
                guard let self,
                    self.isCurrentPreparation(generation, isStillCurrent: isStillCurrent)
                else { return }
                self.asset = stream
                self.player = player
                self.loadState = .ready
                self.startPlaybackIfRequested()
            } catch is CancellationError {
                // Teardown already restored `.idle`; a replaced generation must not publish stale state.
            } catch {
                self?.markPreparationFailed(generation, isStillCurrent: isStillCurrent)
            }
        }
    }

    /// Plays the motion clip once from the start, with sound. Idempotent while already playing. `isMuted`/`volume`
    /// are reset every call (they persist on the `AVPlayer`), so a prior `stop()` can never leave the next play muted.
    public func play() {
        isPlayRequested = true
        startPlaybackIfRequested()
    }

    /// Requests playback and starts preparation only when the user invokes Live Photo motion. This keeps the
    /// expensive encrypted paired-clip preload out of ordinary page navigation.
    public func play(
        for item: PhotoItem,
        streamer: VideoStreamProvider?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            let streamer
        else { return }
        isPlayRequested = true
        if player != nil {
            startPlaybackIfRequested()
        } else if loadState == .idle || loadState == .failed {
            prepare(for: item, streamer: streamer, isStillCurrent: isStillCurrent)
            // `prepare` tears down the previous generation, including its play intent.
            isPlayRequested = true
        }
    }

    private func startPlaybackIfRequested() {
        guard isPlayRequested, let player, !isPlaying else { return }
        isPlaying = true
        player.isMuted = false
        player.volume = 1
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    /// Stops the motion clip and lets the viewer crossfade back to the still (release, or auto at end-of-clip).
    public func stop() {
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
        removeEndObserver()
        player?.pause()
        isPlayRequested = false
        isPlaying = false
        player = nil
        asset = nil
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
        loadState = .failed
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
