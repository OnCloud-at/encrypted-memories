import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// Ensures that the production timeline uses square slots from the Metal grid geometry engine.
/// Source scans cover forbidden layout paths; pure checks cover the engine and renderer contract.
@Suite struct GridCanonicalGuardTests {
    private let eps: CGFloat = 0.01

    // .../Packages/EncryptedMemoriesKit/Tests/TimelineFeatureTests/<this>.swift to up 3 to EncryptedMemoriesKit
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // TimelineFeatureTests
        url.deleteLastPathComponent()  // Tests
        url.deleteLastPathComponent()  // EncryptedMemoriesKit
        return url
    }
    private func source(_ name: String) -> String {
        for target in ["TimelineFeature", "GridCore"] {
            let url = packageRoot.appendingPathComponent("Sources/\(target)/\(name)")
            if let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        return ""
    }

    private func engine(_ count: Int = 1500) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }
    private let viewport = CGSize(width: 1400, height: 900)

    // The production timeline instantiates the Metal grid and never the NSCollectionView grid.
    @Test func noProductionNSCollectionViewFallback() {
        let tv = source("TimelineView.swift")
        #expect(tv.contains("MetalProductionGridView("), "production timeline must use the Metal grid")
        #expect(!tv.contains("PhotoGridView("), "production timeline must NOT fall back to the NSCollectionView grid")
    }

    // Production layout does not use media aspect ratios. The engine is square-only.
    @Test func noProductionJustifiedAspectLayout() {
        let tv = source("TimelineView.swift")
        #expect(!tv.contains("sectionAspects(for:"), "production timeline must not feed aspect ratios into layout")
        // Every engine slot is square at every level - the engine cannot produce a justified (aspect) cell.
        let e = engine()
        for level in 0..<e.levelCount {
            let plan = e.framePlan(
                level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000), overscan: 0)
            for s in plan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < eps) }
        }
    }

    // The geometry engine does not depend on edge-fill or replacement-surface machinery.
    @Test func noEdgeFillHackInEngine() {
        let engineSrc = source("SquareTileGridEngine.swift")
        let banned = [
            "exposedLeft", "exposedRight", "shrunkenSource", "sourcePlate", "targetWall",
            "targetBackdrop", "replacementPlan", "PinchOutEdgeFill", "edgeFill",
        ]
        for term in banned {
            #expect(!engineSrc.contains(term), "the canonical engine must not depend on '\(term)'")
        }
    }

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

    // Live pinch uses the engine-owned `GridZoomTransaction` rather than a stateless re-resolve.
    @Test func productionLiveZoomUsesEngineTransaction() {
        let coord = source("MetalGridCoordinator.swift")
        #expect(coord.contains("zoomTransaction"), "live zoom must be the engine-owned GridZoomTransaction")
        #expect(coord.contains("beginLiveZoom"), "the coordinator must drive the live-zoom transaction")
        // The coordinator must not reference removed detent or justified-layout types.
        for banned in ["GridDetentLayout", "GridZoomDetentModel", "detentModel", "MetalGridLayout", "usesDetentZoom"] {
            #expect(!coord.contains(banned), "the coordinator must not reference removed '\(banned)'")
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
