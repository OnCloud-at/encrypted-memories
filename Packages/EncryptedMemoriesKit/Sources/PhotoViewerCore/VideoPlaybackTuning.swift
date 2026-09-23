import AVFoundation
import PhotosCore

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
        // Preserve native AVFoundation waiting, including AVKit pause, replay, PiP, and interruption behavior.
        player.automaticallyWaitsToMinimizeStalling = true
        if isStreaming {
            item.preferredForwardBufferDuration = streamingForwardBuffer
        }
    }

    /// Loads the duration from the asset and reports it to the loader. Used where no player-item observation
    /// exists; the load is cheap because the header is already being fetched for playback.
    public static func reportDuration(of asset: StreamingVideoAsset) async {
        guard let tuning = asset.readAheadTuning,
            let duration = try? await asset.asset.load(.duration),
            duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0
        else { return }
        tuning.useReadAhead(forPlaybackDuration: duration.seconds)
    }

    /// Reports the clip's duration to the loader once AVFoundation knows it, so the loader can size its
    /// read-ahead from the real bitrate. A clip of unknown or indefinite length keeps the default window.
    public static func reportDuration(of item: AVPlayerItem, to asset: StreamingVideoAsset?) {
        guard let tuning = asset?.readAheadTuning else { return }
        let duration = item.duration
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else { return }
        tuning.useReadAhead(forPlaybackDuration: duration.seconds)
    }
}
