/// Selects the inclusive index range between the anchor and current item.
///
/// The anchor's membership chooses add or remove; items outside the range retain their base membership.
package enum GridDragRangeSelection {
    /// The selection after a drag from `anchorIndex` to `currentIndex` over `orderedIDs`. Out-of-range indices
    /// are clamped into `[0, count-1]`; an empty order returns `base` unchanged.
    package static func selection<ID: Hashable>(
        base: Set<ID>,
        orderedIDs: [ID],
        anchorIndex: Int,
        currentIndex: Int,
        selecting: Bool
    ) -> Set<ID> {
        guard !orderedIDs.isEmpty else { return base }
        let last = orderedIDs.count - 1
        let a = min(max(anchorIndex, 0), last)
        let c = min(max(currentIndex, 0), last)
        let lo = min(a, c)
        let hi = max(a, c)
        let swept = orderedIDs[lo...hi]
        var result = base
        if selecting {
            result.formUnion(swept)
        } else {
            result.subtract(swept)
        }
        return result
    }
}
