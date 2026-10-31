import CoreGraphics

/// An area of a view that the device reserves (Apple's reserved regions): the folding region of iPhone Duo while it
/// is partially open (a division), or hardware such as a camera that covers content (an occlusion). A platform
/// adapter converts the system's regions into this form, in the coordinates of the view that lays out content.
public struct ReservedRegionArea: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case division
        case occlusion
    }

    public var kind: Kind
    /// The region including the margins that interactive content keeps from it.
    public var frame: CGRect
    /// A division is active only while the device is partially open; the outer camera is always active.
    public var isActive: Bool

    public init(kind: Kind, frame: CGRect, isActive: Bool) {
        self.kind = kind
        self.frame = frame
        self.isActive = isActive
    }
}

/// Keeps interactive content clear of the active reserved regions of a view. Photos may scroll through a region;
/// controls and badges move out of it (HIG: keep important elements clear of the center of the fold).
public struct ReservedRegionLayout: Equatable, Sendable {
    public static let none = ReservedRegionLayout(areas: [], bounds: .null)

    /// The frames of the active regions, including their interactive margins.
    public let exclusions: [CGRect]
    /// The visible bounds of the view; content that moves out of a region must stay inside them.
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

    /// The corner of a tile that holds a badge: bottom-trailing unless an active region covers it. The badge then
    /// moves to the first corner, in the order top-trailing, bottom-leading, top-leading, that is clear of every
    /// region, lies completely inside `bounds`, and covers none of the tile's labels in `occupied`. Without such a
    /// corner the badge stays bottom-trailing, where people expect it.
    public func badgeCorner(
        in tile: CGRect, side: CGFloat, inset: CGFloat, avoiding occupied: [CGRect] = []
    ) -> TileCorner {
        let home = TileCorner.bottomTrailing
        guard !isClear(home.badgeRect(in: tile, side: side, inset: inset)) else { return home }
        return TileCorner.badgeOrder.dropFirst().first { corner in
            let rect = corner.badgeRect(in: tile, side: side, inset: inset)
            return isClear(rect) && bounds.contains(rect) && !occupied.contains { $0.intersects(rect) }
        } ?? home
    }
}

/// A corner of a grid tile, in the tile's own coordinates (y grows downward).
public enum TileCorner: Equatable, Sendable {
    case bottomTrailing
    case topTrailing
    case bottomLeading
    case topLeading

    static let badgeOrder: [TileCorner] = [.bottomTrailing, .topTrailing, .bottomLeading, .topLeading]

    /// The square badge of `side` points in this corner, `inset` points from both edges.
    public func badgeRect(in tile: CGRect, side: CGFloat, inset: CGFloat) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch self {
        case .bottomTrailing, .topTrailing: x = tile.maxX - inset - side
        case .bottomLeading, .topLeading: x = tile.minX + inset
        }
        switch self {
        case .bottomTrailing, .bottomLeading: y = tile.maxY - inset - side
        case .topTrailing, .topLeading: y = tile.minY + inset
        }
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
