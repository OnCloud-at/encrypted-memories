import CoreGraphics

// MARK: - Viewport resize camera rebase
//
// A resize keeps the level, phase, content mode, nominal columns, and gap. Only the slot side and derived content
// height change with the new width. The rebase preserves content at a normalized viewport fraction and then clamps
// the result. It does not use zoom or selection state and never resets the committed phase.

/// Which edges of the grid viewport moved, from the old/new viewport frames (y-up screen space: maxY=top, minY=bottom).
public struct GridViewportResizeDelta: Sendable {
    public let widthChanged: Bool
    public let heightChanged: Bool
    public let movedTopEdge: Bool
    public let movedBottomEdge: Bool
    public let movedLeftEdge: Bool
    public let movedRightEdge: Bool

    public init(old: CGRect, new: CGRect, tolerance: CGFloat = 0.5) {
        widthChanged = abs(old.width - new.width) > tolerance
        heightChanged = abs(old.height - new.height) > tolerance
        movedTopEdge = abs(old.maxY - new.maxY) > tolerance
        movedBottomEdge = abs(old.minY - new.minY) > tolerance
        movedLeftEdge = abs(old.minX - new.minX) > tolerance
        movedRightEdge = abs(old.maxX - new.maxX) > tolerance
    }
}

public struct GridViewportResizeInput: Sendable {
    public let oldViewportFrame: CGRect  // y-up screen space (maxY=top, minY=bottom)
    public let newViewportFrame: CGRect
    public let oldScrollY: CGFloat
    public let level: Int
    public let committedPhase: Int?
    public let itemCount: Int
    public let wasBottomPinned: Bool
    public let anchorFractionY: CGFloat  // normalized viewport anchor; 0.5 = centre (Apple-like default)

    public init(
        oldViewportFrame: CGRect, newViewportFrame: CGRect, oldScrollY: CGFloat, level: Int,
        committedPhase: Int?, itemCount: Int, wasBottomPinned: Bool, anchorFractionY: CGFloat = 0.5
    ) {
        self.oldViewportFrame = oldViewportFrame
        self.newViewportFrame = newViewportFrame
        self.oldScrollY = oldScrollY
        self.level = level
        self.committedPhase = committedPhase
        self.itemCount = itemCount
        self.wasBottomPinned = wasBottomPinned
        self.anchorFractionY = anchorFractionY
    }
}

public struct GridViewportResizeResult: Sendable {
    public let newScrollY: CGFloat
    public let anchorGlobalIndex: Int?
    public let anchorFractionY: CGFloat
    public let bottomPinned: Bool
    public let clamped: Bool
    public let newContentSize: CGSize
    public let anchorLocalFractionY: CGFloat?

    public init(
        newScrollY: CGFloat, anchorGlobalIndex: Int?, anchorFractionY: CGFloat, bottomPinned: Bool,
        clamped: Bool, newContentSize: CGSize, anchorLocalFractionY: CGFloat?
    ) {
        self.newScrollY = newScrollY
        self.anchorGlobalIndex = anchorGlobalIndex
        self.anchorFractionY = anchorFractionY
        self.bottomPinned = bottomPinned
        self.clamped = clamped
        self.newContentSize = newContentSize
        self.anchorLocalFractionY = anchorLocalFractionY
    }
}

public extension SquareTileGridEngine {
    /// Rebase the scroll offset for a viewport-size change, preserving the content at the normalized viewport
    /// anchor (`anchorFractionY`). Pure: preserve level, phase, columns, and gap while recomputing slot side,
    /// pitch, and content height from the new width. Resolve the anchor under both metric sets, place it at the
    /// new normalized viewport position, then clamp the result.
    func rebasedScrollOffsetForViewportChange(_ input: GridViewportResizeInput) -> GridViewportResizeResult {
        let level = clampLevel(input.level)
        let phase = input.committedPhase
        let f = min(max(input.anchorFractionY, 0), 1)
        let oldW = max(input.oldViewportFrame.width, 1)
        let oldVH = max(input.oldViewportFrame.height, 0)
        let newW = max(input.newViewportFrame.width, 1)
        let newVH = max(input.newViewportFrame.height, 0)
        let newContent = contentSize(level: level, width: newW, columnPhase: phase)
        let maxY = max(0, newContent.height - newVH)

        func make(_ rawY: CGFloat, anchor: Int?, frac: CGFloat?, pinned: Bool) -> GridViewportResizeResult {
            let cy = min(max(0, rawY), maxY)
            return GridViewportResizeResult(
                newScrollY: cy, anchorGlobalIndex: anchor, anchorFractionY: f,
                bottomPinned: pinned, clamped: abs(cy - rawY) > 0.5,
                newContentSize: newContent, anchorLocalFractionY: frac)
        }

        // Bottom-pinned (newest end) wins - keep it pinned to the new bottom.
        if input.wasBottomPinned { return make(maxY, anchor: nil, frac: nil, pinned: true) }

        // Capture the item at the old normalized viewport content point, preserve its in-slot point under the
        // new metrics, and place it at the same normalized viewport fraction.
        let oldAnchorContentY = input.oldScrollY + oldVH * f
        guard input.itemCount > 0,
            let a = anchorItem(
                nearContentPoint: CGPoint(x: oldW / 2, y: oldAnchorContentY),
                level: level, width: oldW, columnPhase: phase),
            let newSlot = slotRect(flatIndex: a.flatIndex, level: level, width: newW, columnPhase: phase)
        else {
            // Preserve the old position when the anchor cannot be resolved.
            return make(input.oldScrollY, anchor: nil, frac: nil, pinned: false)
        }
        let localY = a.localFraction.y
        let newAnchorContentY = newSlot.minY + localY * newSlot.height
        return make(newAnchorContentY - newVH * f, anchor: a.flatIndex, frac: localY, pinned: false)
    }
}
