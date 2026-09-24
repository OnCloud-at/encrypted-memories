import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// Ensures that the production timeline uses square slots from the Metal grid geometry engine.
/// Source scans cover forbidden layout paths; pure checks cover the engine and renderer contract.
@Suite struct GridCanonicalGuardTests {
    private let eps: CGFloat = 0.01

    private func engine(_ count: Int = 1500) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }
    private let viewport = CGSize(width: 1400, height: 900)

    // Renderer quads use the square viewport rectangles from the engine.
    @Test func rendererReceivesSquareSlotQuads() {
        let e = engine()
        let plan = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 1500), overscan: 200)
        #expect(!plan.visibleSlots.isEmpty)
        for s in plan.visibleSlots {
            #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps)  // the outer quad is square
            #expect(abs(s.viewportRect.width - plan.slotSide) < eps)
        }
    }

    // The engine assigns the same square slot to photos and videos. The fitter handles the media aspect.
    @Test func videoUsesSquareSlot() {
        let e = engine()
        let plan = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 1500), overscan: 0)
        let sides = Set(plan.visibleSlots.map { Int(($0.slotRect.width * 100).rounded()) })
        #expect(sides.count == 1, "every slot is the identical square regardless of payload (photo or video)")
        // A wide-video frame still fits inside the square slot via the fitter (contained, slot unchanged).
        let slot = plan.visibleSlots[0].slotRect
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 16.0 / 9.0, mode: .aspectFill)
        #expect(fit.contentRect == slot)  // fills the square; the crop is in UV, the slot is unchanged
    }
}
