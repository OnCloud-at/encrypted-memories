import CoreGraphics

/// Layout-invariant scroll position: the item at the top of the viewport plus how far its top sat below the
/// viewport top. Restoring re-resolves that item at the current zoom, width, and column phase, so route memory
/// survives layout changes without relying on a stale raw scroll offset.
public struct GridScrollAnchor<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let itemID: ItemID
    public let topOffset: CGFloat

    public init(itemID: ItemID, topOffset: CGFloat) {
        self.itemID = itemID
        self.topOffset = topOffset
    }
}

/// Chooses the photo that anchors a scroll position.
public enum GridScrollAnchorPolicy {
    /// The first visible slot whose top edge lies in the visible content area, between `visibleTop` (below a
    /// translucent top bar) and `visibleBottom` (above a bottom bar). A photo that the top bar mostly covers makes a
    /// poor anchor: after the grid narrows, its smaller tile keeps the same top offset and ends above the viewport.
    /// When no photo starts in the area (tiles taller than the area), the topmost photo that reaches into it anchors,
    /// then the topmost visible photo. All positions are content coordinates; ties keep the first slot in order.
    public static func anchor<Slot>(
        among slots: [Slot], visibleTop: CGFloat, visibleBottom: CGFloat, frame: (Slot) -> CGRect
    ) -> Slot? {
        func topmost(_ candidates: [Slot]) -> Slot? { candidates.min(by: { frame($0).minY < frame($1).minY }) }
        let startsInView = slots.filter { frame($0).minY >= visibleTop - 0.5 && frame($0).minY < visibleBottom }
        let reachesIntoView = slots.filter { frame($0).maxY > visibleTop && frame($0).minY < visibleBottom }
        return topmost(startsInView) ?? topmost(reachesIntoView) ?? topmost(slots)
    }
}
