/// GPU-free state machine that decides which frozen dissolve layers need rasterization.
///
/// During a held gesture only the blend progress changes. A layer must be rasterized again after a drawable
/// resize, a new plan, or a thumbnail update. The renderer uses this state to keep steady frames composite-only.
package struct DissolveLayerCache: Equatable {
    private var renderedSource = false
    private var renderedTarget = false
    private var size: SIMDSizeless?

    // A tiny value type so we don't pull SIMD/CoreGraphics in just for an (Int, Int) pair.
    private struct SIMDSizeless: Equatable {
        var width: Int
        var height: Int
    }

    package init() {}

    /// Decide which layers to (re)raster this frame and record that they will be. `redrawSource`/`redrawTarget`
    /// are the caller's content-arrival requests (a wanted thumbnail for that layer became resident/upgraded).
    /// A drawable-size change forces both (the offscreen textures are reallocated, so their contents are gone),
    /// and a layer that has never been rasterized for the current plan is always drawn.
    package mutating func plan(
        redrawSource: Bool, redrawTarget: Bool, width: Int, height: Int
    ) -> (source: Bool, target: Bool) {
        let incoming = SIMDSizeless(width: width, height: height)
        if size != incoming {
            renderedSource = false
            renderedTarget = false
            size = incoming
        }
        let drawSource = redrawSource || !renderedSource
        let drawTarget = redrawTarget || !renderedTarget
        if drawSource { renderedSource = true }
        if drawTarget { renderedTarget = true }
        return (drawSource, drawTarget)
    }

    /// A new dissolve plan replaced the old one (a fresh begin): forget both rasters so the next frame redraws
    /// the new plan's geometry. Keeps the size (same drawable), so only content, not the surface, is invalidated.
    package mutating func invalidate() {
        renderedSource = false
        renderedTarget = false
    }

    /// The dissolve ended (commit/finish): forget everything, so the next dissolve starts from a clean slate
    /// and the renderer can free the offscreen textures.
    package mutating func release() {
        renderedSource = false
        renderedTarget = false
        size = nil
    }

    // Test/inspection surface.
    package var hasRenderedSource: Bool { renderedSource }
    package var hasRenderedTarget: Bool { renderedTarget }
}
