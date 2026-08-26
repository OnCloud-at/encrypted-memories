// LocalAlphaCurve.swift
//
// C1 slope-limited local-alpha curve for a single-presentation-lattice transition.
//
// Pure function of a normalized position. It has no state, timer, or clock.
// It is monotone, reversible, and has continuous first derivatives at its joins.

package struct LocalAlphaCurve: Equatable, Sendable {
    /// Smooth-edge fraction `a` on each side. Clamped to the open interval (0, 0.5).
    package let edgeFraction: Double

    package init(edgeFraction: Double = 0.20) {
        self.edgeFraction = min(0.49, max(0.0001, edgeFraction))
    }

    /// Peak slope of f in u-space. = 1.25 at a = 0.20.
    package var coreSlope: Double { 1.0 / (1.0 - edgeFraction) }

    /// f(u): C1 linear-core ramp, clamped to [0,1] outside the unit interval.
    package func value(_ u: Double) -> Double {
        let a = edgeFraction
        let s = coreSlope
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        if u < a { return s * u * u / (2 * a) }
        if u <= 1 - a { return s * a / 2 + s * (u - a) }
        let ud = 1 - u
        return 1 - s * ud * ud / (2 * a)
    }

    /// Maps canonical progress into the specified local window without hysteresis.
    package func localProgress(w0: Double, w1: Double, q: Double) -> Double {
        if w1 <= w0 { return q < w0 ? 0 : 1 }
        return value((q - w0) / (w1 - w0))
    }
}
