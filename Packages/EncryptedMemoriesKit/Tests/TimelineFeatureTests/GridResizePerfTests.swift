import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

// Resize/render contract: resize is redraw-only (no texture reload / sync decode),
// the visible query is bounded to the viewport+overscan, the pipeline is built once, diagnostics are throttled,
// and pure-height resize doesn't recompute width-derived metrics/contentSize.
@Suite struct GridResizePerfTests {
    private func engine(_ count: Int = 20000) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }

    // Pure-height resize leaves width-derived metrics and contentSize unchanged.
    @Test func pureHeightResizeDoesNotRecomputeWidthMetrics() {
        let e = engine()
        let before = e.resolvedMetrics(level: 2, width: 1000)
        let r = e.rebasedScrollOffsetForViewportChange(
            GridViewportResizeInput(
                oldViewportFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                newViewportFrame: CGRect(x: 0, y: 200, width: 1000, height: 800),
                oldScrollY: 6000, level: 2, committedPhase: nil, itemCount: 20000,
                wasBottomPinned: false, anchorFractionY: 0.5))
        let after = e.resolvedMetrics(level: 2, width: 1000)
        #expect(before == after, "width-derived metrics must be identical on a pure-height resize")
        #expect(
            r.newContentSize.height == e.contentSize(level: 2, width: 1000).height,
            "contentSize unchanged when width unchanged")
    }

    // The visible-slot query is bounded to viewport plus overscan, not the whole library.
    @Test func visibleSlotQueryBoundedToViewportOverscan() {
        let e = engine(20000)
        let plan = e.framePlan(
            level: 2, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 50000),
            overscan: 200, columnPhase: nil)
        #expect(plan.visibleSlots.count < 600, "visible query must be bounded, got \(plan.visibleSlots.count) of 20000")
        #expect(!plan.visibleSlots.isEmpty)
    }

    @Test func hundredThousandAssetProjectionRemainsViewportBounded() {
        let e = engine(100_000)
        let viewport = CGSize(width: 1_024, height: 1_366)
        let offsets = stride(from: CGFloat(0), through: CGFloat(1_200_000), by: 5_000)
        var maximumVisible = 0
        var projectionCount = 0
        let started = ContinuousClock.now

        for offset in offsets {
            let plan = e.framePlan(
                level: 2,
                viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: offset),
                overscan: 320,
                columnPhase: nil
            )
            maximumVisible = max(maximumVisible, plan.visibleSlots.count)
            projectionCount += 1
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        print("[Grid100kProjection] projections=\(projectionCount) maxVisible=\(maximumVisible) elapsed=\(elapsed)")
        #expect(maximumVisible > 0)
        #expect(maximumVisible < 600, "100k projection must remain bounded to viewport and overscan")
    }
}
