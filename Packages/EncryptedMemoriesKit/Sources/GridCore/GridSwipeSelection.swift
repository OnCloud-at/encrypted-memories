import CoreGraphics

/// Photos-style swipe selection over a flat grid order.
///
/// The photo under the first touch is the anchor. The anchor's membership before the gesture chooses the mode:
/// an unselected anchor adds the swept range, a selected anchor removes it. The swept range is always the
/// reading-order interval between the anchor and the photo under the finger, so whole rows fill in between.
/// Every photo outside the range keeps the membership it had before the gesture, so moving back shrinks the
/// range and restores the earlier state. Platform adapters only feed finger positions into this type.
package struct GridSwipeSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    package let anchorIndex: Int
    /// True when the gesture adds photos; false when it removes them.
    package let selects: Bool
    package private(set) var currentIndex: Int
    private let orderedIDs: [ID]
    private let baseSelection: Set<ID>

    /// Nil when `anchorIndex` is outside `orderedIDs`.
    package init?(anchorIndex: Int, orderedIDs: [ID], selected: Set<ID>) {
        guard orderedIDs.indices.contains(anchorIndex) else { return nil }
        self.anchorIndex = anchorIndex
        self.orderedIDs = orderedIDs
        baseSelection = selected
        selects = !selected.contains(orderedIDs[anchorIndex])
        currentIndex = anchorIndex
    }

    /// The selection for the current range: the base membership with the swept interval added or removed.
    package var selection: Set<ID> {
        let swept = orderedIDs[min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)]
        return selects ? baseSelection.union(swept) : baseSelection.subtracting(swept)
    }

    /// Moves the range end to `index`, clamped into the item order. Returns true when the end changed.
    @discardableResult
    package mutating func extend(to index: Int) -> Bool {
        let clamped = min(max(index, 0), orderedIDs.count - 1)
        guard clamped != currentIndex else { return false }
        currentIndex = clamped
        return true
    }

    /// The flat index under a content-space finger position, or nil when the finger rests in a gap or an empty
    /// slot and the range must keep its previous end. The horizontal position is clamped into the grid, so a
    /// finger beyond the leading or trailing edge still resolves to that row's edge column. A finger above or
    /// below all content resolves to the first or last photo.
    package static func index(
        at contentPoint: CGPoint,
        engine: SquareTileGridEngine,
        level: Int,
        width: CGFloat,
        columnPhase: Int?,
        itemCount: Int
    ) -> Int? {
        guard itemCount > 0, width > 0 else { return nil }
        let contentHeight = engine.contentSize(level: level, width: width, columnPhase: columnPhase).height
        if contentPoint.y < 0 { return 0 }
        if contentPoint.y >= contentHeight { return itemCount - 1 }
        let probe = CGPoint(x: min(max(contentPoint.x, 0), width - 1), y: contentPoint.y)
        guard
            let slot = engine.hitTest(contentPoint: probe, level: level, width: width, columnPhase: columnPhase),
            slot.index >= 0, slot.index < itemCount
        else { return nil }
        return slot.index
    }
}

/// Edge auto-scroll speed while a swipe selection is active.
///
/// The band sits inside the visible grid region (between the top and bottom bars). Speed is zero outside the
/// band and grows quadratically toward the edge, so a finger just inside the band scrolls slowly and a finger
/// on or beyond the edge scrolls at `maxSpeed`. Negative values scroll toward the top, positive toward the bottom.
package enum GridSwipeAutoScrollPolicy {
    package static let edgeBand: CGFloat = 80
    package static let maxSpeed: CGFloat = 1800

    /// Signed speed in points per second for a finger at `touchY`. `visibleMinY` and `visibleMaxY` bound the
    /// visible grid region in the same coordinate space. The band never exceeds one third of that region, so
    /// a short viewport keeps a middle zone without auto-scroll.
    package static func velocity(
        touchY: CGFloat,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat,
        edgeBand: CGFloat = edgeBand,
        maxSpeed: CGFloat = maxSpeed
    ) -> CGFloat {
        let height = visibleMaxY - visibleMinY
        guard height > 0, edgeBand > 0, maxSpeed > 0 else { return 0 }
        let band = min(edgeBand, height / 3)
        let topDepth = (visibleMinY + band - touchY) / band
        if topDepth > 0 { return -maxSpeed * ramp(topDepth) }
        let bottomDepth = (touchY - (visibleMaxY - band)) / band
        if bottomDepth > 0 { return maxSpeed * ramp(bottomDepth) }
        return 0
    }

    private static func ramp(_ depth: CGFloat) -> CGFloat {
        let clamped = min(depth, 1)
        return clamped * clamped
    }
}
