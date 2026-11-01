import CoreGraphics

/// One horizontal mapping for slot placement, queries and zoom. A vertical division replaces the middle gap;
/// equally sized panes keep the grid centred on the physical division instead of the viewport centre.
package struct GridColumnGeometry: Equatable, Sendable {
    package let columns: Int
    package let side: CGFloat
    package let gap: CGFloat
    private let divisionEdges: ClosedRange<CGFloat>?
    private let fitsViewport: Bool

    package var pitch: CGFloat { side + gap }
    package var fittingWidth: CGFloat { CGFloat(columns) * side + CGFloat(columns - 1) * gap }
    package var isDivided: Bool { divisionEdges != nil }

    package init(columns: Int, gap: CGFloat, width: CGFloat, division: CGRect?, targetSide: CGFloat? = nil) {
        self.columns = max(1, columns)
        self.gap = max(0, gap)
        fitsViewport = targetSide == nil
        let ordinarySide = SquareTileGridEngine.nominalSlotSide(columns: columns, gap: gap, width: width)
        if let division, columns >= 2, columns.isMultiple(of: 2),
            division.minX.isFinite, division.width.isFinite, division.width >= 0,
            division.height > division.width
        {
            let middleGap = max(self.gap, division.width)
            let leftEdge = division.midX - middleGap / 2
            let rightEdge = division.midX + middleGap / 2
            let paneWidth = min(leftEdge, width - rightEdge)
            let half = CGFloat(columns / 2)
            let dividedSide = targetSide ?? (paneWidth - self.gap * (half - 1)) / half
            if dividedSide >= 1 {
                side = dividedSide
                divisionEdges = leftEdge...rightEdge
                return
            }
        }
        side = ordinarySide
        divisionEdges = nil
    }

    package func origin(of column: Int) -> CGFloat {
        guard let divisionEdges else { return CGFloat(column) * pitch }
        let half = columns / 2
        if column >= half { return divisionEdges.upperBound + CGFloat(column - half) * pitch }
        // Round away from the band: adding the square's side must not put an edge inside the division.
        let x = (divisionEdges.lowerBound - side - CGFloat(half - 1 - column) * pitch).nextDown
        return fitsViewport && column >= 0 ? max(0, x) : x
    }

    package func column(at x: CGFloat) -> Int {
        guard pitch > 0, pitch.isFinite, x.isFinite else { return 0 }
        guard isDivided else { return min(max(Int(x / pitch), 0), columns - 1) }
        return (0..<columns).min {
            abs(origin(of: $0) + side / 2 - x) < abs(origin(of: $1) + side / 2 - x)
        } ?? 0
    }
}
