import AppKit
import CoreGraphics
import Foundation
import GridCore
import MetalKit
import PhotosCore
import Testing
import TimelineCore

@testable import TimelineFeature

@MainActor
private final class PresentationTestDataSource: MetalGridDataSource {
    let label = "presentation-test"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?

    init(count: Int) {
        self.sectionCounts = [count]
        self.flatUIDs = (0..<count).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }
    }

    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
    func hasImage(for uid: PhotoUID) -> Bool { false }
}

// Live window-resize presentation layer. During a live window edge drag the grid keeps stable geometry: the
// captured items keep their rows and columns. Width changes use canonical fixed gaps and the bounded release
// camera before mouse-up. Thumbnail streaming stays live. Height-only dragging retains its counter-scroll.
@Suite struct GridResizePresentationTests {
    private let eps: CGFloat = 0.001
    @MainActor
    private func makeCoordinator(
        width: CGFloat = 1200, height: CGFloat = 800, level: Int = 3,
        scrollY: CGFloat = 1800, count: Int = 2000
    ) -> (MetalGridCoordinator, MetalGridView, NSClipView)? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let coordinator = MetalGridCoordinator(
                device: device,
                dataSource: PresentationTestDataSource(count: count),
                gridProfile: TimelineGridProfileConfiguration.production.defaultProfile
            )
        else { return nil }
        let view = MetalGridView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        clip.bounds = CGRect(x: 0, y: scrollY, width: width, height: height)
        coordinator.metalView = view
        coordinator.clipView = clip
        coordinator.level = level
        return (coordinator, view, clip)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func executableWindowResizePresentationMatchesCanonicalLayoutAndSettlesCleanly() throws {
        let (coordinator, view, clip) = try #require(makeCoordinator())
        _ = clip  // coordinator holds clipView weakly; keep the test clip alive for the lifecycle.
        coordinator.beginPresentationResize()
        #expect(coordinator.presentationResizeActive)

        let startSlots = coordinator.resizePresentationSlots(viewportSize: view.bounds.size)
        #expect(!startSlots.isEmpty)
        let startByIndex = Dictionary(uniqueKeysWithValues: startSlots.map { ($0.index, $0.rect) })

        view.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        let narrowedSlots = coordinator.resizePresentationSlots(viewportSize: view.bounds.size)
        let narrowedByIndex = Dictionary(uniqueKeysWithValues: narrowedSlots.map { ($0.index, $0.rect) })
        guard let sampleIndex = startSlots.dropFirst(startSlots.count / 2).first?.index,
            let source = startByIndex[sampleIndex],
            let narrowed = narrowedByIndex[sampleIndex]
        else {
            Issue.record("no common presentation slot")
            return
        }
        #expect(narrowed.width < source.width)
        let content = try #require(coordinator.cellContentRect(forFlatIndex: sampleIndex))
        let expected = content.offsetBy(
            dx: coordinator.leadingObstructionInset, dy: -coordinator.windowResizeReleaseScrollY())
        #expect(abs(narrowed.minX - expected.minX) < 0.001)
        #expect(abs(narrowed.minY - expected.minY) < 0.001)
        #expect(abs(narrowed.width - expected.width) < 0.001)
        #expect(abs(narrowed.width - narrowed.height) < 0.001)

        #expect(
            !coordinator.beginResizeSettle(targetScrollY: coordinator.centerAnchoredScroll()),
            "fixed-column resize should not arm a release reflow morph")
        coordinator.endPresentationResize()
        #expect(!coordinator.presentationResizeActive)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func horizontalResizeMatchesSettledGeometryBeforeMouseUp() throws {
        for count in [8, 2000, 50000] {
            for scrollFraction: CGFloat in [0, 0.5, 1] {
                let (coordinator, view, clip) = try #require(makeCoordinator(scrollY: 0, count: count))
                defer { withExtendedLifetime(clip) {} }
                coordinator.topBarInset = 52
                clip.bounds.origin.y = max(0, coordinator.contentSize().height - view.bounds.height) * scrollFraction
                coordinator.beginPresentationResize()
                for width: CGFloat in [900, 1500] {
                    view.frame.size.width = width
                    let liveSlots = coordinator.resizePresentationSlots(viewportSize: view.bounds.size)
                    #expect(!liveSlots.isEmpty)
                    let releaseY = coordinator.windowResizeReleaseScrollY()
                    for slot in liveSlots where slot.rect.maxY >= 0 && slot.rect.minY <= view.bounds.height {
                        let contentRect = try #require(coordinator.cellContentRect(forFlatIndex: slot.index))
                        let settled = contentRect.offsetBy(dx: coordinator.leadingObstructionInset, dy: -releaseY)
                        #expect(abs(slot.rect.minX - settled.minX) < 0.01)
                        #expect(
                            abs(slot.rect.minY - settled.minY) < 0.01,
                            "Live resize must use the same bounded camera as release, without a temporary empty band")
                        #expect(abs(slot.rect.width - settled.width) < 0.01)
                    }
                }
                coordinator.endPresentationResize()
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func extremeWidthShrinkCoversEveryNewlyVisibleRow() throws {
        for order: GridFillOrder in [.newestBottomTrailing, .topLeading] {
            for fraction: CGFloat in [0, 0.5, 1] {
                let (coordinator, view, clip) = try #require(makeCoordinator(width: 2400, scrollY: 0, count: 50000))
                defer { withExtendedLifetime(clip) {} }
                coordinator.setFillOrder(order)
                coordinator.topBarInset = 52
                coordinator.sidebarObstructionInset = 280
                clip.bounds.origin.y = max(0, coordinator.contentSize().height - view.bounds.height) * fraction
                coordinator.beginPresentationResize()
                let original = coordinator.resizePresentationSlots(viewportSize: view.bounds.size)
                let originalByIndex = Dictionary(uniqueKeysWithValues: original.map { ($0.index, $0) })
                for size in [
                    CGSize(width: 720, height: 800), CGSize(width: 960, height: 1000),
                    CGSize(width: 2400, height: 800),
                ] {
                    view.frame.size = size
                    let slots = coordinator.resizePresentationSlots(viewportSize: size)
                    let presented = Set(slots.map(\.index))
                    // Returning to the original width uses the host's height-only release branch.
                    let releaseY =
                        size.width == 2400
                        ? coordinator.presentationStartScrollY : coordinator.windowResizeReleaseScrollY()
                    clip.bounds.origin.y = releaseY
                    let visible = coordinator.visibleCells()
                    #expect(!visible.isEmpty)
                    #expect(
                        visible.allSatisfy { presented.contains($0.flatIndex) },
                        "Extreme shrink and corner drags must cover every newly visible row")
                    #expect(slots.count < 2000, "Resize work must remain bounded by the viewport, not library size")
                    for slot in slots {
                        if let start = originalByIndex[slot.index] {
                            #expect(
                                slot.row == start.row && slot.column == start.column,
                                "Resizing must preserve each photo's row and column")
                        }
                        let content = try #require(coordinator.cellContentRect(forFlatIndex: slot.index))
                        let settled = content.offsetBy(dx: coordinator.leadingObstructionInset, dy: -releaseY)
                        #expect(abs(slot.rect.minY - settled.minY) < 0.01)
                        #expect(abs(slot.rect.minX - settled.minX) < 0.01)
                        #expect(abs(slot.rect.width - settled.width) < 0.01)
                    }
                }
                coordinator.endPresentationResize()
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func executableSidebarPresentationReachesCanonicalTargetAndCommitsEventInset() throws {
        let (coordinator, view, clip) = try #require(makeCoordinator())
        _ = clip  // coordinator holds clipView weakly; keep the test clip alive for the lifecycle.
        coordinator.normalLevelLeadingGap = 16
        #expect(coordinator.beginSidebarResize(fromInset: 0, toInset: 280))
        #expect(coordinator.isSidebarResizing)

        let startSlots = coordinator.sidebarPresentationSlots(viewportSize: view.bounds.size, progress: 0)
        let endSlots = coordinator.sidebarPresentationSlots(viewportSize: view.bounds.size, progress: 1)
        let startByIndex = Dictionary(uniqueKeysWithValues: startSlots.map { ($0.index, $0.rect) })
        let endByIndex = Dictionary(uniqueKeysWithValues: endSlots.map { ($0.index, $0.rect) })
        guard let sampleIndex = startSlots.dropFirst(startSlots.count / 2).first?.index,
            let source = startByIndex[sampleIndex],
            let end = endByIndex[sampleIndex]
        else {
            Issue.record("no common sidebar slot")
            return
        }
        #expect(end.minX > source.minX, "opening the sidebar moves the grid's leading edge out of the obstruction")
        #expect(abs(end.width - end.height) < 0.001)

        let target = coordinator.presentationSidebarTargetSlots
        let endIndices = Set(endSlots.map(\.index))
        #expect(!target.isEmpty)
        #expect(
            target.allSatisfy { endIndices.contains($0.index) },
            "the final presentation must include every destination slot")
        #expect(
            MetalGridCoordinator.maxIndexedRectDelta(source: endSlots, target: target) < 0.001,
            "the final presentation frame must exactly match the canonical settled layout")

        let result = coordinator.endSidebarResize()
        #expect(result.scroll >= 0)
        #expect(!result.animating, "fixed-column sidebar width changes must not arm a release morph")
        #expect(!coordinator.isSidebarResizing)
        #expect(coordinator.sidebarObstructionInset == 280)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func sidebarCloseAtNewestEndHasNoFinalGeometrySnap() throws {
        let (coordinator, view, clip) = try #require(makeCoordinator())
        coordinator.normalLevelLeadingGap = 16
        coordinator.sidebarObstructionInset = 280
        let maxScroll = max(0, coordinator.contentSize().height - view.bounds.height)
        clip.bounds.origin.y = maxScroll

        #expect(coordinator.beginSidebarResize(fromInset: 280, toInset: 0))
        let finalPresented = coordinator.sidebarPresentationSlots(viewportSize: view.bounds.size, progress: 1)
        let target = coordinator.presentationSidebarTargetSlots
        let presentedIndices = Set(finalPresented.map(\.index))
        #expect(
            target.allSatisfy { presentedIndices.contains($0.index) },
            "the bottom-pinned destination must already be covered by the captured overscan")
        #expect(
            MetalGridCoordinator.maxIndexedRectDelta(source: finalPresented, target: target) < 0.001,
            "closing the sidebar at startup/newest must end on the settled target without a second set")

        let result = coordinator.endSidebarResize()
        #expect(!result.animating)
        #expect(coordinator.sidebarObstructionInset == 0)
    }

    // A square tile stays square at any scale and its size follows the width ratio (× k).
    @Test func scalePreservesSquareTilesAtWidthRatio() {
        for k in [CGFloat(0.4), 0.75, 1.0, 1.6] {
            let out = MetalGridCoordinator.presentationScaledRect(
                CGRect(x: 137, y: 421, width: 200, height: 200), scale: k, insetX: 0, anchorY: 400)
            #expect(abs(out.width - out.height) < eps, "tile must stay square at scale \(k)")
            #expect(abs(out.width - 200 * k) < eps, "tile size must scale by the width ratio")
        }
    }

    // k = 1 is the identity, so the gesture-start frame equals the settled grid.
    @Test func unitScaleIsIdentity() {
        let r = CGRect(x: 312, y: 47, width: 180, height: 180)
        let out = MetalGridCoordinator.presentationScaledRect(r, scale: 1, insetX: 24, anchorY: 450)
        #expect(
            abs(out.minX - r.minX) < eps && abs(out.minY - r.minY) < eps && abs(out.width - r.width) < eps
                && abs(out.height - r.height) < eps)
    }

    // The content left edge stays at the inset anchor.
    @Test func leftEdgeHeldAtInset() {
        let inset: CGFloat = 50
        let out = MetalGridCoordinator.presentationScaledRect(
            CGRect(x: inset, y: 400, width: 200, height: 200), scale: 0.6, insetX: inset, anchorY: 400)
        #expect(abs(out.minX - inset) < eps, "the content origin edge must stay pinned at the inset")
    }

    // Center-anchored scaling keeps the focused row fixed while surrounding rows scale symmetrically.
    @Test func centreAnchoredHoldsCentreRow() {
        let viewportHeight: CGFloat = 800
        // A cell centered on the viewport remains centered at every scale.
        let centreCell = CGRect(x: 0, y: viewportHeight / 2 - 50, width: 100, height: 100)
        for k in [CGFloat(0.5), 1.0, 1.6] {
            let out = MetalGridCoordinator.presentationScaledRect(
                centreCell, scale: k, insetX: 0, anchorY: viewportHeight / 2)
            #expect(
                abs(out.midY - viewportHeight / 2) < eps,
                "the centre row must stay at the viewport centre at scale \(k)")
        }
        // A row above the centre moves further up on a scale-up and toward the centre on a scale-down (symmetric).
        let above = CGRect(x: 0, y: 100, width: 100, height: 100)
        let up = MetalGridCoordinator.presentationScaledRect(
            above, scale: 1.5, insetX: 0, anchorY: viewportHeight / 2)
        let down = MetalGridCoordinator.presentationScaledRect(
            above, scale: 0.5, insetX: 0, anchorY: viewportHeight / 2)
        #expect(up.minY < above.minY, "a scale-up pushes an above-centre row further up")
        #expect(down.minY > above.minY, "a scale-down pulls an above-centre row toward the centre")
    }

    // Scaled content fills the current content width: a cell at the start content-right
    // maps to the current content-right (the inset-anchored scale by the width ratio gives no gutter / no overflow).
    @Test func scaledContentFillsCurrentWidth() {
        // start layout width 1280 (no inset); narrow to 960, so k = 0.75. A cell at the right edge (maxX = 1280).
        let k: CGFloat = 960.0 / 1280.0
        let rightCell = MetalGridCoordinator.presentationScaledRect(
            CGRect(x: 1080, y: 0, width: 200, height: 200), scale: k, insetX: 0, anchorY: 400)
        #expect(
            abs(rightCell.maxX - 960) < eps,
            "the content right edge must map to the new content width (fills, no gutter)")
    }

    // Bottom-pin detection: a resize that began near the newest end is
    // bottom-pinned; one scrolled up into the middle is not. Bottom-pinned holds the last row at the viewport bottom
    // (no empty band below); centre-pinned holds the centre. Pure + boundary.
    @Test func resizeBottomPinDetection() {
        // scrolled to the very bottom (scrollY == maxScroll = content − viewport), so pinned.
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 4100, contentHeight: 5000, viewportHeight: 900))
        // within the 2pt tolerance of the bottom, so still pinned.
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 4099, contentHeight: 5000, viewportHeight: 900))
        // scrolled up into the middle, so not pinned (hold the centre).
        #expect(!MetalGridCoordinator.resizeIsBottomPinned(scrollY: 2000, contentHeight: 5000, viewportHeight: 900))
        // content shorter than the viewport (maxScroll = 0, scrollY 0), so pinned (degenerate bottom).
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 0, contentHeight: 400, viewportHeight: 900))
    }

    // maxIndexedRectDelta is zero for identical layouts and large when the same indexed items move. Fixed-column
    // resize normally never arms this path; it remains useful for any future responsive policy that changes columns.
    @Test func indexedRectDeltaDetectsReflow() {
        let a = [
            GridRenderSlot(index: 0, column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            GridRenderSlot(index: 1, column: 1, row: 0, rect: CGRect(x: 100, y: 0, width: 100, height: 100)),
        ]
        #expect(MetalGridCoordinator.maxIndexedRectDelta(source: a, target: a) == 0, "identical layouts ⇒ no settle")
        let b = [
            GridRenderSlot(index: 0, column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 80, height: 80)),
            GridRenderSlot(index: 1, column: 0, row: 1, rect: CGRect(x: 0, y: 80, width: 80, height: 80)),
        ]
        #expect(
            MetalGridCoordinator.maxIndexedRectDelta(source: a, target: b) > 20, "a column reflow ⇒ a measurable delta")
    }

    // easeOutCubic is a clamped 0 to 1 fast-start, gentle-landing curve.
    @Test func easeOutCubicShape() {
        #expect(
            abs(MetalGridCoordinator.easeOutCubic(0) - 0) < eps && abs(MetalGridCoordinator.easeOutCubic(1) - 1) < eps)
        #expect(MetalGridCoordinator.easeOutCubic(0.5) > 0.5, "easeOut leads linear at the midpoint")
    }

    // The vertical counter-scroll shares the height loss: the dragging edge clips most of it, while the opposite
    // edge gives up fraction f. A shrink slides the grid UP (negative); growing flips it; f interpolates pure
    // edge-anchor (0) and opposite-anchor (1).
    @Test func verticalCounterScrollSharesTheLoss() {
        let f: CGFloat = 1.0 / 3.0
        #expect(
            abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: f) - (-30)) < eps,
            "bottom-edge shrink slides up by f·dH")
        #expect(
            abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: true, fraction: f) - (-60)) < eps,
            "top-edge shrink slides up by (1−f)·dH")
        #expect(
            MetalGridCoordinator.verticalCounterScrollShift(dH: -90, topEdgeDrag: false, fraction: f) > 0,
            "growing flips the slide")
        #expect(
            MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: 0) == 0,
            "f=0 ⇒ top fixed (pure edge-anchor)")
        #expect(
            abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: 1) - (-90)) < eps,
            "f=1 ⇒ bottom-anchored")
    }

    // Right-anchored scale holds the content's right edge fixed and maps the left edge to the new inset
    // (sidebar open = a left-edge resize of the grid: the grid slides in from the right and scales).
    @Test func rightAnchoredScaleHoldsRightEdge() {
        let rightEdgeX: CGFloat = 1000
        let k: CGFloat = 0.75
        let right = MetalGridCoordinator.presentationScaledRectRightAnchored(
            CGRect(x: rightEdgeX - 100, y: 0, width: 100, height: 100), scale: k, rightX: rightEdgeX,
            anchorY: 800)
        #expect(abs(right.maxX - rightEdgeX) < eps, "the content right edge stays fixed")
        let left = MetalGridCoordinator.presentationScaledRectRightAnchored(
            CGRect(x: 0, y: 0, width: 100, height: 100), scale: k, rightX: rightEdgeX, anchorY: 800)
        #expect(abs(left.minX - 250) < eps, "the left edge maps to the new inset")
        #expect(
            abs(left.width - 100 * k) < eps && abs(left.width - left.height) < eps, "tiles stay square, scaled by k")
    }
}
