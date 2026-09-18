import Testing

@testable import PhotosCore

/// The read-ahead window must follow the clip's bitrate: the same seconds of playback cost a 4K clip far
/// more bytes than a 1080p clip, and a fast connection with a small clip must not queue useless work.
@Suite struct VideoReadAheadWindowTests {
    private let blockBytes = 4 * 1024 * 1024

    private func blocks(mbitPerSecond: Double, seconds: Double, minimum: Int = 8, maximum: Int = 48) -> Int? {
        let totalSize = Int(mbitPerSecond * 1_000_000 / 8 * seconds)
        let blockCount = max(1, Int((Double(totalSize) / Double(blockBytes)).rounded(.up)))
        return VideoReadAheadWindow.blockCount(
            totalSize: totalSize,
            durationSeconds: seconds,
            blockCount: blockCount,
            minimumBlocks: minimum,
            maximumBlocks: maximum
        )
    }

    @Test func aFourKClipGetsAWiderWindowThanNineteenTwenty() throws {
        // iPhone 4K at about 50 Mbit/s against 1080p at about 8 Mbit/s, both two minutes long.
        let fourK = try #require(blocks(mbitPerSecond: 50, seconds: 120))
        let fullHD = try #require(blocks(mbitPerSecond: 8, seconds: 120))
        #expect(fourK > fullHD, "the higher bitrate needs more bytes for the same seconds")
        // 25 seconds at about 6.25 MB/s is roughly 156 MB, which is about 38 blocks of 4 MB.
        #expect((34...42).contains(fourK))
        #expect(fullHD == 8, "8 Mbit/s fits the target window inside the hot window already")
    }

    @Test func aSmallClipNeverQueuesMoreBlocksThanItHas() throws {
        // A five-second 4K clip has about 31 MB: the window must not ask for 38 blocks it cannot have.
        let window = try #require(blocks(mbitPerSecond: 50, seconds: 5))
        #expect(window <= 8 + 1)
        #expect(window >= 8, "the hot window stays the floor")
    }

    @Test func anExtremeBitrateStaysBounded() throws {
        let window = try #require(blocks(mbitPerSecond: 400, seconds: 600))
        #expect(window == 48)
    }

    @Test func unusableInputsKeepTheDefaultWindow() {
        #expect(
            VideoReadAheadWindow.blockCount(
                totalSize: 0, durationSeconds: 60, blockCount: 4, minimumBlocks: 8, maximumBlocks: 48) == nil)
        #expect(
            VideoReadAheadWindow.blockCount(
                totalSize: 1_000, durationSeconds: 0, blockCount: 4, minimumBlocks: 8, maximumBlocks: 48) == nil)
        #expect(
            VideoReadAheadWindow.blockCount(
                totalSize: 1_000, durationSeconds: .infinity, blockCount: 4, minimumBlocks: 8, maximumBlocks: 48)
                == nil)
    }
}
