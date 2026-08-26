import CoreGraphics
import Foundation
import GridCore
import Testing
import TimelineCore

@testable import TimelineFeature

/// Rubber-band over-zoom at the largest grid level (level 0): pinching further in produces a bounded elastic
/// visual over-zoom (negative live level) anchored under the cursor, while the committed level stays clamped.
@Suite struct GridLiveZoomBoundsTests {
    private func transaction(anchorIndex: Int = 500, cursor: CGPoint = CGPoint(x: 700, y: 450)) -> GridZoomTransaction {
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        return GridZoomTransaction(
            totalItems: 4000, anchorGlobalIndex: anchorIndex, anchorViewportPoint: cursor,
            anchorLocalFraction: CGPoint(x: 0.5, y: 0.5), levels: engine.levels, sourceLevel: 0)
    }

    // A negative live level produces a tile larger than level 0.
    @Test func overZoomGrowsTileBeyondLevel0() {
        let tx = transaction()
        let width: CGFloat = 1400
        let side0 = tx.apparentSlotSide(at: 0, width: width)
        let sideOver = tx.apparentSlotSide(at: -0.2, width: width)
        #expect(sideOver > side0)
        #expect(tx.apparentSlotSide(at: -0.3, width: width) > sideOver)  // more over-zoom, so larger
    }

    // Over-zoom scales the level-0 grid geometrically with fixed columns and larger cells and pitch.
    @Test func overZoomScalesLevel0GridWithoutReflow() {
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let tx = transaction()
        let viewport = CGSize(width: 1400, height: 900)
        let f0 = tx.frame(continuousLevel: 0, viewportSize: viewport, overscan: 0)
        let fOver = tx.frame(continuousLevel: -0.25, viewportSize: viewport, overscan: 0)
        #expect(fOver.columns == f0.columns)  // fixed columns - scales, doesn't reflow
        #expect(fOver.columns == engine.levels[0].nominalColumns)
        #expect(fOver.slotSide > f0.slotSide)  // cells geometrically larger
        #expect(fOver.pitch > f0.pitch)  // whole grid (cell+gap) scales uniformly
    }

    // Scaling the width-filled level-0 surface around a point inside a source column must keep the source
    // column identity. Re-deriving the column from the already-enlarged pitch can turn compact L0's right
    // column into column zero and translate the whole grid right by one tile, exposing a black leading strip.
    @Test func overZoomKeepsSourceColumnAndCoversViewport() throws {
        let profile = try #require(TimelineGridProfileConfiguration.production.profile(id: "touchCompactTimeline"))
        let engine = SquareTileGridEngine(sectionCounts: [4000], profile: profile)
        let viewport = CGSize(width: 440, height: 900)
        let metrics = engine.resolvedMetrics(level: 0, width: viewport.width)
        #expect(metrics.columns == 2)

        for sourceColumn in 0..<metrics.columns {
            for localX in [CGFloat(0.1), 0.5, 0.9] {
                let cursorX = CGFloat(sourceColumn) * metrics.pitch + localX * metrics.slotSide
                let tx = GridZoomTransaction(
                    totalItems: 4000,
                    anchorGlobalIndex: 500,
                    anchorViewportPoint: CGPoint(x: cursorX, y: 450),
                    anchorLocalFraction: CGPoint(x: localX, y: 0.5),
                    levels: engine.levels,
                    sourceLevel: 0
                )
                let settled = tx.frame(continuousLevel: 0, viewportSize: viewport, overscan: 0)
                let overZoom = tx.frame(continuousLevel: -0.25, viewportSize: viewport, overscan: 0)
                let focusRow = overZoom.visibleSlots.filter { $0.row == 0 }.sorted { $0.column < $1.column }

                #expect(settled.anchorColumn == sourceColumn)
                #expect(overZoom.anchorColumn == sourceColumn)
                #expect(focusRow.count == metrics.columns)
                #expect(focusRow.first!.rect.minX <= 0)
                #expect(focusRow.last!.rect.maxX >= viewport.width)
            }
        }
    }

    // The live-zoom mapping keeps a bounded negative visual level within the cap.
    @Test func visualLevelKeepsBoundedNegativeOverZoom() {
        let lc = 6
        let cap = GridLiveZoomBounds.maxOverZoom
        let oneLevel = GridLiveZoomBounds.visualLevel(rawLevel: -0.42, levelCount: lc)
        #expect(oneLevel < 0)  // not clamped to 0 - the rubber-band shows
        #expect(oneLevel >= -cap)  // …but bounded by the cap
        // Aggressive pinch is capped (cannot produce absurd tile sizes).
        let aggressive = GridLiveZoomBounds.visualLevel(rawLevel: -1000, levelCount: lc)
        #expect(aggressive >= -cap)
        #expect(aggressive < 0)
        // Monotonic: more pinch-in, so more (more negative) overshoot.
        #expect(
            GridLiveZoomBounds.visualLevel(rawLevel: -1, levelCount: lc)
                < GridLiveZoomBounds.visualLevel(rawLevel: -0.2, levelCount: lc))
    }

    // Releasing a negative live level commits to level 0.
    @Test func releaseFromOverZoomCommitsToLevel0() {
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let deepest = GridLiveZoomBounds.visualLevel(rawLevel: -1000, levelCount: engine.levelCount)
        #expect(Int(deepest.rounded()) == 0)  // the host's rounded commit target is 0
        #expect(engine.clampLevel(Int(deepest.rounded())) == 0)
        #expect(engine.clampLevel(-1) == 0)  // backstop: a negative level clamps to 0
        // clampVisual keeps the live value in range too.
        #expect(GridLiveZoomBounds.clampVisual(-5, levelCount: engine.levelCount) == -GridLiveZoomBounds.maxOverZoom)
    }

    // The anchor item stays under the cursor during over-zoom.
    @Test func anchorStaysUnderCursorDuringOverZoom() {
        let cursor = CGPoint(x: 700, y: 450)
        let tx = transaction(anchorIndex: 500, cursor: cursor)
        let viewport = CGSize(width: 1400, height: 900)
        func anchorCentre(at x: CGFloat) -> CGPoint? {
            let f = tx.frame(continuousLevel: x, viewportSize: viewport, overscan: 0)
            guard let slot = f.visibleSlots.first(where: { $0.index == 500 }) else { return nil }
            return CGPoint(x: slot.rect.midX, y: slot.rect.midY)
        }
        let atZero = anchorCentre(at: 0)
        let atOver = anchorCentre(at: -0.2)
        #expect(atZero != nil)
        #expect(atOver != nil)
        if let z = atZero {
            #expect(abs(z.x - cursor.x) < 1e-6)
            #expect(abs(z.y - cursor.y) < 1e-6)
        }
        if let o = atOver {
            #expect(abs(o.x - cursor.x) < 1e-6)
            #expect(abs(o.y - cursor.y) < 1e-6)
        }
    }

    // Positive in-band levels pass through unchanged, except at the densest end.
    @Test func inBandLevelsPassThroughUnchanged() {
        let lc = 6
        #expect(GridLiveZoomBounds.visualLevel(rawLevel: 0, levelCount: lc) == 0)
        #expect(GridLiveZoomBounds.visualLevel(rawLevel: 1.5, levelCount: lc) == 1.5)
        #expect(GridLiveZoomBounds.visualLevel(rawLevel: 5, levelCount: lc) == 5)
        #expect(GridLiveZoomBounds.visualLevel(rawLevel: 9, levelCount: lc) == 5)  // clamp to densest (lc-1)
    }
}
