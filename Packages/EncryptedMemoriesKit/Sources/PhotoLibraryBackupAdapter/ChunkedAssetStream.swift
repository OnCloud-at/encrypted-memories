import Foundation

/// The chunk loop of the PhotoKit enumerators: it opens one indexed source off the calling actor and hands its items
/// to `emit` in index ranges of `chunkSize`, each inside an autorelease pool, so transient PhotoKit memory stays bounded.
enum ChunkedAssetStream {
    /// `open` runs once inside the detached task. `count` reads the size of the opened source. `emit` receives one
    /// chunk range and yields its output. The loop starts at `startOffset`, clamped to the source, so a library that
    /// shrank since a saved cursor yields nothing and ends. Cancellation finishes the stream with a
    /// `CancellationError`, and the end of the stream cancels the task.
    static func make<Source, Output: Sendable>(
        startOffset: Int = 0,
        chunkSize: Int,
        open: @escaping @Sendable () -> Source,
        count: @escaping @Sendable (Source) -> Int,
        emit: @escaping @Sendable (Source, Range<Int>, AsyncThrowingStream<Output, any Error>.Continuation) -> Void
    ) -> AsyncThrowingStream<Output, any Error> {
        let chunkSize = max(1, chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let source = open()
                let total = count(source)
                var index = min(max(0, startOffset), total)
                while index < total {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, total)
                    autoreleasepool { emit(source, index..<upperBound, continuation) }
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
