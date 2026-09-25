import Foundation
import Photos

/// Runs one PhotoKit request. Cancelling the task cancels the request, so an iCloud download stops when the
/// grid scrolls on, the viewer pages away, or the account tears down. The result arrives exactly once: the
/// value, or nil on cancellation.
enum PhotoKitRequest {
    static func perform<Value: Sendable>(
        _ start: (_ finish: @escaping @Sendable (Value?) -> Void) -> PHImageRequestID
    ) async -> Value? {
        let request = Pending<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation) { start { request.finish($0) } }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private final class Pending<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var requestID: PHImageRequestID?
        private var cancelled = false

        func start(_ continuation: CheckedContinuation<Value?, Never>, request: () -> PHImageRequestID) {
            let isCancelled = lock.withLock {
                self.continuation = continuation
                return cancelled
            }
            guard !isCancelled else {
                finish(nil)
                return
            }
            let id = request()
            let cancelNow = lock.withLock {
                requestID = id
                return cancelled
            }
            if cancelNow { PHImageManager.default().cancelImageRequest(id) }
        }

        func finish(_ value: Value?) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }

        func cancel() {
            let id = lock.withLock {
                cancelled = true
                return requestID
            }
            if let id { PHImageManager.default().cancelImageRequest(id) }
            finish(nil)
        }
    }
}

/// PhotoKit's image request, answered as a `CGImage` with PhotoKit's "degraded" flag (a quick, lower-quality
/// version that a better one may follow). PhotoKit hands out images as the platform image type, so
/// the platform media adapters implement it once (`PhotoKitPlatformImages.request` in MediaCacheUIKitAdapter and
/// MediaCacheAppKitAdapter) and hosts pass it in. This adapter stays free of UI frameworks.
public typealias PhotoKitImageRequest =
    @Sendable (
        _ asset: PHAsset,
        _ targetSize: CGSize,
        _ contentMode: PHImageContentMode,
        _ options: PHImageRequestOptions,
        _ resultHandler: @escaping @Sendable (_ image: CGImage?, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID
