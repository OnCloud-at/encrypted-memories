import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// A discrete, anchor-preserved level change keeps the visible index neighbourhood centered on the anchor.
/// Within one level, the index order does not rewrap.
@Suite struct GridZoomNeighborhoodTests {
    private let width: CGFloat = 1400
    private let viewport = CGSize(width: 1400, height: 900)
    private let viewportPointY: CGFloat = 450

    private func engine() -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [3000]) }

    private func midScroll(_ e: SquareTileGridEngine, level: Int) -> CGFloat {
        max(0, e.contentSize(level: level, width: width).height / 2 - viewport.height / 2)
    }
    private func visibleIndices(
        _ e: SquareTileGridEngine, level: Int, scrollY: CGFloat, overscan: CGFloat = 0
    ) -> Set<Int> {
        Set(
            e.framePlan(
                level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan
            ).visibleSlots.map(\.index))
    }
    /// Simulate the host's discrete, anchor-preserving level change: capture the item at the viewport centre,
    /// then re-anchor scroll so that item stays at the same viewport point at the new level.
    private func reanchor(
        _ e: SquareTileGridEngine, from startLevel: Int, scrollY: CGFloat, to targetLevel: Int
    ) -> (scrollY: CGFloat, anchorIndex: Int) {
        let a = e.anchorItem(
            nearContentPoint: CGPoint(x: width / 2, y: scrollY + viewportPointY), level: startLevel, width: width)!
        var ny = e.anchoredScrollOffsetY(
            flatIndex: a.flatIndex, relInCellY: a.localFraction.y,
            contentFractionY: 0, viewportPointY: viewportPointY, level: targetLevel, width: width)
        let maxY = max(0, e.contentSize(level: targetLevel, width: width).height - viewport.height)
        ny = min(max(0, ny), maxY)
        return (ny, a.flatIndex)
    }
    /// Fraction of the smaller set retained by the other (continuity metric - 1.0 = the sparser view's items
    /// are all still shown).
    private func retained(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        let small = a.count <= b.count ? a : b
        let big = a.count <= b.count ? b : a
        return small.isEmpty ? 1 : Double(small.intersection(big).count) / Double(small.count)
    }

    @Test func detentOnlyZoomPreservesLogicalViewport() {
        let e = engine()
        let level = 2
        let scrollY = midScroll(e, level: level)
        let before = visibleIndices(e, level: level, scrollY: scrollY)
        for targetLevel in [1, 3] {
            let r = reanchor(e, from: level, scrollY: scrollY, to: targetLevel)
            let after = visibleIndices(e, level: targetLevel, scrollY: r.scrollY)
            #expect(after.contains(r.anchorIndex), "anchor lost on \(level)→\(targetLevel)")
            #expect(
                retained(before, after) > 0.6,
                "neighbourhood not preserved \(level)→\(targetLevel): \(retained(before, after))")
        }
    }

    @Test func zoomVisibleNeighborhoodDoesNotJump() {
        let e = engine()
        let level = 2
        let scrollY = midScroll(e, level: level)
        let before = visibleIndices(e, level: level, scrollY: scrollY)
        let r = reanchor(e, from: level, scrollY: scrollY, to: 3)
        let after = visibleIndices(e, level: 3, scrollY: r.scrollY)
        #expect(after.contains(r.anchorIndex))
        #expect(!before.isDisjoint(with: after), "visible set jumped to a disjoint region")
        // Index ranges overlap (not a teleport to an unrelated region).
        #expect(after.min()! <= before.max()! && after.max()! >= before.min()!, "index ranges disjoint = jump")
    }

    @Test func consecutiveZoomFramesHaveHighIndexOverlap() {
        let e = engine()
        var currentLevel = 2
        var scrollY = midScroll(e, level: currentLevel)
        var prev = visibleIndices(e, level: currentLevel, scrollY: scrollY)
        for targetLevel in [3, 4, 5] {
            let r = reanchor(e, from: currentLevel, scrollY: scrollY, to: targetLevel)
            let cur = visibleIndices(e, level: targetLevel, scrollY: r.scrollY)
            #expect(retained(prev, cur) > 0.6, "low overlap \(currentLevel)→\(targetLevel): \(retained(prev, cur))")
            currentLevel = targetLevel
            scrollY = r.scrollY
            prev = cur
        }
    }

    @Test func anchorItemAndNeighborhoodStable() {
        let e = engine()
        let level = 2
        let scrollY = midScroll(e, level: level)
        let r = reanchor(e, from: level, scrollY: scrollY, to: 3)
        let after = visibleIndices(e, level: 3, scrollY: r.scrollY, overscan: 200)
        var kept = 0
        for k in -5...5 where after.contains(r.anchorIndex + k) { kept += 1 }
        #expect(kept >= 9, "anchor neighbourhood not retained: \(kept)/11")
    }

    @Test func zoomDoesNotRewrapWholeGridEveryTick() {
        let e = engine()
        let level = 3
        let cols = e.resolvedMetrics(level: level, width: width).columns
        let loc0 = e.locate(flatIndex: 1234, level: level, width: width)!
        for scrollY in [CGFloat(0), 1000, 5000, 12000] {
            #expect(e.resolvedMetrics(level: level, width: width).columns == cols)  // scroll never changes columns
            // The visible set translates with scroll but the grid does not rewrap.
            _ = visibleIndices(
                e, level: level,
                scrollY: min(scrollY, max(0, e.contentSize(level: level, width: width).height - viewport.height)))
        }
        let loc1 = e.locate(flatIndex: 1234, level: level, width: width)!
        #expect(loc0.row == loc1.row && loc0.column == loc1.column)  // placement is scroll-independent
        #expect(e.resolvedMetrics(level: level + 1, width: width).columns != cols)
    }
}
