import CoreGraphics
import Foundation
import GridCore
import MetalRenderingCore
import Testing

@testable import TimelineFeature

// The production grid uses one dark-gray surface for gaps, aspect-fit letterboxing, and the clear color.
// Production rendering has no per-cell cards, grid lines, or synthetic tile colors.
@Suite struct GridBackgroundStyleTests {
    private let eps: CGFloat = 0.5

    // The named background color is the clear-color source.
    @Test func productionGridUsesSingleBackgroundColor() {
        let c = MetalGridPalette.backgroundRGBA
        #expect(abs(c.r - c.g) < 0.01 && abs(c.g - c.b) < 0.01, "background must be a NEUTRAL gray")
        #expect(c.r > 0.07 && c.r < 0.20, "background must be a dark gray ~#1f1f1f, not black/light: \(c.r)")
        #expect(c.a == 1.0, "opaque surface")
        #expect(MetalGridRenderPalette.backgroundRGBA == MetalGridPalette.backgroundRGBA)
    }

    // Aspect-fit letterboxing remains inside the square slot and reveals the grid background.
    @Test func aspectFitLetterboxUsesGridBackground() {
        let slot = CGRect(x: 0, y: 0, width: 180, height: 180)
        // A wide photo leaves letterbox bands inside the square.
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 16.0 / 9.0, displayMode: .aspectFitInsideSquare)
        #expect(fit.contentRect.height < slot.height - eps, "letterbox bands must exist for a wide photo")
        #expect(
            fit.contentRect.minX >= slot.minX - eps && fit.contentRect.maxX <= slot.maxX + eps, "content stays in slot")
        // Letterbox bands reveal the cleared surface because no card is drawn behind the image.
        #expect(MetalGridPalette.backgroundVector.w == 1)
    }
}
