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

    // MARK: - Block layout validation (D2)

    @Test(arguments: [0, 100])
    func legacyWebWriterMayAppendAnExtraZeroBlockSize(size: Int) throws {
        let result = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: size == 0 ? [] : blockInfos([1]),
            blockSizes: size == 0 ? [0] : [size, 0], declaredSize: size)
        #expect(result.totalSize == size)
        #expect(result.blocks.count == (size == 0 ? 0 : 1))
    }

    private func blockInfos(_ indexes: [Int]) -> [BlockInfo] {
        indexes.map { BlockInfo(index: $0, bareURL: "u\($0)", url: nil, token: "t\($0)") }
    }

    @Test func validatedVideoBlocksAcceptsConsistentSingleBlock() throws {
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: blockInfos([1]),
            blockSizes: [100],
            declaredSize: 100
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].index == 1)
        #expect(blocks[0].clearOffset == 0)
        #expect(blocks[0].clearSize == 100)
        #expect(total == 100)
    }

    @Test func validatedVideoBlocksAcceptsMultiBlockLayoutWithShortTail() throws {
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: blockInfos([1, 2, 3]),
            blockSizes: [100, 100, 40],
            declaredSize: 240
        )
        #expect(blocks.map(\.index) == [1, 2, 3])
        #expect(blocks.map(\.clearOffset) == [0, 100, 200])
        #expect(blocks.map(\.clearSize) == [100, 100, 40])
        #expect(total == 240)
    }

    @Test func validatedVideoBlocksFallsBackToSummedSizesWhenDeclaredMissingOrZero() throws {
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: blockInfos([1, 2]),
            blockSizes: [100, 50],
            declaredSize: 0
        )
        #expect(total == 150)
        #expect(blocks.map(\.clearSize) == [100, 50])
    }

    @Test func validatedVideoBlocksRejectsCountMismatch() {
        #expect(throws: StreamingError.self) {
            _ = try PhotoVideoStreamSource.validatedVideoBlocks(
                blockInfos: blockInfos([1, 2]),
                blockSizes: [100],
                declaredSize: 100
            )
        }
    }

    @Test func validatedVideoBlocksRejectsPositiveDeclaredSizeWithoutBlocks() {
        #expect(throws: StreamingError.self) {
            _ = try PhotoVideoStreamSource.validatedVideoBlocks(
                blockInfos: [],
                blockSizes: [],
                declaredSize: 100
            )
        }
    }

    @Test func validatedVideoBlocksAcceptsEmptyFile() throws {
        // An empty file has no blocks and no declared size; summed fallback yields zero.
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: [],
            blockSizes: [],
            declaredSize: 0
        )
        #expect(blocks.isEmpty)
        #expect(total == 0)
    }

    @Test func validatedVideoBlocksAllowsZeroSizeBlocksWhenSumMatches() throws {
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: blockInfos([1, 2, 3]),
            blockSizes: [100, 0, 100],
            declaredSize: 200
        )
        #expect(blocks.map(\.clearSize) == [100, 0, 100])
        #expect(total == 200)
    }

    @Test(arguments: [
        (200, [100, 50]),  // sum smaller than declared
        (100, [100, 50]),  // sum greater than declared
    ])
    func validatedVideoBlocksRejectsDeclaredSizeMismatch(declaredSize: Int, blockSizes: [Int]) {
        #expect(throws: StreamingError.self) {
            _ = try PhotoVideoStreamSource.validatedVideoBlocks(
                blockInfos: blockInfos(Array(1...blockSizes.count)),
                blockSizes: blockSizes,
                declaredSize: declaredSize
            )
        }
    }

    @Test func validatedVideoBlocksRejectsNegativeBlockSize() {
        #expect(throws: StreamingError.self) {
            _ = try PhotoVideoStreamSource.validatedVideoBlocks(
                blockInfos: blockInfos([1]),
                blockSizes: [-1],
                declaredSize: 0
            )
        }
    }

    @Test func validatedVideoBlocksRejectsOverflowingSummedSize() {
        #expect(throws: StreamingError.self) {
            _ = try PhotoVideoStreamSource.validatedVideoBlocks(
                blockInfos: blockInfos([1, 2]),
                blockSizes: [Int.max, 1],
                declaredSize: 0
            )
        }
    }

    @Test func validatedVideoBlocksAcceptsAllZeroBlocksWhenDeclaredAlsoZero() throws {
        // All blocks have size 0, declaredSize 0: sum matches declared.
        let (blocks, total) = try PhotoVideoStreamSource.validatedVideoBlocks(
            blockInfos: blockInfos([1, 2]),
            blockSizes: [0, 0],
            declaredSize: 0
        )
        #expect(blocks.map(\.clearSize) == [0, 0])
        #expect(total == 0)
    }
}
