import PhotosCore

/// Pure, platform-neutral policy for Live Photo motion playback - the single source of truth for *which* items may
/// prepare motion and how long to wait for their (local, encrypted-cached) player to become ready.
/// Shared by the macOS and iOS viewers so the rule can never drift between platforms.
public enum LivePhotoMotionPolicy {
    /// Only ordinary Live Photos show a Live control and accept a press. Loops start without one.
    public static func acceptsPress(item: PhotoItem) -> Bool {
        item.isLivePhoto && !item.isLoopingLivePhoto
    }

    /// Poll interval (ms) while waiting for the preloaded clip's player item to reach `.readyToPlay`.
    public static let prerollPollMilliseconds = 20

    /// Max number of `prerollPollMilliseconds` polls before giving up. The clip is fully pre-downloaded, so
    /// readiness is normally near-instant; this bounds the wait so a stuck item can never hang the preload task.
    public static let prerollMaxTries = 100

    /// The wait before the one silent repeat of a failed preparation, or nil when the symbol shows now. The clip is a
    /// read, so a new attempt changes nothing. These show the symbol at once: a device without a network for this app,
    /// a refused connection, a cause that a repeat cannot change (a codec, a key, a self-contradicting block layout, a
    /// clip that is no video) and a cause that only the person can fix. The failure policy decides for a failure with a
    /// cause; a failure without one repeats once.
    public static func repeatDelay(after error: any Error) -> Duration? {
        guard !(error is VideoStreamError), !VideoPlaybackError.repeatCannotHelp(error),
            VideoPlaybackError.classify(error).isRetryable
        else { return nil }
        if let cause = (error as? any FailureClassifiable)?.failureCause,
            FailurePolicy.resolve(cause, situation: .background, safety: .safeRead).retry != .automatic
        {
            return nil
        }
        return VideoPlaybackError.silentRetryDelaySchedule.first
    }

    /// True only when a motion clip may be prepared for `item`: the item is a Live Photo with a paired video, and a
    /// streamer is available to fetch it.
    public static func shouldPrepare(item: PhotoItem, hasStreamer: Bool) -> Bool {
        item.isLivePhoto && item.relatedVideoUID != nil && hasStreamer
    }
}
