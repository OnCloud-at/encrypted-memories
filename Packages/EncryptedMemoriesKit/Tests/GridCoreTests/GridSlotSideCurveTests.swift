import CoreGraphics
import Testing

@testable import GridCore

/// `slotSide` eases between levels with the shared `gridSmoothstep` curve and keeps the values of the
/// smoothstep formula it spelled inline before, up to the rounding of the last bit: the ladder tails clamp to
/// their level sides, and every interior position matches, including the seam between two levels with the same
/// column count.
@Suite struct GridSlotSideCurveTests {
    private static let levels: [GridLevelMetrics] = [
        GridLevelMetrics(levelID: 0, nominalColumns: 8, gap: 4, monthLabels: false),
        GridLevelMetrics(levelID: 1, nominalColumns: 6, gap: 5, monthLabels: false),
        GridLevelMetrics(levelID: 2, nominalColumns: 6, gap: 6, monthLabels: true),
        GridLevelMetrics(levelID: 3, nominalColumns: 3, gap: 8, monthLabels: true, transitionKindToNext: nil),
    ]
    private static let width: CGFloat = 390

    private static func side(_ index: Int) -> CGFloat {
        GridColumnGeometry(columns: levels[index].nominalColumns, gap: levels[index].gap, width: width).side
    }

    @Test func theInteriorKeepsTheInlineSmoothstepValues() {
        let last = Self.levels.count - 1
        var x: CGFloat = 0
        while x < CGFloat(last) {
            let lo = Int(x)
            // The formula that `slotSide` spelled inline before it called `gridSmoothstep`. It multiplied the
            // side difference by each factor in turn, so its rounding can differ in the last bit.
            let t = x - CGFloat(lo)
            let inline = Self.side(lo) + (Self.side(lo + 1) - Self.side(lo)) * t * t * (3 - 2 * t)
            let side = GridApparentMetrics.slotSide(at: x, width: Self.width, levels: Self.levels)
            #expect(abs(side - inline) <= 2 * inline.ulp, "x \(x): \(side) against \(inline)")
            #expect(side == Self.side(lo) + (Self.side(lo + 1) - Self.side(lo)) * gridSmoothstep(t))
            x += 0.05
        }
    }

    @Test func theTailsClampToTheirLevelSides() {
        let last = Self.levels.count - 1
        for x in [CGFloat(-0.4), 0, CGFloat(last), CGFloat(last) + 0.5] {
            let expected = x <= 0 ? Self.side(0) * (1 - x * 0.6) : Self.side(last)
            #expect(GridApparentMetrics.slotSide(at: x, width: Self.width, levels: Self.levels) == expected)
        }
    }
}
