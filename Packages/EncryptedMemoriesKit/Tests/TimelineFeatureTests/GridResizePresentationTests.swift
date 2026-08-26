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
// settled slots are snapshotted once on begin, then each frame is uniformly scaled to the new width (square tiles
// preserved) about the stationary left edge + viewport centre. It must not per-tick engine-resolve the lattice
// because that reflows tiles, but it must still stream current thumbnails through the normal visible-first path
// so placeholders can fill while the mouse is still down. The clip is frozen and re-centred once on release.
@Suite struct GridResizePresentationTests {
    private let eps: CGFloat = 0.001
    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }
    private func src(_ name: String) -> String {
        (try? String(
            contentsOf: repoRoot().appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }
    /// Extract a full function body by brace-matching from its signature, so a substring guard checks the
    /// whole function (robust to the function growing) rather than a brittle fixed byte window that silently
    /// drops the guard the moment the function gets longer. Returns "" if the signature isn't found.
    private func funcBody(_ source: String, _ signature: String) -> String {
        guard let sig = source.range(of: signature),
            let brace = source.range(of: "{", range: sig.upperBound..<source.endIndex)
        else { return "" }
        var depth = 0
        var i = brace.lowerBound
        while i < source.endIndex {
            switch source[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[brace.lowerBound...i]) }
            default: break
            }
            i = source.index(after: i)
        }
        return String(source[brace.lowerBound...])
    }
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
    func executableWindowResizePresentationScalesSnapshotAndSettlesCleanly() throws {
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
        let k: CGFloat = (900 - 24) / (1200 - 24)  // standard 12pt left + right margin at normal levels
        let expected = MetalGridCoordinator.presentationScaledRect(source, scale: k, insetX: 12, anchorY: 400)
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

    // The presentation scales the gesture-start snapshot each tick; it does not re-resolve the engine per frame
    // (that would reflow). drawPresentationResize maps the snapshot slots through presentationScaledRect, then
    // streams/renders those slots through the shared visible-first path - never `engine.framePlan` for the render.
    @Test func presentationScalesSnapshotNotPerFrameResolve() {
        let coord = src("MetalGridCoordinator.swift")
        let drawBody = funcBody(coord, "func drawPresentationResize")
        let slotBody = funcBody(coord, "func resizePresentationSlots")
        guard !drawBody.isEmpty else {
            Issue.record("drawPresentationResize missing")
            return
        }
        guard !slotBody.isEmpty else {
            Issue.record("resizePresentationSlots missing")
            return
        }
        #expect(drawBody.contains("resizePresentationSlots(viewportSize: viewportSize)"))
        #expect(
            drawBody.contains("streamTextures("),
            "live resize must keep the normal visible-first thumbnail stream alive")
        #expect(
            drawBody.contains("renderRealSlots("),
            "live resize must render from the current texture cache, not a stale offscreen canvas")
        #expect(
            !coord.contains("rasterizeResizeSnapshot") && !coord.contains("drawResizeCanvasQuad"),
            "live resize must not use a frozen offscreen snapshot canvas")
        #expect(
            slotBody.contains("presentationSnapshotSlots") && slotBody.contains("presentationScaledRect"),
            "the render must SCALE the captured snapshot geometry, not re-resolve per tick")
        #expect(
            !drawBody.contains("engine.framePlan") && !slotBody.contains("engine.framePlan"),
            "drawPresentationResize must NOT re-resolve the layout per tick (that reflows)")
        #expect(coord.contains("if presentationResizeActive {") && coord.contains("drawPresentationResize(in: view"))
    }

    // Shared snapshot capture builds settled slots once with generous overscan above (so a scale-out
    // reveals real rows) + records the start box; begin captures the centre anchor + uses it; never in a zoom.
    @Test func beginSnapshotsWithOverscanAndCenterAnchor() {
        let coord = src("MetalGridCoordinator.swift")
        guard let cap = coord.range(of: "func captureSnapshot()") else {
            Issue.record("captureSnapshot missing")
            return
        }
        let capBody = String(
            coord[
                cap
                    .lowerBound..<(coord.index(cap.lowerBound, offsetBy: 1600, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(
            capBody.contains("max(budget.overscanFraction, 1.5)"),
            "the snapshot must carry generous overscan rows above")
        #expect(
            capBody.contains("engine.framePlan") && capBody.contains("presentationSnapshotSlots ="),
            "captureSnapshot builds the slots once")
        #expect(
            capBody.contains("presentationStartLayoutWidth"),
            "captureSnapshot records the start layout width (the scale denominator)")
        let centerAnchorBody = funcBody(coord, "func captureCenterAnchor()")
        #expect(
            centerAnchorBody.containsCodeFragmentIgnoringWhitespace("anchorItem(nearContentPoint:"),
            "the centre anchor is captured at the viewport centre")
        guard let range = coord.range(of: "func beginPresentationResize()") else {
            Issue.record("beginPresentationResize missing")
            return
        }
        let body = String(
            coord[
                range
                    .lowerBound..<(coord.index(range.lowerBound, offsetBy: 1500, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(
            body.contains("captureCenterAnchor()") && body.contains("captureSnapshot()"),
            "begin captures the centre anchor + the snapshot")
        #expect(
            coord.contains("var canPresentResize") && coord.contains("zoomTransaction == nil")
                && coord.contains("!gridTransition.isActive"))
    }

    // layout() presents synchronously per tick through draw(), not async needsDisplay, because the live-resize run loop
    // coalesces) and early-returns before the normal per-tick reflow path.
    @Test func layoutPresentsSynchronouslyAndBypassesReflow() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("metalView.draw()"), "must draw synchronously per tick")
        guard let branch = host.range(of: "if inLiveResize, coordinator.presentationResizeActive"),
            let ret = host.range(of: "return", range: branch.upperBound..<host.endIndex),
            let rebase = host.range(of: "rebaseForResize(oldFrame: old")
        else {
            Issue.record("layout wiring missing")
            return
        }
        #expect(
            branch.lowerBound < ret.lowerBound && ret.lowerBound < rebase.lowerBound,
            "the presentation branch must early-return BEFORE the normal per-tick rebaseForResize")
    }

    // Release settle does not reflow or snap: a width change settles to the resize anchor at release
    // width (so the settled grid lands where the live frame left it) and it does not call rebaseForResize.
    @Test func settleSyncsClipWithoutReflowSnap() {
        let host = src("MetalGridScrollHost.swift")
        guard let dr = host.range(of: "func windowDidEndLiveResize()") else {
            Issue.record("windowDidEndLiveResize missing")
            return
        }
        let db = String(
            host[dr.lowerBound..<(host.index(dr.lowerBound, offsetBy: 2000, limitedBy: host.endIndex) ?? host.endIndex)]
        )
        #expect(db.contains("coordinator.endPresentationResize()"))
        #expect(
            db.contains("coordinator.windowResizeReleaseScrollY()"),
            "the width settle must use the resize anchor (bottom-pinned ⇒ last row, else centre)")
        #expect(!db.contains("rebaseForResize("), "settle must NOT reflow/re-anchor (that was the snap)")
        #expect(
            host.contains("NSWindow.didEndLiveResizeNotification") && host.contains("selector(windowDidEndLiveResize)"))
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

    // Presentation and settle pick the anchor from the bottom-pin flag: `drawPresentationResize` scales about
    // H (last row) when pinned else H/2 (centre); the settle scroll routes through `windowResizeReleaseScrollY`
    // (bottom-anchored vs centre-anchored). Begin captures both anchors + the flag.
    @Test func resizeAnchorIsAdaptiveBottomOrCentre() {
        let coord = src("MetalGridCoordinator.swift")
        guard let dr = coord.range(of: "func resizePresentationSlots") else {
            Issue.record("resizePresentationSlots missing")
            return
        }
        let db = String(
            coord[
                dr
                    .lowerBound..<(coord.index(dr.lowerBound, offsetBy: 1600, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(
            db.containsCodeFragmentIgnoringWhitespace(
                "presentationResizeBottomPinned ? viewportHeight : viewportHeight / 2"
            ),
            "the scale anchor must be the last row when bottom-pinned, else the centre")
        #expect(
            coord.contains("func windowResizeReleaseScrollY()")
                && coord.contains("presentationResizeBottomPinned ? bottomAnchoredScroll() : centerAnchoredScroll()"),
            "the release scroll must be bottom-anchored when pinned, else centre-anchored")
        guard let bp = coord.range(of: "func beginPresentationResize()") else {
            Issue.record("beginPresentationResize missing")
            return
        }
        let bb = String(
            coord[
                bp
                    .lowerBound..<(coord.index(bp.lowerBound, offsetBy: 1500, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(
            bb.contains("presentationResizeBottomPinned = Self.resizeIsBottomPinned"),
            "begin must record the bottom-pin state")
        #expect(
            bb.contains("captureBottomAnchor()") && bb.contains("captureCenterAnchor()"),
            "begin must capture BOTH anchors so either can settle")
    }

    // The vertical counter-scroll slide applies only to a pure-height drag. When width also
    // changing (a corner drag) the tiles scale and the resize anchor already places the content vertically - adding
    // the slide double-counts and snaps back on release. So `layout()` gates the slide off when the width changes.
    @Test func cornerResizeGatesVerticalShift() {
        let host = src("MetalGridScrollHost.swift")
        guard let lr = host.range(of: "override func layout()") else {
            Issue.record("layout() missing")
            return
        }
        let lb = String(
            host[lr.lowerBound..<(host.index(lr.lowerBound, offsetBy: 2600, limitedBy: host.endIndex) ?? host.endIndex)]
        )
        #expect(
            lb.contains("widthChanging ? 0 : verticalCounterScroll("),
            "the vertical slide must be gated off while the width is changing (corner drag)")
    }

    // The duplicate content-size callback is frozen during presentation.
    @Test func contentSizeCallbackFrozenDuringPresentation() {
        let host = src("MetalGridScrollHost.swift")
        guard let range = host.range(of: "coordinator.onContentSizeChange = {") else {
            Issue.record("onContentSizeChange wiring missing")
            return
        }
        let body = String(
            host[
                range
                    .lowerBound..<(host.index(range.lowerBound, offsetBy: 240, limitedBy: host.endIndex)
                    ?? host.endIndex)])
        #expect(body.contains("presentationResizeActive"), "applyContentSize must be gated off while presenting")
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

    // Release arms animated settle only when a future responsive layout changes columns and source differs from target.
    // Fixed-column resize normally settles instantly; the host wiring remains dormant unless that guard is satisfied.
    @Test func releaseArmsAnimatedSettleWiring() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(
            coord.contains("func beginResizeSettle(targetScrollY:")
                && coord.contains("plan.columns != startCols")
                && coord.contains("let delta = Self.maxIndexedRectDelta(source: source, target: target)")
                && coord.contains("delta > 1.5"),
            "begin must arm only when the release layout changed columns and source differs from target")
        #expect(
            coord.contains("if resizeSettleActive {") && coord.contains("drawResizeSettle(in: view"),
            "draw() must render the settle morph")
        let host = src("MetalGridScrollHost.swift")
        #expect(
            host.contains("coordinator.beginResizeSettle(targetScrollY: settledY)"),
            "release arms the settle with the settled scroll")
        #expect(
            host.contains("if coordinator.isResizeSettling { advanceResizeSettle() }")
                && host.contains("coordinator.resizeSettleProgress = CGFloat(t)"),
            "the display tick advances the settle to completion")
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

    // A height change keeps the same surface and slides it vertically without scaling tiles.
    // drawPresentationResize offsets each scaled rect by presentationVerticalShift, and layout() presents both axes
    // synchronously; the heightChanged path does not rebase on every tick.
    @Test func verticalDragSlidesTheSnapshotNoFallback() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "func resizePresentationSlots") else {
            Issue.record("resizePresentationSlots missing")
            return
        }
        let body = String(
            coord[
                range
                    .lowerBound..<(coord.index(range.lowerBound, offsetBy: 1400, limitedBy: coord.endIndex)
                    ?? coord.endIndex)])
        #expect(
            body.contains("presentationVerticalShift")
                && body.containsCodeFragmentIgnoringWhitespace("offsetBy(dx: 0, dy: dy)"),
            "the vertical drag must SLIDE the scaled snapshot (tiles keep size)")
        let host = src("MetalGridScrollHost.swift")
        #expect(
            host.contains("verticalCounterScroll(start: liveResizeStartFrame, current: newFrame)"),
            "layout() sets the per-tick vertical slide (gated to pure-vertical)")
        #expect(!host.contains("if !heightChanged"), "the heightChanged fallback (the flicker path) must be gone")
    }

    // Settle is axis-aware: a width change uses the fixed-column release path; a pure vertical
    // change settles to the counter-scrolled scroll (start − slide), with no animation.
    @Test func settleIsAxisAware() {
        let host = src("MetalGridScrollHost.swift")
        let db = funcBody(host, "func windowDidEndLiveResize()")
        guard !db.isEmpty else {
            Issue.record("windowDidEndLiveResize missing")
            return
        }
        #expect(db.contains("widthChanged"), "the settle must branch on the resize axis")
        #expect(
            db.contains("presentationStartScrollY - coordinator.presentationVerticalShift"),
            "pure vertical settles to the counter-scrolled scroll")
        #expect(
            db.contains("widthChanged && coordinator.beginResizeSettle"),
            "the reserved release-settle guard is width-only")
    }

    // At content edges the vertical slide clamps effective scroll to [0, maxScroll] without pulling a void
    // open below the last row / above the first): a grow at the bottom pins the last row and reveals older rows up
    // top, and vice-versa.
    @Test func verticalSlideClampsToContentBounds() {
        let host = src("MetalGridScrollHost.swift")
        guard let r = host.range(of: "func verticalCounterScroll(") else {
            Issue.record("verticalCounterScroll missing")
            return
        }
        let body = String(
            host[r.lowerBound..<(host.index(r.lowerBound, offsetBy: 1500, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(
            body.contains("spacer.frame.height") && body.contains("min(max(0, startScrollY - rawShift), maxScroll)"),
            "the vertical slide must clamp the effective scroll to the content bounds")
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

    // Sidebar open and close interpolate the captured grid to a canonical target resolved once at transition start.
    // The Metal surface remains full-width behind the glass, while the q=1 cell geometry already equals the settled
    // obstruction layout. Fixed columns do not arm a second release morph.
    @Test func sidebarOpenCloseScalesTheGrid() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(
            coord.contains("func beginSidebarResize(") && coord.contains("presentationScaledRectRightAnchored"),
            "unmatched overscan slots retain the right-edge fallback mapping")
        #expect(
            coord.contains("if presentationSidebarActive {") && coord.contains("drawSidebarResize(in: view"),
            "draw() renders the sidebar transition")
        #expect(
            coord.contains("sidebarObstructionInset = presentationSidebarToEventInset"),
            "commit the sidebar WIDTH (engine re-adds the gap), not the layout inset")
        #expect(
            coord.contains("presentationSidebarTargetSlots = targetPlan.visibleSlots.map")
                && coord.contains("targetByIndex[source.index]")
                && coord.contains("maxIndexedRectDelta(source: source, target: target)"),
            "the slide must resolve its target once, interpolate to it, and commit that exact geometry")
        #expect(
            coord.contains("presentationSidebarBottomPinned")
                && coord.contains("bottomAnchoredScroll(width: toLayoutW)")
                && coord.contains("centerAnchoredScroll(width: toLayoutW)"),
            "the sidebar settle must bottom-anchor only at newest; middle-of-timeline toggles stay centre-anchored")
        #expect(
            coord.contains("if presentationSidebarActive { cancelSidebarResize() }"),
            "a new toggle / window resize supersedes the in-flight sidebar scale")
        let host = src("MetalGridScrollHost.swift")
        #expect(
            host.contains("coordinator.beginSidebarResize(fromInset: oldValue, toInset: eventLeadingInset)"),
            "an inset change arms the sidebar scale")
        #expect(
            host.contains("if coordinator.isSidebarResizing { advanceSidebarResize() }")
                && host.contains("coordinator.presentationSidebarProgress = CGFloat(t)"),
            "the display tick drives the sidebar scale")
    }

    // A fresh pinch must not capture its level-0 transaction from a mixed geometry state. Sidebar
    // open/close, resize-settle, and commit-bridge are presentation-only states; finish them before cursor/anchor
    // capture so layout width + leading inset are already committed.
    @Test func pinchStartFinishesInFlightGridPresentationBeforeAnchorCapture() {
        let host = src("MetalGridScrollHost.swift")
        guard let began = host.range(of: "case .began:"),
            let anchor = host.range(
                of: "let cursorContent = cursorContentPoint(for: event)", range: began.lowerBound..<host.endIndex),
            let fence = host.range(
                of: "finishInFlightGridPresentationForGestureStart()", range: began.lowerBound..<anchor.lowerBound)
        else {
            Issue.record("pinch begin must finish in-flight grid presentations before cursor/anchor capture")
            return
        }
        #expect(fence.lowerBound < anchor.lowerBound)
        guard let helper = host.range(of: "private func finishInFlightGridPresentationForGestureStart()") else {
            Issue.record("gesture-start geometry fence helper missing")
            return
        }
        let body = String(
            host[
                helper
                    .lowerBound..<(host.index(helper.lowerBound, offsetBy: 1800, limitedBy: host.endIndex)
                    ?? host.endIndex)])
        #expect(
            body.contains("coordinator.endSidebarResize()"),
            "sidebar presentation must commit its target inset before pinch")
        #expect(
            body.contains("coordinator.endResizeSettle()"), "resize settle must not overlap a fresh pinch transaction")
        #expect(
            body.contains("coordinator.endCommitBridge()"), "commit bridge must not overlap a fresh pinch transaction")
        #expect(
            body.contains("applyContentSize(coordinator.contentSize())"),
            "sidebar completion must refresh content geometry")
    }

    // Toolbar and keyboard plus/minus transitions must be display-link paced. The transition plan itself is pure
    // GridCore; the AppKit host must keep requesting frames while a click plan is active, otherwise 7 and 9 can build
    // a valid plan but show no visible animation.
    @Test func clickTransitionKeepsDisplayLinkActive() {
        let host = src("MetalGridScrollHost.swift")
        #expect(
            host.contains("coordinator.gridTransition.activeKind == .click { requestFrame() }"),
            "the display tick must request frames for active click transitions")
        #expect(
            host.contains("|| coordinator.gridTransition.activeKind == .click"),
            "active click transitions must keep the display link awake until they settle")
    }

    // The coordinator applies a constant outer gutter through the render inset and width trim.
    // The engine remains unchanged, and gesture-start and settled widths stay aligned across levels.
    @Test func gridHasConstantOuterMargin() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("static let standardOuterMargin"), "the outer gutter must be a named constant")
        #expect(
            coord.contains("func gridHorizontalMargin(forLevel") && coord.contains("Self.standardOuterMargin"),
            "the outer margin must be the CONSTANT gutter (level-independent ⇒ layoutWidth level-independent), 0 on overviews"
        )
        #expect(
            !coord.contains("monthLabels ? 0 : engine.metrics(level: lvl).gap"),
            "the gutter must NOT be the per-level gap (that made layoutWidth level-dependent → the pinch/± commit jump)"
        )
        #expect(
            coord.contains("sidebarObstructionInset + gap + gridHorizontalMargin(forLevel: lvl)"),
            "the LEFT margin folds into the leading inset")
        #expect(coord.contains("GridRenderBounds("), "per-level render/layout bounds must be a named pure value")
        #expect(
            coord.contains("trailingInset: gridHorizontalMargin(forLevel: lvl)"),
            "the RIGHT margin trims the (per-level) layout width")
        #expect(
            coord.contains("renderBounds(forLevel: lvl).layoutWidth"),
            "layout width must come from the per-level bounds policy")
    }
}
