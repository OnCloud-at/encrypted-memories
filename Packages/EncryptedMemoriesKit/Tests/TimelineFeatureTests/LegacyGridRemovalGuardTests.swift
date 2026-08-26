import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

/// Ensures that the timeline uses the Metal grid and that unsupported grid paths stay absent.
/// The source scan covers the production tree.
@Suite struct LegacyGridRemovalGuardTests {
    // .../Packages/EncryptedMemoriesKit/Tests/TimelineFeatureTests/<this>.swift to up 3 to EncryptedMemoriesKit.
    private var packageDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // TimelineFeatureTests
        url.deleteLastPathComponent()  // Tests
        url.deleteLastPathComponent()  // EncryptedMemoriesKit
        return url
    }
    private var sourcesDir: URL { packageDir.appendingPathComponent("Sources/TimelineFeature") }

    /// Every production `.swift` under Sources/TimelineFeature (recursive), as (filename, contents).
    private func productionSources() -> [(name: String, text: String)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.lastPathComponent, text))
            }
        }
        return out
    }

    /// No production source may reference a removed grid symbol. The scan includes comments.
    @Test func noProductionReferenceToRemovedLegacySymbols() {
        let banned = [
            // NSCollectionView grid.
            "PhotoGridView", "PhotoGridItem", "RoundedCellView", "DateHeaderView", "MagnifyingCollectionView",
            // Justified and aspect layouts.
            "JustifiedCollectionLayout", "MetalGridLayout",
            // Detent zoom machinery.
            "GridDetentLayout", "GridZoomDetentModel", "GridZoomTransition", "MetalGridDetentZoomFlag",
            "GridZoomDebug", "GridLayoutFamily", "GridDetentCell", "detentModel", "usesDetentZoom",
            // Removed zoom math and sprite-transition overlay.
            "GridZoomMath", "GridSpriteTransitionView", "GridSpriteRenderer", "GridResizeStabilizer",
            "ContinuousGridLayoutEngine", "GridThumbnailFallback",
            // Removed edge-fill transition vocabulary.
            "sourcePlate", "targetBackdrop", "targetWall", "exposedLeftRect", "replacementPlan",
            // Removed NSCollectionView switch.
            "MetalGridFeatureFlag",
        ]
        let sources = productionSources()
        #expect(!sources.isEmpty, "could not read production sources")
        for (name, text) in sources {
            for term in banned {
                #expect(
                    !text.contains(term), "production source \(name) still references removed legacy symbol '\(term)'")
            }
        }
    }

    /// Removed grid files must stay absent from the production source tree.
    @Test func removedLegacyFilesDoNotExist() {
        let fm = FileManager.default
        let removed = [
            "PhotoGridView.swift", "PhotoGridItem.swift", "JustifiedCollectionLayout.swift",
            "MetalGridLayout.swift", "GridSpriteTransitionView.swift", "GridZoomMath.swift",
            "GridResizeStabilizer.swift", "ContinuousGridLayoutEngine.swift", "ThumbnailFallback.swift",
            "DurationLookupGate.swift", "MetalGridFeatureFlag.swift",
            "GridZoom/GridDetentLayout.swift", "GridZoom/GridZoomDetentModel.swift",
            "GridZoom/GridZoomTransition.swift", "GridZoom/MetalGridDetentZoomFlag.swift",
        ]
        for rel in removed {
            #expect(
                !fm.fileExists(atPath: sourcesDir.appendingPathComponent(rel).path),
                "legacy file \(rel) must be deleted, not present")
        }
    }

    /// No production source may expose a switch back to an NSCollectionView grid.
    @Test func noNSCollectionViewFallbackFlag() {
        for (name, text) in productionSources() {
            #expect(
                !text.contains("MetalGrid.enabled"),
                "production source \(name) must not gate the grid on a MetalGrid.enabled flag")
            #expect(
                !text.lowercased().contains("nscollectionview"),
                "production source \(name) must not mention an NSCollectionView grid path")
        }
    }

    /// `TimelineView` constructs the Metal grid. The frame check also exercises the square geometry path.
    @Test func productionTimelineUsesMetalGridOnly() {
        let tv =
            (try? String(contentsOf: sourcesDir.appendingPathComponent("TimelineView.swift"), encoding: .utf8)) ?? ""
        #expect(tv.contains("MetalProductionGridView("), "timeline must build the Metal grid")
        #expect(!tv.contains("PhotoGridView("), "timeline must not build the NSCollectionView grid")

        let e = SquareTileGridEngine.testRegular(sectionCounts: [5_000])
        let plan = e.framePlan(
            level: 3, viewportSize: CGSize(width: 1280, height: 800),
            scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        #expect(!plan.visibleSlots.isEmpty)
        for s in plan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < 0.01) }  // square only
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
}
