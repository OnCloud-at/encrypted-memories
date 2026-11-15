import Testing

@testable import PhotosCore

@Suite struct ExportByteProgressTests {
    @Test func aLargeOriginalMovesTheProgressFurtherThanASmallOne() {
        let progress = ExportByteProgress(itemCount: 2)
        progress.record(size: 100, at: 0)
        progress.record(size: 900, at: 1)
        #expect(progress.fraction(completedItems: 0, currentItemProgress: 1) == 0.085)
        #expect(progress.fraction(completedItems: 1, currentItemProgress: 0) == 0.1)
        #expect(abs(progress.fraction(completedItems: 1, currentItemProgress: 0.5) - 0.4825) < 1e-12)
        #expect(progress.fraction(completedItems: 2, currentItemProgress: 0) == 1)
    }

    @Test func anUnknownSizeCountsAsTheMeanOfTheKnownSizes() {
        let progress = ExportByteProgress(itemCount: 3)
        progress.record(size: 100, at: 0)
        progress.record(size: nil, at: 1)
        progress.record(size: 300, at: 2)
        #expect(abs(progress.fraction(completedItems: 2, currentItemProgress: 0) - 0.5) < 1e-12)
    }

    @Test func withoutAnyKnownSizeEveryOriginalCountsTheSame() {
        let progress = ExportByteProgress(itemCount: 4)
        progress.record(size: 0, at: 0)
        #expect(progress.fraction(completedItems: 1, currentItemProgress: 0) == 0.25)
    }

    /// A download progress that is not a number, or lies outside 0...1, can never fill the progress.
    @Test func anInvalidDownloadProgressNeverFillsTheProgress() {
        let progress = ExportByteProgress(itemCount: 2)
        progress.record(size: 100, at: 0)
        progress.record(size: 100, at: 1)
        #expect(progress.fraction(completedItems: 0, currentItemProgress: .nan) == 0)
        #expect(progress.fraction(completedItems: 0, currentItemProgress: -1) == 0)
        #expect(progress.fraction(completedItems: 0, currentItemProgress: .infinity) == 0)
        #expect(progress.fraction(completedItems: 0, currentItemProgress: 2) == 0.425)
    }

    /// The largest file sizes add up without an overflow.
    @Test func theLargestFileSizesAddUpWithoutAnOverflow() {
        let progress = ExportByteProgress(itemCount: 3)
        progress.record(size: Int.max, at: 0)
        progress.record(size: Int.max, at: 1)
        #expect(abs(progress.fraction(completedItems: 1, currentItemProgress: 0) - 1.0 / 3) < 1e-12)
    }

    @Test func theProgressNeverGoesBackWhenALaterSizeChangesTheEstimate() {
        let progress = ExportByteProgress(itemCount: 2)
        progress.record(size: 100, at: 0)
        #expect(progress.fraction(completedItems: 1, currentItemProgress: 0) == 0.5)
        progress.record(size: 900, at: 1)
        #expect(progress.fraction(completedItems: 1, currentItemProgress: 0) == 0.5)
        #expect(abs(progress.fraction(completedItems: 1, currentItemProgress: 0.5) - 0.5) < 1e-12)
        #expect(abs(progress.fraction(completedItems: 1, currentItemProgress: 1) - 0.865) < 1e-12)
    }
}
