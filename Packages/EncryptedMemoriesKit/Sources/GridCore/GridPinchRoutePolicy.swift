/// Routes the first adjacent step of a live grid pinch.
///
/// Hosts attempt the selected presentation. If plan building fails, they fall back to
/// `GridZoomTransaction` reflow.
public enum GridPinchRoutePolicy {
    public enum Candidate: Equatable, Sendable {
        /// The step stays inside the focus-row chain band, so scrub the shared lattice plan.
        case lattice(target: Int)
        /// The step crosses an overview boundary, so use the two-layer offscreen dissolve.
        case overviewDissolve(target: Int)
        /// Out of ladder bounds or no eligible presentation uses transaction reflow (a short-pinch
        /// release interprets this as "no step" - there is nothing to animate).
        case reflow
    }

    /// The contiguous adjacent-step band around `level` that is lattice-eligible.
    /// An overview start yields a degenerate band (`lo == hi`) and uses reflow routing.
    public static func chainBand(around level: Int, engine: SquareTileGridEngine) -> (lo: Int, hi: Int) {
        var lo = level
        var hi = level
        while lo > 0, engine.metrics(level: lo - 1).transitionKindToNext == .focusRowRelayout { lo -= 1 }
        while hi < engine.levelCount - 1, engine.metrics(level: hi).transitionKindToNext == .focusRowRelayout {
            hi += 1
        }
        return (lo, hi)
    }

    /// Route one resolved pinch direction from `startLevel`. `direction < 0` means zoom in (toward lower
    /// level ids). `chainBand` is the band captured at gesture start, not recomputed per sample.
    public static func candidate(
        startLevel: Int,
        direction: Int,
        chainBand: (lo: Int, hi: Int),
        engine: SquareTileGridEngine
    ) -> Candidate {
        let next = startLevel + (direction < 0 ? -1 : 1)
        guard next >= 0, next < engine.levelCount else { return .reflow }
        if next >= chainBand.lo, next <= chainBand.hi { return .lattice(target: next) }
        if engine.isOverviewBoundary(startLevel, next) { return .overviewDissolve(target: next) }
        return .reflow
    }
}
