import CoreGraphics

/// An area of a view that the device reserves (Apple's reserved regions): the folding region of iPhone Duo while it
/// is partly open (a division), or hardware such as a camera that covers content (an occlusion). A platform adapter
/// converts the system's regions into this form, in the coordinates of the view that lays out the grid.
public struct ReservedRegionArea: Equatable, Sendable {
    /// The region including the margins that interactive content keeps from it.
    public var frame: CGRect
    /// A division is active only while the device is partly open.
    public var isActive: Bool

    public init(frame: CGRect, isActive: Bool) {
        self.frame = frame
        self.isActive = isActive
    }
}

/// Keeps the selection mark of a grid tile clear of the active reserved regions. Photos may scroll through a region;
/// the mark moves out of it (HIG: move only what's necessary to keep elements visible and easy to tap).
public struct ReservedRegionLayout: Equatable, Sendable {
    public static let none = ReservedRegionLayout(areas: [], bounds: .null)

    /// The frames of the active regions, including their interactive margins.
    public let exclusions: [CGRect]
    /// The visible part of the view, without the bars; a mark that moves must stay inside it.
    public let bounds: CGRect

    public init(areas: [ReservedRegionArea], bounds: CGRect) {
        exclusions = areas.filter { $0.isActive && !$0.frame.isEmpty }.map(\.frame)
        self.bounds = bounds
    }

    public var isEmpty: Bool { exclusions.isEmpty }

    /// Whether `rect` stays clear of every active region.
    public func isClear(_ rect: CGRect) -> Bool {
        !exclusions.contains { $0.intersects(rect) }
    }

    /// The frame of a tile's selection mark: bottom-trailing unless an active region covers it. A covered mark moves to
    /// the nearest free position inside the visible part of the tile: clear of every region, completely inside `bounds`,
    /// and covering none of the tile's labels in `occupied`. Candidate positions lie on a grid of half a mark, starting
    /// at the bottom-trailing corner and always including the leading and top edges, so equally near positions keep the
    /// bottom row and the trailing side first. When only a label leaves room, the mark covers the label: selection comes
    /// first. Without any free position the mark stays bottom-trailing.
    public func selectionMarkRect(
        in tile: CGRect, side: CGFloat, inset: CGFloat, avoiding occupied: [CGRect] = []
    ) -> CGRect {
        let home = Self.homeMarkRect(in: tile, side: side, inset: inset)
        guard !isClear(home) else { return home }
        let visible = tile.intersection(bounds)
        guard !visible.isNull, side > 0 else { return home }
        return nearestFreeRect(in: visible, side: side, inset: inset, home: home, avoiding: occupied)
            ?? nearestFreeRect(in: visible, side: side, inset: inset, home: home, avoiding: [])
            ?? home
    }

    private func nearestFreeRect(
        in visible: CGRect, side: CGFloat, inset: CGFloat, home: CGRect, avoiding occupied: [CGRect]
    ) -> CGRect? {
        var nearest: CGRect?
        var nearestDistance = CGFloat.infinity
        for y in Self.positions(from: visible.maxY - side - inset, to: visible.minY + inset, step: side / 2) {
            for x in Self.positions(from: visible.maxX - side - inset, to: visible.minX + inset, step: side / 2) {
                let rect = CGRect(x: x, y: y, width: side, height: side)
                let distance = distance(rect, home)
                if distance < nearestDistance - 0.5, isClear(rect), bounds.contains(rect),
                    !occupied.contains(where: { $0.intersects(rect) })
                {
                    nearest = rect
                    nearestDistance = distance
                }
            }
        }
        return nearest
    }

    /// The mark of `side` points in the bottom-trailing corner of a tile, `inset` points from both edges.
    public static func homeMarkRect(in tile: CGRect, side: CGFloat, inset: CGFloat) -> CGRect {
        CGRect(x: tile.maxX - side - inset, y: tile.maxY - side - inset, width: side, height: side)
    }

    /// Positions from `start` down to `end` in steps of `step`, ending exactly on `end` when the steps miss it. A start
    /// below `end` (a tile too small for the mark) gives none; the tolerance absorbs rounding.
    private static func positions(from start: CGFloat, to end: CGFloat, step: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var position = start
        while position >= end - 0.5 {
            result.append(position)
            position -= step
        }
        if let last = result.last, last > end + 0.5 { result.append(end) }
        return result
    }

    private func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }
}
