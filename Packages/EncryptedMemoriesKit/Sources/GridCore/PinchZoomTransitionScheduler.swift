// PinchZoomTransitionScheduler.swift
//
// Builds the immutable pinch plan. Component windows are fixed-width and ordered from the center out.
// The host supplies progress from the gesture; this scheduler owns no timer or gesture state.

import CoreGraphics

package enum PinchZoomTransitionScheduler {
    package static func makePlan(
        source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
        viewportSize: CGSize, tuning: GridTransitionTuning = .default
    ) -> GridTransitionPlan? {
        guard
            let lat = GridTransitionComponentBuilder.build(
                source: source, target: target,
                anchorIndex: anchorIndex, viewportSize: viewportSize),
            !lat.components.isEmpty
        else { return nil }
        return makePlan(lattice: lat, sourceLevel: source.levelID, targetLevel: target.levelID, tuning: tuning)
    }

    package static func makePlan(
        lattice lat: GridTransitionLattice, sourceLevel: Int, targetLevel: Int,
        tuning: GridTransitionTuning = .default
    ) -> GridTransitionPlan? {
        guard !lat.components.isEmpty else { return nil }
        let windows = GridTransitionScheduler.pinchWindows(components: lat.components, tuning: tuning)
        guard windows.count == lat.components.count else { return nil }
        return GridTransitionComponentBuilder.assemble(
            kind: .pinch, lattice: lat, windows: windows,
            sourceLevel: sourceLevel, targetLevel: targetLevel,
            durationMs: 0, curve: tuning.localAlphaCurve)
    }
}
