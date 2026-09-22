import Foundation

/// Owner close finishes a pending request. AVFoundation cancellation already owns its terminal result.
final class VideoLoadingRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Error?) -> Void)?

    init(_ handler: @escaping @Sendable (Error?) -> Void) { self.handler = handler }

    func finish(_ error: Error?) {
        let callback = lock.withLock {
            let callback = handler
            handler = nil
            return callback
        }
        callback?(error)
    }

    func cancel() { lock.withLock { handler = nil } }
}
