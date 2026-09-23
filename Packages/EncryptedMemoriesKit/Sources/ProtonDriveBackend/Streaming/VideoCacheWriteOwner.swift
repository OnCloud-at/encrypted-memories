import Foundation

/// A player can retire its writes without clearing another player's encrypted cache.
final class VideoCacheWriteOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false

    func close() { lock.withLock { isClosed = true } }

    func performIfOpen<T>(_ operation: () -> T) -> T? {
        lock.withLock {
            guard !isClosed else { return nil }
            return operation()
        }
    }
}
