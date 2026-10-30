import CoreGraphics
import MediaByteCache
import MediaCache
import PhotosCore
import SwiftUI
import Testing

@testable import TimelineCore
@testable import TimelineFeature

/// Retry is shown only when the recorded failure is retryable and the device is online.
/// The iOS error screen honors the same flag and offline exception.
/// Every failure reaches the view through a production route: a throwing repository drives `load()`
/// for the retryable case, and the non-retryable case is replayed through the first-load reducer
/// seam that production uses for the same mirroring.
/// The direction of the comparison matters: the render with `retryable: true` must carry the
/// Retry button's layout weight, moving the error text's ink centroid measurably upward, and the
/// render with `retryable: false` must not. An inverted switch swaps those roles and fails these
/// checks.
@MainActor
@Suite struct TimelineViewRetryVisibilityTests {
    @Test func onlineRetryButtonFollowsTheFailureFlagByDirection() async throws {
        // The real first-load failure route: the repository throws and `load()` mirrors the failure.
        let shownFeed = makeFeed()
        let shownModel = TimelineViewModel(repository: FailingStartupRepository(), feed: shownFeed.feedCore)
        await shownModel.load()
        guard case .failed(let message, let retryable) = shownModel.state else {
            Issue.record("A thrown first load must surface the failure state")
            return
        }
        #expect(retryable, "The production route must record a thrown first read as retryable")
        let shown = try renderedPixels(of: shownModel, feed: shownFeed)
        let shownRepeated = try renderedPixels(of: shownModel, feed: shownFeed)
        #expect(
            Self.differingPixels(shown, shownRepeated) == 0,
            "Renders of the same failure state must be identical")

        // Only the Retry affordance may shift the layout. The glass button draws no offscreen ink,
        // so the directional signal is the centroid of that ink: adding the actions row to the
        // centered stack moves it measurably upward (measured shift: 12 rows; message-length noise
        // stays under 2 rows, so 6 is a wide margin both ways). An inverted switch puts the button
        // in the bare render instead, flipping both comparisons and failing these checks.
        let bare = try renderReplayedFailure(message: message, retryable: false)
        let withButton = try renderReplayedFailure(message: message, retryable: true)
        #expect(
            Self.centroidRow(withButton) + 6 < Self.centroidRow(bare),
            "The retryable flag must add the Retry button's layout weight (centroids: \(Self.centroidRow(withButton)) vs \(Self.centroidRow(bare)))"
        )
        #expect(
            Self.centroidRow(shown) + 6 < Self.centroidRow(bare),
            "The real failure route must draw the Retry button (centroids: \(Self.centroidRow(shown)) vs \(Self.centroidRow(bare)))"
        )
    }

    @Test func theErrorMessageDrawsOnTheErrorScreen() throws {
        // A different description text must change the drawn pixels; this proves the failure text
        // renders on macOS and the screen is not just the static background.
        let first = try renderReplayedFailure(message: "First fixture failure", retryable: true)
        let second = try renderReplayedFailure(message: "Second fixture failure", retryable: true)
        #expect(
            Self.differingPixels(first, second) > 300,
            "The failure message must draw ink")
    }

    @Test func provisionalEmptyGridPreservesFailureRetryability() {
        for retryable in [false, true] {
            let feed = makeFeed()
            let model = TimelineViewModel(repository: NoopRepository(), feed: feed.feedCore)
            model.applyIsolatedInitialLoadEventsForTesting([.failed(message: "Failure", retryable: retryable)])
            model.state = .empty
            guard case .failed(let message, let actualRetryable) = model.gridState else {
                Issue.record("A provisional empty grid must surface the first-load failure")
                continue
            }
            #expect(message == "Failure")
            #expect(actualRetryable == retryable)
        }
    }

    // MARK: - Helpers

    private func makeFeed() -> ThumbnailFeed {
        ThumbnailFeed(
            cache: ThumbnailCache(
                namespace: "tests-retry-visibility-\(UUID().uuidString)",
                rootDirectory: timelineFeatureTestCacheRoot("retry-visibility")),
            loader: NoopThumbnailLoader())
    }

    /// `ImageRenderer` takes one snapshot and runs no view lifecycle, so the error screen renders
    /// from the model's recorded failure state alone.
    private func renderedPixels(of model: TimelineViewModel, feed: ThumbnailFeed) throws -> [UInt8] {
        let view = TimelineView(model: model, feed: feed)
        return try RenderedInk.rawPixels(view, width: 480, height: 360)
    }

    /// Replays a first-load failure through the production reducer seam and renders its error screen.
    private func renderReplayedFailure(message: String, retryable: Bool) throws -> [UInt8] {
        let feed = makeFeed()
        let model = TimelineViewModel(repository: NoopRepository(), feed: feed.feedCore)
        model.applyIsolatedInitialLoadEventsForTesting([.failed(message: message, retryable: retryable)])
        return try renderedPixels(of: model, feed: feed)
    }

    /// Offsets of pixels whose color differs between two same-sized RGBA renders.
    private static func differingPixelOffsets(_ lhs: [UInt8], _ rhs: [UInt8]) -> [Int] {
        precondition(lhs.count == rhs.count)
        var offsets: [Int] = []
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            if lhs[offset] != rhs[offset]
                || lhs[offset + 1] != rhs[offset + 1]
                || lhs[offset + 2] != rhs[offset + 2]
            {
                offsets.append(offset)
            }
        }
        return offsets
    }

    private static func differingPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        differingPixelOffsets(lhs, rhs).count
    }

    /// Row of the vertical centroid of the render's ink (pixels departing from the corner surface
    /// background). The glass Retry button itself draws no offscreen ink, but its presence in the
    /// actions row moves the centered stack, so the centroid is the directional signal.
    private static func centroidRow(_ pixels: [UInt8]) -> Double {
        let background = (pixels[0], pixels[1], pixels[2])
        var weighted = 0.0
        var count = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let departs =
                abs(Int(pixels[offset]) - Int(background.0)) > 8
                || abs(Int(pixels[offset + 1]) - Int(background.1)) > 8
                || abs(Int(pixels[offset + 2]) - Int(background.2)) > 8
            guard departs else { continue }
            weighted += Double(offset / 4 / 480)
            count += 1
        }
        return count > 0 ? weighted / count : -1
    }

    private struct FailingStartupRepository: PhotosRepository {
        enum Failure: Error { case firstRead }
        func cachedTimeline() async -> [TimelineSection]? { nil }
        func loadTimeline() async throws -> [TimelineSection] { throw Failure.firstRead }
    }

    private struct NoopRepository: PhotosRepository {
        func cachedTimeline() async -> [TimelineSection]? { nil }
        func loadTimeline() async throws -> [TimelineSection] { [] }
    }

    private struct NoopThumbnailLoader: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult { .delivered }
    }
}
