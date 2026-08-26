/// Scroll-direction-biased prefetch range - the shared calculation behind "warm the next viewport in the
/// direction the user is travelling" on the settled grid.
///
/// The streamed slot window (viewport + overscan) covers `coveredIndexRange`; this policy answers which
/// flat indices just beyond that window should be pre-decoded from disk to RAM (at `.nearViewportScrollAhead`
/// priority) so that resuming the scroll lands on RAM-ready tiles instead of misses. Pure and platform-free:
/// hosts supply the covered range, the column count, and the travel direction; no cache budget changes.
package enum GridScrollAheadPolicy {
    package enum Direction: Equatable {
        /// Content offset increasing (scrolling toward later rows / higher flat indices).
        case towardHigherIndices
        /// Content offset decreasing (scrolling back toward earlier rows / lower flat indices).
        case towardLowerIndices
    }

    /// The flat index range to pre-warm beyond the covered window, `rowsAhead` full rows in the travel
    /// direction, clamped to the library bounds. Empty when there is nothing beyond the window.
    package static func aheadRange(
        coveredIndexRange: ClosedRange<Int>,
        itemCount: Int,
        columns: Int,
        rowsAhead: Int,
        direction: Direction
    ) -> Range<Int> {
        guard itemCount > 0, columns > 0, rowsAhead > 0 else { return 0..<0 }
        let count = columns * rowsAhead
        switch direction {
        case .towardHigherIndices:
            let start = min(itemCount, max(0, coveredIndexRange.upperBound + 1))
            let end = min(itemCount, start + count)
            return start..<end
        case .towardLowerIndices:
            let end = max(0, min(itemCount, coveredIndexRange.lowerBound))
            let start = max(0, end - count)
            return start..<end
        }
    }

    /// Chooses a bounded decode corridor from the actual scroll velocity. One viewport is the minimum useful
    /// look-ahead (the rejected fixed three-row policy was smaller than many macOS viewports); three viewports is
    /// the hard ceiling so a trackpad fling cannot turn interactive prefetch into an unbounded library crawl.
    package static func corridorRows(
        viewportRows: Int,
        rowsPerSecond: Double,
        lookAheadSeconds: Double = 0.45,
        maximumViewportCount: Int = 3
    ) -> Int {
        guard viewportRows > 0 else { return 0 }
        let base = max(1, viewportRows)
        let ceiling = max(base, base * max(1, maximumViewportCount))
        let finiteVelocity = rowsPerSecond.isFinite ? max(0, rowsPerSecond) : 0
        let finiteLookAhead = lookAheadSeconds.isFinite ? max(0, lookAheadSeconds) : 0
        let projected = Int((finiteVelocity * finiteLookAhead).rounded(.up))
        return min(ceiling, max(base, projected))
    }
}
