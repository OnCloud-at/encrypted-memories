import Foundation

/// How many encrypted blocks a streamed video keeps warm ahead of playback.
///
/// The window is expressed in seconds of playback, not in blocks: a 4K clip carries several times the bytes
/// of a 1080p clip for the same second, so a fixed block count buffers minutes of one and a few seconds of
/// the other. A slow server cannot be made faster, but the player only stalls once the buffer runs dry.
public enum VideoReadAheadWindow {
    /// Seconds of playback the deep read-ahead aims to hold.
    public static let targetSeconds: Double = 25

    /// Blocks to keep warm, or nil when the inputs prove nothing (no duration, empty file).
    ///
    /// - Parameters:
    ///   - totalSize: cleartext size of the whole clip in bytes.
    ///   - durationSeconds: playback duration as the player reports it.
    ///   - blockCount: number of encrypted blocks the clip has.
    ///   - minimumBlocks: never return less than the hot window.
    ///   - maximumBlocks: bound for a very high bitrate, so one clip cannot queue unbounded work.
    public static func blockCount(
        totalSize: Int,
        durationSeconds: Double,
        blockCount: Int,
        minimumBlocks: Int,
        maximumBlocks: Int,
        targetSeconds: Double = targetSeconds
    ) -> Int? {
        guard totalSize > 0, blockCount > 0, durationSeconds > 0.5, durationSeconds.isFinite,
            minimumBlocks <= maximumBlocks
        else { return nil }
        let averageBlockSize = Double(totalSize) / Double(blockCount)
        guard averageBlockSize >= 1 else { return nil }
        let bytesPerSecond = Double(totalSize) / durationSeconds
        let wanted = Int((targetSeconds * bytesPerSecond / averageBlockSize).rounded(.up))
        // A clip shorter than the target window needs no more blocks than it has.
        return min(max(wanted, minimumBlocks), maximumBlocks, max(blockCount, minimumBlocks))
    }
}
