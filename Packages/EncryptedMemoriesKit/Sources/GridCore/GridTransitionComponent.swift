// GridTransitionComponent.swift
//
// Lattice keys identify slots relative to the pinned focus item at (0, 0).
// Keys that move between levels form components with separate dissolve windows.

/// Anchor-relative lattice key: integer (row, col) offset from the pinned anchor.
package struct RelativeSlotKey: Hashable, Sendable, Comparable {
    package let dr: Int
    package let dc: Int

    package init(dr: Int, dc: Int) {
        self.dr = dr
        self.dc = dc
    }

    package static func < (lhs: RelativeSlotKey, rhs: RelativeSlotKey) -> Bool {
        (lhs.dr, lhs.dc) < (rhs.dr, rhs.dc)
    }
}

package enum GridTransitionComponentSide: String, Sendable, Equatable {
    case focus, upper, lower
}

/// Lattice keys whose occupants share one dissolve window.
/// `visibleAreaFraction` supplies the scheduler weight.
package struct GridTransitionComponent: Equatable, Sendable, Identifiable {
    package let id: Int
    package let keys: [RelativeSlotKey]
    package let focusDistance: Int
    package let side: GridTransitionComponentSide
    package let visibleAreaFraction: Double
    /// Assigned dissolve window. `nil` means the component is stable or enters without relocation.
    package var window: ClosedRange<Double>?

    package init(
        id: Int,
        keys: [RelativeSlotKey],
        focusDistance: Int,
        side: GridTransitionComponentSide,
        visibleAreaFraction: Double,
        window: ClosedRange<Double>? = nil
    ) {
        self.id = id
        self.keys = keys
        self.focusDistance = focusDistance
        self.side = side
        self.visibleAreaFraction = visibleAreaFraction
        self.window = window
    }
}
