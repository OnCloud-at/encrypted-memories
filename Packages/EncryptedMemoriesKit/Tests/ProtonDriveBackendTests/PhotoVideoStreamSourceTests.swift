import Testing

@testable import ProtonDriveBackend

struct PhotoVideoStreamSourceTests {
    private func blocks(_ range: Range<Int>) -> [BlockInfo] {
        range.map { BlockInfo(index: $0, bareURL: nil, url: nil, token: nil) }
    }

    @Test func fullRevisionPageAdvancesFromItsMaximumIndex() throws {
        let next = try PhotoVideoStreamSource.nextRevisionPageStart(
            previousStart: 1,
            blocks: blocks(1..<501),
            pageSize: 500
        )
        #expect(next == 501)
    }

    @Test func reorderedFullRevisionPageStillAdvances() throws {
        let next = try PhotoVideoStreamSource.nextRevisionPageStart(
            previousStart: 1,
            blocks: Array(blocks(1..<501).reversed()),
            pageSize: 500
        )
        #expect(next == 501)
    }

    @Test func collectionAcceptsFullPageThenPartialTerminalPage() async throws {
        var starts: [Int] = []
        let (collected, xAttr) = try await PhotoVideoStreamSource.collectRevisionBlocks(pageSize: 500) { start in
            starts.append(start)
            if start == 1 {
                return (blocks: blocks(1..<501), xAttr: "first")
            }
            return (blocks: blocks(501..<601), xAttr: "second")
        }

        #expect(starts == [1, 501])
        #expect(collected.map(\.index) == Array(1...600))
        #expect(xAttr == "first")
    }

    @Test func collectionAcceptsFullPageThenEmptyTerminalPage() async throws {
        var starts: [Int] = []
        let (collected, _) = try await PhotoVideoStreamSource.collectRevisionBlocks(pageSize: 500) { start in
            starts.append(start)
            return start == 1
                ? (blocks: blocks(1..<501), xAttr: nil)
                : (blocks: [], xAttr: "terminal")
        }

        #expect(starts == [1, 501])
        #expect(collected.count == 500)
    }

    @Test func collectionPropagatesCancellationFromPageFetch() async {
        await #expect(throws: CancellationError.self) {
            try await PhotoVideoStreamSource.collectRevisionBlocks(pageSize: 500) { _ in
                throw CancellationError()
            }
        }
    }

    @Test(arguments: [
        (501, Array(1..<501)),
        (501, Array(400..<900)),
        (1, Array(1..<500) + [501]),
        (1, Array(1..<500) + [499]),
    ])
    func repeatedRegressionOrOverflowPageThrows(
        previousStart: Int,
        page: [Int]
    ) {
        #expect(throws: StreamingError.revisionPaginationNoProgress) {
            try PhotoVideoStreamSource.nextRevisionPageStart(
                previousStart: previousStart,
                blocks: page.map { BlockInfo(index: $0, bareURL: nil, url: nil, token: nil) },
                pageSize: 500
            )
        }
    }

    @Test func overflowPageThrows() {
        #expect(throws: StreamingError.revisionPaginationNoProgress) {
            try PhotoVideoStreamSource.nextRevisionPageStart(
                previousStart: Int.max,
                blocks: [BlockInfo(index: Int.max, bareURL: nil, url: nil, token: nil)],
                pageSize: 1
            )
        }
    }

    @Test func oversizedPageThrows() {
        #expect(throws: StreamingError.revisionPaginationNoProgress) {
            try PhotoVideoStreamSource.nextRevisionPageStart(
                previousStart: 1,
                blocks: blocks(1..<502),
                pageSize: 500
            )
        }
    }
}
