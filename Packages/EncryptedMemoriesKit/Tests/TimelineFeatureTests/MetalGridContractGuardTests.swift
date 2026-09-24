import CoreGraphics
import Foundation
import GridCore
import Testing
import TimelineCore

@testable import TimelineFeature

/// Behavior tests for the Metal grid engine contract: square slots, fixed columns, and content fitting.
@Suite struct MetalGridContractGuardTests {
    private let eps: CGFloat = 0.5
    private func engine(_ count: Int = 6000) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }

    @Test func engineOwnsSlotGeometryGuard() {
        let e = engine()
        for level in 0..<e.levelCount {
            let plan = e.framePlan(
                level: level, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 2000),
                overscan: 0)
            for s in plan.visibleSlots {
                #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps, "slot not square at L\(level)")
            }
        }
    }

    /// The fitter only changes the content rect / UV inside a slot; it can never change the (square) slot.
    @Test func tileContentFitterIsContentOnly() {
        let slot = CGRect(x: 100, y: 200, width: 140, height: 140)
        for aspect in [0.25, 0.5, 1.0, 1.78, 4.0] as [CGFloat] {
            let fill = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFill)
            #expect(fill.contentRect == slot, "aspectFill fills the square slot exactly; aspect lives only in UV")
            let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFit)
            #expect(slot.contains(fit.contentRect) || fit.contentRect == slot, "aspectFit stays inside the slot")
            // The fitter changes content geometry, not the slot geometry.
            #expect(fill.contentRect.width <= slot.width + 0.01 && fill.contentRect.height <= slot.height + 0.01)
        }
    }

    @Test func tileContentFitterDoesNotAffectSlotGeometryGuard() {
        let e = engine()
        let before = e.framePlan(
            level: 1, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        let after = e.framePlan(
            level: 1, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        #expect(
            before.visibleSlots == after.visibleSlots && before.contentSize == after.contentSize
                && before.columns == after.columns)
        let slot = before.visibleSlots.first!.viewportRect
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 1.7, displayMode: .aspectFitInsideSquare)
        let fill = TileContentFitter.fit(slotRect: slot, mediaAspect: 1.7, displayMode: .squareFillCrop)
        #expect(fit.contentRect != fill.contentRect, "the two modes must fit content differently")
        for r in [fit.contentRect, fill.contentRect] {
            #expect(
                r.minX >= slot.minX - eps && r.maxX <= slot.maxX + eps && r.minY >= slot.minY - eps
                    && r.maxY <= slot.maxY + eps,
                "content must stay inside the (unchanged) slot")
        }
    }

    // A level fills the width across widths without a trailing gutter; the
    // column count is constant (held at nominalColumns) and the tile scales with width (resize = scale, never
    // reflow). The reference width reproduces the level's nominalColumns.
    @Test func fillWidthFixedColumnsGuard() {
        let e = engine()
        for level in 0..<e.levelCount {
            let nominal = e.metrics(level: level).nominalColumns
            var sides: [CGFloat] = []
            for w in [CGFloat(800), 1400, 2400] {
                let m = e.resolvedMetrics(level: level, width: w)
                #expect(m.columns == nominal, "L\(level) fixed-columns: count holds at \(nominal)")
                sides.append(m.slotSide)
                #expect(abs((CGFloat(m.columns) * m.pitch - m.gap) - w) < 2.0, "L\(level) must fill width \(w)")
            }
            #expect(sides.first! < sides.last!, "L\(level) tile must SCALE with width (fixed-columns, no reflow)")
            #expect(
                e.resolvedMetrics(level: level, width: GridSizePolicy.referenceWidth).columns
                    == e.metrics(level: level).nominalColumns,
                "L\(level) must reproduce nominalColumns at the reference width")
        }
    }

    @Test func noAspectOuterLayoutGuard() {
        // The engine slot geometry has no media-aspect input: same square slot regardless of any content aspect.
        let e = engine()
        let s = e.slotRect(flatIndex: 137, level: 2, width: 1000)!
        #expect(abs(s.width - s.height) < eps, "engine slot is square (independent of media aspect)")
        #expect(
            e.slotRect(flatIndex: 137, level: 2, width: 1000) == s, "engine slotRect is deterministic / aspect-free")
    }

    @Test func sixLevelSpecGuard() {
        #expect(SquareTileGridEngine.appleLevelSpecs.count == 6)
        #expect(SquareTileGridEngine.testRegularLevels.count == 6)
        #expect(engine().levelCount == 6)
        #expect(
            SquareTileGridEngine.appleLevelSpecs.map(\.nominalColumns) == [3, 5, 7, 9, 20, 30],
            "configured six-level nominal columns")
    }
}
