import CoreGraphics

// MARK: - Overview Layer Dissolve
//
// Overview boundaries dissolve between two complete static grid layers rather than relocating individual
// cells. Both layers are resolved at gesture start and blended by opacity.
//
// The source keeps its display mode. The target uses `squareFillCrop` because overview levels are square-only.
//
// Renderer requirement: correct blending over the shared dark background needs offscreen layer compositing.
// This type is the renderer-independent plan; it does not rasterize.

/// Smootherstep easing for the layer crossfade (matches the transition family's curve shape). Pure.
public func overviewDissolveEase(_ q: Double) -> Double {
    let x = min(1, max(0, q))
    return x * x * x * (x * (x * 6 - 15) + 10)
}

/// The linear cross-dissolve applied by the offscreen composite shader.
public func overviewDissolveMix(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

/// Reference single-pass premultiplied source-over dissolve over a shared background.
public func overviewDissolveSinglePassBleed(_ a: Double, _ b: Double, _ bg: Double, _ t: Double) -> Double {
    b * t + a * (1 - t) * (1 - t) + bg * t * (1 - t)
}

/// Immutable plan for one overview layer dissolve. The frame plans are already settled; only `q` changes.
public struct OverviewLayerDissolvePlan: Equatable, Sendable {
    public let sourceLevel: Int
    public let targetLevel: Int
    /// Source grid as it appears settled at `sourceLevel`.
    public let source: GridFramePlan
    /// Target grid as it appears settled at `targetLevel`, including its anchored scroll.
    public let target: GridFramePlan
    /// Display mode used by the source grid.
    public let sourceDisplayMode: TileContentDisplayMode
    /// The target's display mode - `squareFillCrop` for the overview levels.
    public let targetDisplayMode: TileContentDisplayMode
    /// Where the target settles (commit info): the anchored scroll-Y and column phase for `targetLevel`.
    public let targetScrollY: CGFloat
    public let targetColumnPhase: Int?
    /// Dissolve progress: 0 = pure source, 1 = pure target.
    public let q: Double

    public init(
        sourceLevel: Int, targetLevel: Int, source: GridFramePlan, target: GridFramePlan,
        sourceDisplayMode: TileContentDisplayMode, targetDisplayMode: TileContentDisplayMode,
        targetScrollY: CGFloat, targetColumnPhase: Int?, q: Double
    ) {
        self.sourceLevel = sourceLevel
        self.targetLevel = targetLevel
        self.source = source
        self.target = target
        self.sourceDisplayMode = sourceDisplayMode
        self.targetDisplayMode = targetDisplayMode
        self.targetScrollY = targetScrollY
        self.targetColumnPhase = targetColumnPhase
        self.q = q
    }

    /// Opacity of the source layer.
    public var sourceOpacity: Double { 1 - overviewDissolveEase(q) }
    /// Opacity of the target layer.
    public var targetOpacity: Double { overviewDissolveEase(q) }

    /// Returns a copy at a new progress. Frame plans and display modes remain unchanged.
    public func withProgress(_ newQ: Double) -> OverviewLayerDissolvePlan {
        OverviewLayerDissolvePlan(
            sourceLevel: sourceLevel, targetLevel: targetLevel, source: source, target: target,
            sourceDisplayMode: sourceDisplayMode, targetDisplayMode: targetDisplayMode,
            targetScrollY: targetScrollY, targetColumnPhase: targetColumnPhase,
            q: min(1, max(0, newQ)))
    }
}

public extension SquareTileGridEngine {
    /// Build an overview layer dissolve from level `s` to adjacent level `t` (must be an overview boundary).
    /// The source plan is the current settled grid (its own scroll + display mode); the target plan is the
    /// adjacent overview grid, anchored so the item under the cursor stays under the cursor, in square mode.
    /// Pure: it composes settled `framePlan`s + the engine's anchor math - no relocation, no transition builder.
    /// Returns `nil` when the levels are not an overview boundary or the anchor is unavailable.
    ///
    /// The target scroll is clamped to the same range used by the settled grid. Cursor anchoring normally wins.
    /// When zooming out from a bottom-pinned source, the target remains bottom-filled.
    /// `targetMaxY` is 0 when the target content is shorter than the viewport, so a short target settles at 0
    /// (never stretched/faked). Direction is read from the levels (the ladder is monotonic in density, so
    /// `targetLevel > sourceLevel` ⟺ zooming out).
    func overviewLayerDissolvePlan(
        from s: Int, to t: Int, viewportSize: CGSize, targetViewportSize: CGSize,
        sourceScrollY: CGFloat, sourceColumnPhase: Int?,
        preferredNormalMode: TileContentDisplayMode,
        anchorContentPoint: CGPoint, anchorViewportPoint: CGPoint,
        overscan: CGFloat
    ) -> OverviewLayerDissolvePlan? {
        guard isOverviewBoundary(s, t) else { return nil }
        let width = viewportSize.width
        // The boundary crosses the normal and overview gutter divide, so source and target layout widths differ.
        let targetWidth = targetViewportSize.width
        guard
            let a = anchorItem(
                nearContentPoint: anchorContentPoint, level: s, width: width,
                columnPhase: sourceColumnPhase)
        else { return nil }
        // Display modes: source keeps its own mode; the overview target uses square crop.
        let sourceMode = effectiveContentMode(preferred: preferredNormalMode, level: s)
        // Overview levels use square cropping.
        let targetMode = effectiveContentMode(preferred: preferredNormalMode, level: t)
        // Anchor the target so the cursor's item lands in the cursor's column (no horizontal fly on settle).
        let desiredColumn = cursorColumn(viewportX: anchorViewportPoint.x, level: t, width: targetWidth)
        let targetPhase = columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: t, width: targetWidth)
        let rawTargetScrollY = anchoredScrollOffset(
            flatIndex: a.flatIndex, localFraction: a.localFraction,
            viewportPoint: anchorViewportPoint, level: t, width: targetWidth,
            columnPhase: targetPhase
        ).y
        // Final target scroll = what the settled grid will commit to (clamped; bottom-filled when at the bottom).
        let viewportH = viewportSize.height
        let sourceMaxY = max(0, contentSize(level: s, width: width, columnPhase: sourceColumnPhase).height - viewportH)
        let targetMaxY = max(0, contentSize(level: t, width: targetWidth, columnPhase: targetPhase).height - viewportH)
        let bottomPinEpsilon: CGFloat = 1.0  // ~the settled scroll-clamp tolerance; robust to sub-pixel rounding
        let sourceIsBottomPinned = abs(sourceScrollY - sourceMaxY) <= bottomPinEpsilon
        let isZoomingOut = t > s  // Higher levels are denser.
        // Cursor anchoring normally wins; bottom-fill applies only when zooming out from the bottom.
        let targetScrollY =
            (isZoomingOut && sourceIsBottomPinned)
            ? targetMaxY
            : min(max(0, rawTargetScrollY), targetMaxY)
        let sourcePlan = framePlan(
            level: s, viewportSize: viewportSize, scrollOffset: CGPoint(x: 0, y: sourceScrollY),
            overscan: overscan, columnPhase: sourceColumnPhase)
        let targetPlan = framePlan(
            level: t, viewportSize: targetViewportSize, scrollOffset: CGPoint(x: 0, y: targetScrollY),
            overscan: overscan, columnPhase: targetPhase)
        return OverviewLayerDissolvePlan(
            sourceLevel: s, targetLevel: t, source: sourcePlan, target: targetPlan,
            sourceDisplayMode: sourceMode, targetDisplayMode: targetMode,
            targetScrollY: targetScrollY, targetColumnPhase: targetPhase, q: 0)
    }
}
