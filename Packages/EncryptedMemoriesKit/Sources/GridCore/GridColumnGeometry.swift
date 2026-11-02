import CoreGraphics

package enum GridVerticalDivision {
    /// A usable division has positive width, is taller than wide, and leaves both panes room for every level
    /// of the profile with square sides of at least one point. One failed level rejects the whole profile.
    package static func isUsable(_ frame: CGRect, width: CGFloat, levels: [GridLevelMetrics]) -> Bool {
        !levels.isEmpty
            && levels.allSatisfy {
                fittingSide(frame, width: width, columns: $0.nominalColumns, gap: $0.gap) != nil
            }
    }

    package static func fittingSide(_ frame: CGRect, width: CGFloat, columns: Int, gap: CGFloat) -> CGFloat? {
        guard width.isFinite, width > 0, columns >= 2, columns.isMultiple(of: 2),
            frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
            frame.width > 0, frame.height > frame.width
        else { return nil }
        let edges = edges(frame, gap: gap)
        let pane = min(edges.lowerBound, width - edges.upperBound)
        let half = CGFloat(columns / 2)
        let side = (pane - max(0, gap) * (half - 1)) / half
        return side >= 1 ? side : nil
    }

    package static func edges(_ frame: CGRect, gap: CGFloat) -> ClosedRange<CGFloat> {
        let halfGap = max(gap, frame.width) / 2
        return min(frame.minX, frame.midX - halfGap)...max(frame.maxX, frame.midX + halfGap)
    }
}

package enum GridApparentMetrics {
    package static func slotSide(
        at x: CGFloat, width: CGFloat, levels: [GridLevelMetrics], division: CGRect?
    ) -> CGFloat {
        let division = division.flatMap { GridVerticalDivision.isUsable($0, width: width, levels: levels) ? $0 : nil }
        func side(_ i: Int) -> CGFloat {
            GridColumnGeometry(columns: levels[i].nominalColumns, gap: levels[i].gap, width: width, division: division)
                .side
        }
        let last = levels.count - 1
        if x <= 0 { return side(0) * (1 - x * 0.6) }
        if x >= CGFloat(last) { return side(last) }
        let lo = Int(x)
        let t = x - CGFloat(lo)
        return side(lo) + (side(lo + 1) - side(lo)) * t * t * (3 - 2 * t)
    }
}

/// One horizontal mapping for slot placement, queries and zoom. A vertical division replaces the middle gap;
/// equally sized panes keep the grid centred on the physical division instead of the viewport centre.
package struct GridColumnGeometry: Equatable, Sendable {
    package let columns: Int
    package let side: CGFloat
    package let gap: CGFloat
    private let divisionEdges: ClosedRange<CGFloat>?
    private let fitsViewport: Bool
    private let width: CGFloat

    package var pitch: CGFloat { side + gap }
    package var fittingWidth: CGFloat { CGFloat(columns) * side + CGFloat(columns - 1) * gap }
    package var isDivided: Bool { divisionEdges != nil }

    package init(columns: Int, gap: CGFloat, width: CGFloat, division: CGRect?, targetSide: CGFloat? = nil) {
        self.columns = max(1, columns)
        self.gap = max(0, gap)
        self.width = width
        fitsViewport = targetSide == nil
        let ordinarySide = SquareTileGridEngine.nominalSlotSide(columns: columns, gap: gap, width: width)
        if let division,
            let fittingSide = GridVerticalDivision.fittingSide(division, width: width, columns: columns, gap: self.gap)
        {
            let dividedSide = targetSide ?? max(1, fittingSide.nextDown.nextDown)
            if dividedSide.isFinite, dividedSide >= 1 {
                side = dividedSide
                divisionEdges = GridVerticalDivision.edges(division, gap: self.gap)
                return
            }
        }
        side = ordinarySide
        divisionEdges = nil
    }

    package func origin(of column: Int) -> CGFloat {
        guard let divisionEdges else { return CGFloat(column) * pitch }
        let half = columns / 2
        if column >= half {
            let x = (divisionEdges.upperBound + CGFloat(column - half) * pitch).nextUp
            if fitsViewport, column < columns {
                var limit = width - side
                while limit + side > width { limit = limit.nextDown }
                return min(limit, x)
            }
            return x
        }
        // Round away from the band: adding the square's side must not put an edge inside the division.
        let x = (divisionEdges.lowerBound - side - CGFloat(half - 1 - column) * pitch).nextDown
        return fitsViewport && column >= 0 ? max(0, x) : x
    }

    /// Choose a column that lets its pane move only away from the division to the interpolated anchor origin.
    package func interpolatedAnchorColumn(at x: CGFloat) -> Int {
        guard let divisionEdges else { return column(at: x) }
        let half = columns / 2
        if x < divisionEdges.lowerBound {
            return (0..<half).first { origin(of: $0) >= x } ?? half - 1
        }
        return (half..<columns).last { origin(of: $0) <= x } ?? half
    }

    package func column(at x: CGFloat) -> Int {
        guard pitch > 0, pitch.isFinite, x.isFinite else { return 0 }
        guard isDivided else { return min(max(Int(x / pitch), 0), columns - 1) }
        return (0..<columns).min {
            abs(origin(of: $0) + side / 2 - x) < abs(origin(of: $1) + side / 2 - x)
        } ?? 0
    }
}
