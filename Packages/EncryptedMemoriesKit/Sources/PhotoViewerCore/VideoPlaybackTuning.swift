import AVFoundation

/// One place for the playback buffering policy of a streamed Proton video.
///
/// AVFoundation owns the bandwidth arithmetic: with `automaticallyWaitsToMinimizeStalling` the player
/// measures its own throughput and starts playback only when it expects no stall, and it reports that
/// judgement through `AVPlayerItem.isPlaybackLikelyToKeepUp`. The app therefore never computes a start
/// buffer itself. What the app owns is the supply: how far ahead the player may read, and how many
/// encrypted blocks the resource loader warms before the player asks.
public enum VideoPlaybackTuning {
    /// How far ahead the player should keep bytes for a range-streamed asset. Zero would let
    /// AVFoundation pick a window sized for an HTTP server; a custom loader that fetches and decrypts
    /// 4 MB blocks needs a wider one to stay in front of playback.
    public static let streamingForwardBuffer: TimeInterval = 30

    /// Applies the streaming policy. `isStreaming` is false for a fully downloaded local file, where
    /// AVFoundation reads from disk and needs no forward window.
    public static func configure(player: AVPlayer, item: AVPlayerItem, isStreaming: Bool) {
        // The player waits until its own estimate says playback can continue without stalling.
        player.automaticallyWaitsToMinimizeStalling = true
        if isStreaming {
            item.preferredForwardBufferDuration = streamingForwardBuffer
        }
    }
}
