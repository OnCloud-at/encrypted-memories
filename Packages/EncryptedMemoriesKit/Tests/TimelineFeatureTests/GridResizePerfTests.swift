import CoreGraphics
import Foundation
import GridCore
import Testing

@testable import TimelineFeature

// Resize/render contract: resize is redraw-only (no texture reload / sync decode),
// the visible query is bounded to the viewport+overscan, the pipeline is built once, diagnostics are throttled,
// and pure-height resize doesn't recompute width-derived metrics/contentSize.
@Suite struct GridResizePerfTests {
    private func engine(_ count: Int = 20000) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }
    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }
    private func src(_ name: String) -> String {
        for target in [
            "TimelineFeature", "GridCore", "MetalRenderingCore", "MediaFeedCore", "MediaCacheAppKitAdapter",
            "MediaCacheUIKitAdapter", "TimelineUIKitFeature",
        ] {
            let rel = "Packages/EncryptedMemoriesKit/Sources/\(target)/\(name)"
            if let source = try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8) {
                return source
            }
        }
        return ""
    }
    private func appSrc(_ path: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("App/\(path)"), encoding: .utf8)) ?? ""
    }

    // Pure-height resize leaves width-derived metrics and contentSize unchanged.
    @Test func pureHeightResizeDoesNotRecomputeWidthMetrics() {
        let e = engine()
        let before = e.resolvedMetrics(level: 2, width: 1000)
        let r = e.rebasedScrollOffsetForViewportChange(
            GridViewportResizeInput(
                oldViewportFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                newViewportFrame: CGRect(x: 0, y: 200, width: 1000, height: 800),
                oldScrollY: 6000, level: 2, committedPhase: nil, itemCount: 20000,
                wasBottomPinned: false, anchorFractionY: 0.5))
        let after = e.resolvedMetrics(level: 2, width: 1000)
        #expect(before == after, "width-derived metrics must be identical on a pure-height resize")
        #expect(
            r.newContentSize.height == e.contentSize(level: 2, width: 1000).height,
            "contentSize unchanged when width unchanged")
        // The coordinator's resize signpost reports metricsRecomputed = widthChanged (false for pure height).
        #expect(src("MetalGridCoordinator.swift").contains("metricsRecomputed: delta.widthChanged"))
    }

    // The resize path requests a redraw only; it must not reload textures or touch the cache.
    @Test func resizeDoesNotTriggerTextureReload() {
        let host = src("MetalGridScrollHost.swift")
        guard let range = host.range(of: "private func rebaseForResize") else {
            Issue.record("rebaseForResize missing")
            return
        }
        let body = String(
            host[
                range
                    .lowerBound..<(host.index(range.lowerBound, offsetBy: 1100, limitedBy: host.endIndex)
                    ?? host.endIndex)])
        #expect(
            !body.contains("cache") && !body.contains("streamTextures") && !body.contains("reload")
                && !body.contains("upload"),
            "resize must not reload textures - redraw only")
        // The coordinator's resize rebase likewise does no texture work (it only reads uploadsThisFrame for the signpost).
        let coord = src("MetalGridCoordinator.swift")
        if let cr = coord.range(of: "func rebaseForViewportChange") {
            let cbody = String(
                coord[
                    cr
                        .lowerBound..<(coord.index(cr.lowerBound, offsetBy: 1800, limitedBy: coord.endIndex)
                        ?? coord.endIndex)])
            #expect(!cbody.contains("streamTextures") && !cbody.contains("cache.texture") && !cbody.contains("reload"))
        }
    }

    @Test func sidebarPresentationStreamsTargetOnlyVisibleSlots() throws {
        let coordinator = src("MetalGridCoordinator.swift")
        let start = try #require(coordinator.range(of: "private func drawSidebarResize("))
        let end = try #require(
            coordinator.range(
                of: "    /// Presents the window-resize snapshot geometry",
                range: start.upperBound..<coordinator.endIndex
            )
        )
        let body = coordinator[start.lowerBound..<end.lowerBound]

        #expect(body.contains("GridTextureStreamingPolicy.transitionWindow"))
        #expect(body.contains("streamTextures"))
        #expect(body.contains("presentationSidebarTargetSlots"))
    }

    // The visible-slot query is bounded to viewport plus overscan, not the whole library.
    @Test func visibleSlotQueryBoundedToViewportOverscan() {
        let e = engine(20000)
        let plan = e.framePlan(
            level: 2, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 50000),
            overscan: 200, columnPhase: nil)
        #expect(plan.visibleSlots.count < 600, "visible query must be bounded, got \(plan.visibleSlots.count) of 20000")
        #expect(!plan.visibleSlots.isEmpty)
    }

    @Test func hundredThousandAssetProjectionRemainsViewportBounded() {
        let e = engine(100_000)
        let viewport = CGSize(width: 1_024, height: 1_366)
        let offsets = stride(from: CGFloat(0), through: CGFloat(1_200_000), by: 5_000)
        var maximumVisible = 0
        var projectionCount = 0
        let started = ContinuousClock.now

        for offset in offsets {
            let plan = e.framePlan(
                level: 2,
                viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: offset),
                overscan: 320,
                columnPhase: nil
            )
            maximumVisible = max(maximumVisible, plan.visibleSlots.count)
            projectionCount += 1
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        print("[Grid100kProjection] projections=\(projectionCount) maxVisible=\(maximumVisible) elapsed=\(elapsed)")
        #expect(maximumVisible > 0)
        #expect(maximumVisible < 600, "100k projection must remain bounded to viewport and overscan")
    }

    // The render pipeline is created once in init, never per render or resize frame.
    @Test func rendererDoesNotRecreatePipelineOnResize() {
        let r = src("MetalGridRenderer.swift")
        guard let initRange = r.range(of: "init"), let renderRange = r.range(of: "func render") else {
            Issue.record("renderer shape")
            return
        }
        let pipelineIdx = r.range(of: "makeRenderPipelineState")
        #expect(pipelineIdx != nil, "pipeline must be created")
        #expect(
            pipelineIdx!.lowerBound > initRange.lowerBound && pipelineIdx!.lowerBound < renderRange.lowerBound,
            "pipeline must be built in init, before/outside render()")
        let renderBody = String(r[renderRange.lowerBound..<r.endIndex])
        #expect(!renderBody.contains("makeRenderPipelineState"), "render() must NOT recreate the pipeline")
    }

    // Renderer internals take a drawable boundary, not an MTKView. This keeps the MTKView/AppKit edge
    // thin so the Metal renderer can later move behind a platform-neutral adapter.
    @Test func rendererUsesDrawableTargetBoundary() {
        let r = src("MetalGridRenderer.swift")
        let renderingCore = src("MetalGridRenderPrimitives.swift")
        let adapter = src("MetalGridRenderer+MTKView.swift")
        #expect(renderingCore.contains("struct MetalGridDrawableTarget"))
        #expect(adapter.contains("guard let target = MetalGridDrawableTarget(view: view) else { return }"))
        #expect(adapter.contains("init?(view: MTKView)"))
        #expect(r.containsCodeFragmentIgnoringWhitespace("func render(to target: MetalGridDrawableTarget"))
        #expect(r.containsCodeFragmentIgnoringWhitespace("func renderLayerDissolve(to target: MetalGridDrawableTarget"))

        guard let renderStart = r.range(of: "func render("),
            let renderEnd = r.range(of: "/// Set the shared per-frame state")
        else {
            Issue.record("drawable-target render body missing")
            return
        }
        let renderBody = String(r[renderStart.lowerBound..<renderEnd.lowerBound])
        #expect(!renderBody.contains("MTKView"))
        #expect(!renderBody.contains("currentDrawable"))
        #expect(!renderBody.contains("currentRenderPassDescriptor"))
        #expect(!r.contains("import MetalKit"), "shared renderer must not import the view-hosting MetalKit layer")
    }

    // Resize diagnostics are throttled while a live drag fires per frame.
    @Test func resizeDiagnosticsThrottled() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(
            coord.contains("lastResizeDiagTime") && coord.contains("> 0.33"), "GridResize logs must be time-throttled")
        #expect(
            src("GridZoomCommit.swift").contains("throttleSeconds: 0.5"), "MetalGridPerf signposts must be throttled")
    }

    @Test func metalGridPerfSplitsCpuEncodeAndGpuTime() {
        let coord = src("MetalGridCoordinator.swift")
        let types = src("MetalGridTypes.swift")
        #expect(coord.contains("\"drawMs\""))
        #expect(coord.contains("\"gpuMs\""))
        #expect(types.contains("var drawMs: Double"))
        #expect(types.contains("var gpuMs: Double"))
        #expect(!coord.contains("gpuDrawMs"))
        #expect(!types.contains("gpuDrawMs"))
    }

    // Sidebar animation must not emit synchronous probe I/O on the toggle path.
    @Test func sidebarAnimationHasNoPerFrameProbeLogging() {
        let main = appSrc("Views/MainView.swift")
        #expect(!main.contains("SidebarProbe"))
        #expect(!main.contains("logSidebarProbe"))
        #expect(!main.contains(".onChange(of: geo.safeAreaInsets.leading)"))
        #expect(!main.contains(".onChange(of: geo.size.width)"))
    }

    // The host must not run a permanent display link. It wakes for real animation or streaming work and
    // pauses again once the viewport is idle and the visible thumbnails are resident.
    @Test func displayLinkIdlesAndWakesForThumbnailArrival() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("private var displayLinkWakeUntil"))
        #expect(host.contains("private func requestFrame(keepDisplayLinkAlive: Bool = true)"))
        #expect(host.contains("streamingTick?.isPaused = !displayLinkHasActiveWork(now: now)"))
        #expect(host.contains("coordinator.hasPendingVisibleThumbnails"))
        #expect(host.contains("source.onImagesAvailable = { [weak self]"))
        #expect(
            !host.contains("streamingTick?.isPaused = false\n            requestFrame()"),
            "view attach should not leave the display link permanently unpaused")

        let dataSource = src("MetalGridDataSource.swift")
        #expect(dataSource.contains("var onImagesAvailable: (() -> Void)? { get set }"))
        #expect(dataSource.contains("self?.onImagesAvailable?()"))
        #expect(
            dataSource.contains("feed.feedCore.setOnImagesAvailableWake"),
            "macOS must subscribe to the shared feed-core arrival wake, not a platform-local callback bridge")
        let core = src("ThumbnailFeedCore.swift")
        #expect(
            core.contains("public nonisolated func setOnImagesAvailableWake"),
            "the platform hosts should share one core wake registration entry point")
        #expect(
            src("UIKitTimelineGridHost.swift").contains("thumbnailFeed.feedCore.setOnImagesAvailableWake"),
            "iOS must use the same shared feed-core wake entry point")
        #expect(!src("ThumbnailFeed.swift").contains("func setOnImagesAvailable("))
        #expect(!src("UIKitThumbnailFeed.swift").contains("func setOnImagesAvailable("))
    }

    @Test func thumbnailViewportUsesOneReplaceableCoreQueue() {
        let dataSource = src("MetalGridDataSource.swift")
        #expect(
            dataSource.contains("feed.submitVisibleDiskDecodeDemand(incoming)"),
            "moving viewport decode must replace one Core-owned disk-only demand queue")
        #expect(
            !dataSource.contains("visibleDiskDemandGeneration"),
            "a replaceable platform data source must not own the feed-lifetime generation")
        #expect(
            !dataSource.contains("Task { [feed]"),
            "display ticks must not create an actor-message backlog for obsolete viewports")
        #expect(!dataSource.contains("pumpWarm"))
        #expect(!dataSource.contains("cancelWarmBatch"))
        #expect(
            !dataSource.contains("warmBatchInFlight"),
            "macOS must not retain per-viewport task groups that outlive cancellation")
        let core = src("ThumbnailFeedCore.swift")
        #expect(core.contains("struct LatestVisibleDecodeDemand"))
        #expect(core.contains("private var visibleDiskDemand = LatestVisibleDecodeDemand()"))
        #expect(core.contains("public nonisolated func submitVisibleDiskDecodeDemand("))
        #expect(
            core.contains("private var nextGeneration: UInt64 = 0"),
            "the feed-lifetime mailbox must own monotonic viewport ordering")
        #expect(
            core.contains("final class ThumbnailDecodeWorkExecutor"),
            "blocking Foundation, CryptoKit and ImageIO work must leave Swift's cooperative executor")
        #expect(
            core.contains("actor DecodePermitPool"),
            "all decode paths must retain one feed-wide admission budget")
        #expect(core.contains("private let decodePermits: DecodePermitPool"))
        #expect(core.contains("decodePermits.acquire(priority: .visibleNow)"))
        #expect(
            core.contains("await decodePermits.release()"),
            "each decrypt/decode lane must be returned after its blocking work completes")
    }

    @Test func overscanIsNotPinnedWhileVisibleThumbnailsAreCold() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(
            coord.contains(
                "let pinOverscan = visibleUIDs.allSatisfy { cache.isResident($0) || !dataSource.canRetryThumbnail(for: $0) }"
            ))
        #expect(coord.contains("pinOverscan: pinOverscan"))
    }

    @Test func unfetchableVisibleThumbnailsDoNotKeepDisplayLinkPending() {
        let coord = src("MetalGridCoordinator.swift")
        let dataSource = src("MetalGridDataSource.swift")
        #expect(dataSource.contains("func canRetryThumbnail(for uid: PhotoUID) -> Bool"))
        #expect(coord.contains("private func hasRetryableMissingVisibleTexture"))
        #expect(coord.contains("dataSource.canRetryThumbnail(for: $0)"))
        #expect(coord.contains("!dataSource.canRetryThumbnail(for: $0)"))
        #expect(
            !coord.contains("visibleUIDs.contains { !cache.isResident($0) }"),
            "pending visible work must ignore backend-refused, non-retryable thumbnails")
    }

    // The resize rebase is pure geometry; texture work stays in the cache.
    @Test func noSynchronousDecodeOnResizePath() {
        let resizeSrc = src("GridViewportResizeRebase.swift")
        #expect(
            !resizeSrc.contains("decode") && !resizeSrc.contains("NSImage") && !resizeSrc.contains("CGImage")
                && !resizeSrc.contains("texture"), "the resize rebase must be pure geometry - no decode/texture work")
        // It only depends on CoreGraphics geometry (no AppKit / image APIs).
        #expect(
            resizeSrc.contains("import CoreGraphics") && !resizeSrc.contains("import AppKit")
                && !resizeSrc.contains("import MetalKit"))
    }
}
