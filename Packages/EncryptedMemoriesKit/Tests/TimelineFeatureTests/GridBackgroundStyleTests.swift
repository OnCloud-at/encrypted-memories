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
    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }
    private func src(_ name: String) -> String {
        for target in ["TimelineFeature", "MetalRenderingCore"] {
            let rel = "Packages/EncryptedMemoriesKit/Sources/\(target)/\(name)"
            if let source = try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8) {
                return source
            }
        }
        return ""
    }

    // The named background color is the clear-color source.
    @Test func productionGridUsesSingleBackgroundColor() {
        let c = MetalGridPalette.backgroundRGBA
        #expect(abs(c.r - c.g) < 0.01 && abs(c.g - c.b) < 0.01, "background must be a NEUTRAL gray")
        #expect(c.r > 0.07 && c.r < 0.20, "background must be a dark gray ~#1f1f1f, not black/light: \(c.r)")
        #expect(c.a == 1.0, "opaque surface")
        #expect(MetalGridRenderPalette.backgroundRGBA == MetalGridPalette.backgroundRGBA)
        // Production injects the palette into the shared renderer; the renderer itself clears with that value.
        #expect(
            src("MetalGridCoordinator.swift").contains(
                "MetalGridRenderer(device: device, clearColor: MetalGridPalette.clearColor)"))
        let renderer = src("MetalGridRenderer.swift")
        #expect(renderer.contains("private let clearColor"))
        #expect(renderer.contains("pass.colorAttachments[0].clearColor = clearColor"))
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("MetalGridPalette.clearColor") && host.contains("MetalGridPalette.background"))
        #expect(!host.contains("red: 0.043"), "no leftover hardcoded warm-brown clear color")
    }

    // Production grid rendering does not draw per-cell cards.
    @Test func rendererDoesNotDrawGridCellBackgroundsInProduction() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "private func buildRealGroups") else {
            Issue.record("buildRealGroups missing")
            return
        }
        let body = String(
            coord[
                range
                    .lowerBound..<(coord.index(range.lowerBound, offsetBy: 2800, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(!body.contains("backgrounds.append"), "missing thumbnails must not draw placeholder background cards")
        #expect(
            !body.contains("quads: backgrounds"), "production must not submit a placeholder-background render group")
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

    // The production path must not draw synthetic solid-colored tiles.
    @Test func productionDoesNotUseSyntheticDebugColors() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(!coord.contains("SquareGridDebugMode"), "the synthetic debug palette must stay removed")
        // Resident tiles draw image quads rather than solid-colored cards.
        guard let range = coord.range(of: "private func buildRealGroups") else {
            Issue.record("buildRealGroups missing")
            return
        }
        let body = String(
            coord[
                range
                    .lowerBound..<(coord.index(range.lowerBound, offsetBy: 2800, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(!body.contains("mode: .solid"), "production must not draw synthetic solid-colored tiles")
    }
}
