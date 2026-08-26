import Foundation

/// Sleep seam so tests drive the runner's backoff waits deterministically.
public protocol BackupSchedulerClock: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

/// Production clock - real suspension via `Task.sleep`.
public struct BackupContinuousClock: BackupSchedulerClock {
    public init() {}

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
