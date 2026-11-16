import CoreGraphics
import GridCore
import Testing

@testable import TimelineFeature

/// The geometry of the settled grid and of the live over-zoom plan, recorded before the grid builder was split
/// into a fixed-column and a side-driven entry. The digest changes with any bit of any value. A mismatch on
/// another CPU (fused multiply-add can change the last bit) needs a dump of the single values first, to see which
/// value moved, before the constants are touched.
@Suite struct SettledGridGeometryTests {
    private static func fold(_ values: [CGFloat], into hash: inout UInt64) {
        for value in values {
            hash = (hash ^ UInt64(Double(value).bitPattern)) &* 0x0000_0100_0000_01b3
        }
    }

    private static func digest(profile: GridLevelProfile, sectionCounts: [Int]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let engine = SquareTileGridEngine(sectionCounts: sectionCounts, profile: profile)
        for level in 0..<engine.levelCount {
            for width: CGFloat in [120, 400, 700, 1000, SquareTileGridEngine.testReferenceWidth, 1600, 2560, 3840] {
                let m = engine.resolvedMetrics(level: level, width: width)
                fold([CGFloat(m.columns), m.slotSide, m.gap, m.pitch], into: &hash)
                for phase in [nil, 2] as [Int?] {
                    let size = engine.contentSize(level: level, width: width, columnPhase: phase)
                    let plan = engine.framePlan(
                        level: level, viewportSize: CGSize(width: width, height: 800),
                        scrollOffset: CGPoint(x: 0, y: 300), overscan: 100, columnPhase: phase)
                    let counts = [CGFloat(plan.columns), CGFloat(plan.visibleSlots.count)]
                    fold([size.width, size.height] + counts, into: &hash)
                    if let first = plan.visibleSlots.first {
                        fold([first.slotRect.minX, first.slotRect.minY, first.slotRect.width], into: &hash)
                    }
                }
            }
        }
        let anchor = GridZoomAnchor(
            flatIndex: 100, viewportPoint: CGPoint(x: 160, y: 300),
            contentFractionY: 0.5, relInCell: CGPoint(x: 0.5, y: 0.5))
        // A narrow phone, the usual laptop window and a wide display.
        for viewport in [
            CGSize(width: 390, height: 844), CGSize(width: 1400, height: 900), CGSize(width: 2560, height: 1440),
        ] {
            for x in stride(from: -0.5, through: Double(engine.levelCount) + 0.5, by: 0.125) {
                let plan = engine.zoomFramePlan(
                    continuousLevel: CGFloat(x), viewportSize: viewport, anchor: anchor, overscan: 0)
                let counts = [CGFloat(plan.columns), CGFloat(plan.visibleSlots.count)]
                fold(counts + [plan.slotSide, plan.pitch], into: &hash)
            }
        }
        return hash
    }

    @Test func theSettledAndLiveGridGeometryKeepsItsValues() {
        let regular = GridLevelProfile.testRegularTimeline
        #expect(Self.digest(profile: regular, sectionCounts: [500]) == 0x08cd_0acb_ccc1_8bbc)
        #expect(Self.digest(profile: regular, sectionCounts: [200, 300]) == 0x3af4_8348_eceb_ed5d)
        #expect(Self.digest(profile: .testCompactTimeline, sectionCounts: [500]) == 0x9e8a_5890_6257_47bc)
    }
}
