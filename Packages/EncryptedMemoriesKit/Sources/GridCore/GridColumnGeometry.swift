import CoreGraphics

package enum GridApparentMetrics {
    package static func slotSide(at x: CGFloat, width: CGFloat, levels: [GridLevelMetrics]) -> CGFloat {
        func side(_ i: Int) -> CGFloat {
            GridColumnGeometry(columns: levels[i].nominalColumns, gap: levels[i].gap, width: width).side
        }
        let last = levels.count - 1
        if x <= 0 { return side(0) * (1 - x * 0.6) }
        if x >= CGFloat(last) { return side(last) }
        let lo = Int(x)
        let t = x - CGFloat(lo)
        return side(lo) + (side(lo + 1) - side(lo)) * t * t * (3 - 2 * t)
    }

    /// The apparent gap for a continuous level position `x`: the gap of the bracketing detents, eased with the
    /// smoothstep curve, and the gap of the first or last level beyond the ladder.
    package static func gap(at x: CGFloat, levels: [GridLevelMetrics]) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].gap }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].gap }
        let lo = Int(x)
        let from = levels[lo].gap
        return from + (levels[lo + 1].gap - from) * gridSmoothstep(x - CGFloat(lo))
    }
}

/// The smoothstep curve `3t^2 - 2t^3` of `x` clamped into 0...1: zero slope at both ends.
package func gridSmoothstep(_ x: CGFloat) -> CGFloat {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// One horizontal mapping for slot placement, queries and zoom.
package struct GridColumnGeometry: Equatable, Sendable {
    package let columns: Int
    package let side: CGFloat
    package let gap: CGFloat

    package var pitch: CGFloat { side + gap }

    package init(columns: Int, gap: CGFloat, width: CGFloat) {
        self.columns = max(1, columns)
        self.gap = max(0, gap)
        side = SquareTileGridEngine.nominalSlotSide(columns: columns, gap: gap, width: width)
    }

    package func origin(of column: Int) -> CGFloat {
        CGFloat(column) * pitch
    }

    package func column(at x: CGFloat) -> Int {
        guard pitch > 0, pitch.isFinite, x.isFinite else { return 0 }
        return min(max(Int(x / pitch), 0), columns - 1)
    }
}
