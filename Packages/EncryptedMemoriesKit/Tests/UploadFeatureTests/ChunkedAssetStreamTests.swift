import Foundation
import XCTest

@testable import PhotoLibraryBackupAdapter

final class ChunkedAssetStreamTests: XCTestCase {
    private func stream(
        of items: [Int], startOffset: Int = 0, chunkSize: Int
    ) -> AsyncThrowingStream<[Int], any Error> {
        ChunkedAssetStream.make(
            startOffset: startOffset,
            chunkSize: chunkSize,
            open: { items },
            count: { $0.count },
            emit: { source, range, continuation in continuation.yield(Array(source[range])) })
    }

    /// Collects the chunks of a stream that ends. A stream that does not end fails the test after 100 chunks
    /// instead of hanging it.
    private func collect(_ stream: AsyncThrowingStream<[Int], any Error>) async throws -> [[Int]] {
        var chunks: [[Int]] = []
        for try await chunk in stream {
            chunks.append(chunk)
            if chunks.count > 100 {
                XCTFail("the stream does not end")
                break
            }
        }
        return chunks
    }

    func testTheItemsArriveInOrderInChunksOfTheRequestedSize() async throws {
        let chunks = try await collect(stream(of: Array(0..<10), chunkSize: 4))

        XCTAssertEqual(chunks, [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
    }

    func testASourceThatFillsWholeChunksEndsWithoutAnEmptyChunk() async throws {
        let all = try await collect(stream(of: Array(0..<6), chunkSize: 3))
        let resumed = try await collect(stream(of: Array(0..<6), startOffset: 3, chunkSize: 3))

        XCTAssertEqual(all, [[0, 1, 2], [3, 4, 5]], "the last chunk is included and no empty chunk follows")
        XCTAssertEqual(resumed, [[3, 4, 5]])
    }

    func testAnEmptySourceEndsWithoutAChunk() async throws {
        let chunks = try await collect(stream(of: [], chunkSize: 4))

        XCTAssertEqual(chunks, [])
    }

    func testAChunkSizeBelowOneStillAdvances() async throws {
        let chunks = try await collect(stream(of: [1, 2, 3], chunkSize: 0))

        XCTAssertEqual(chunks, [[1], [2], [3]])
    }

    func testTheScanResumesAtTheSavedOffset() async throws {
        let chunks = try await collect(stream(of: Array(0..<10), startOffset: 6, chunkSize: 3))

        XCTAssertEqual(chunks, [[6, 7, 8], [9]])
    }

    func testAnOffsetPastTheEndOfAShrunkSourceYieldsNothing() async throws {
        let chunks = try await collect(stream(of: Array(0..<5), startOffset: 9, chunkSize: 3))

        XCTAssertEqual(chunks, [])
    }

    func testANegativeOffsetStartsAtTheBeginning() async throws {
        let chunks = try await collect(stream(of: Array(0..<4), startOffset: -3, chunkSize: 2))

        XCTAssertEqual(chunks, [[0, 1], [2, 3]])
    }

    func testTheSourceIsOpenedOncePerStream() async throws {
        let opened = Counter()
        let stream: AsyncThrowingStream<[Int], any Error> = ChunkedAssetStream.make(
            chunkSize: 2,
            open: {
                opened.increment()
                return Array(0..<6)
            },
            count: { $0.count },
            emit: { source, range, continuation in continuation.yield(Array(source[range])) })

        _ = try await collect(stream)

        XCTAssertEqual(opened.value, 1)
    }

    func testTheEndOfTheStreamStopsTheEnumeration() async throws {
        let emitted = Counter()
        let atSecondChunk = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stream: AsyncThrowingStream<[Int], any Error> = ChunkedAssetStream.make(
            chunkSize: 1,
            open: { Array(0..<1000) },
            count: { $0.count },
            emit: { source, range, continuation in
                emitted.increment()
                if range.lowerBound == 1 {
                    atSecondChunk.signal()
                    release.wait()
                }
                continuation.yield(Array(source[range]))
            })

        let consumer = Task { () -> [[Int]] in
            var chunks: [[Int]] = []
            for try await chunk in stream { chunks.append(chunk) }
            return chunks
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                atSecondChunk.wait()
                continuation.resume()
            }
        }
        // The enumeration sits inside the second chunk. The consumer ends the stream by cancelling, and only then
        // does the second chunk finish. The enumeration must stop after that chunk.
        consumer.cancel()
        _ = await consumer.result
        release.signal()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(emitted.value, 2, "the enumeration must not run on after the stream ended")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
