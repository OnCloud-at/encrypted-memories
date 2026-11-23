import Foundation

/// Prepares a video and asks again behind the loading indicator while the failure goes away by itself: a rate limit,
/// a network failure or a timeout, and once for missing video information. The waits come from
/// `VideoPlaybackError.silentRetryDelays`. A failure that another attempt cannot change (no network for this app, a
/// refused connection) ends the loop at once, and so does a cancelled task, so a host that cancels the preparation
/// when the person moves on never asks again.
public enum VideoPreparationRetry {
    /// The wait before the next silent attempt after `error`, or nil when the failure shows now. Both viewers ask this,
    /// so the macOS and the iOS preparation retry by the same rule.
    public static func nextDelay(
        after error: any Error, retries: Int, delays: (VideoPlaybackError) -> [Duration]
    ) -> Duration? {
        guard !VideoPlaybackError.repeatCannotHelp(error) else { return nil }
        return delays(VideoPlaybackError.classify(error)).dropFirst(retries).first
    }

    /// Returns the result of the first attempt that succeeds. Throws the failure of the last attempt when its class
    /// has no wait left, and a `CancellationError` when the task is cancelled during a wait.
    public static func run<Result>(
        delays: (VideoPlaybackError) -> [Duration] = { $0.silentRetryDelays },
        wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        attempt: () async throws -> Result
    ) async throws -> Result {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled, let delay = nextDelay(after: error, retries: retries, delays: delays)
                else { throw error }
                await wait(delay)
                try Task.checkCancellation()
                retries += 1
            }
        }
    }
}
