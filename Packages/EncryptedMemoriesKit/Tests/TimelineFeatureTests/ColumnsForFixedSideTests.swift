import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// Pins the column count that the live over-zoom path derives from a slot side.
@Suite struct ColumnsForFixedSideTests {
    private let levels = SquareTileGridEngine.testRegularLevels

    /// The exact-fill slot side of a level at the reference width, minus half a point so that the rounding of
    /// the column count stays away from a tie.
    private func sampleSide(_ m: GridLevelMetrics) -> CGFloat {
        max(1, (SquareTileGridEngine.testReferenceWidth + m.gap) / CGFloat(m.nominalColumns) - m.gap - 0.5)
    }

    // At the reference width the sample side yields exactly the nominal column count of every level.
    @Test func sampleSideRoundTripsAtTheReferenceWidth() {
        for m in levels {
            let cols = SquareTileGridEngine.columnsForFixedSide(
                side: sampleSide(m), gap: m.gap, width: SquareTileGridEngine.testReferenceWidth)
            #expect(cols == m.nominalColumns, "level \(m.levelID): \(cols) ≠ nominalColumns \(m.nominalColumns)")
        }
    }

    // At a constant side, the column count is non-decreasing in width and strictly grows on a wide enough
    // viewport: more photos when wider, never a rescale.
    @Test func columnsGrowWithWidthAtConstantSize() {
        for m in levels {
            let side = sampleSide(m)
            let narrow = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: 800)
            let wide = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: 2560)
            #expect(wide > narrow, "level \(m.levelID): columns did not grow with width (\(narrow) → \(wide))")
            var last = 0
            for w in stride(from: CGFloat(400), through: 3200, by: 25) {
                let c = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: w)
                #expect(c >= last, "columns decreased as width grew (level \(m.levelID), w=\(w): \(c) < \(last))")
                #expect(c >= 1, "always at least one column")
                last = c
            }
        }
    }
}
