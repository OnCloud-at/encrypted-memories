// ClickZoomTransitionScheduler.swift
//
// Builds the immutable click plan for toolbar zoom commands. Component windows are
// area-weighted, and progress is owned by the host's trapezoidal clock.

import CoreGraphics

package enum ClickZoomTransitionScheduler {
    /// Builds a click transition plan from a precomputed presentation lattice, or returns `nil` when the
    /// caller must snap.
    package static func makePlan(
        lattice lat: GridTransitionLattice, sourceLevel: Int, targetLevel: Int,
        tuning: GridTransitionTuning = .default
    ) -> GridTransitionPlan? {
        guard !lat.components.isEmpty else { return nil }
        let windows = GridTransitionScheduler.clickWindows(components: lat.components, tuning: tuning)
        guard windows.count == lat.components.count else { return nil }  // every component scheduled
        return GridTransitionComponentBuilder.assemble(
            kind: .click, lattice: lat, windows: windows,
            sourceLevel: sourceLevel, targetLevel: targetLevel,
            durationMs: tuning.clickDurationMs, curve: tuning.localAlphaCurve)
    }

    /// Returns canonical click progress at elapsed time `t`.
    package static func progress(atElapsed t: Double, tuning: GridTransitionTuning = .default) -> Double {
        GridTransitionScheduler.clickQ(
            t, durationSeconds: tuning.clickDurationSeconds,
            rampFraction: tuning.clickRampFraction)
    }
}
