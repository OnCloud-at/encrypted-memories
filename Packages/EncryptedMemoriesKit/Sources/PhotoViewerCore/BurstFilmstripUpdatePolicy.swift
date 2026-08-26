import PhotosCore

/// Pure update policy for native burst filmstrips. Identity changes reload cells; selection changes only move
/// the native selection; geometry changes only invalidate layout.
public struct BurstFilmstripUpdate: Equatable, Sendable {
    public let reloadData: Bool
    public let updateLayout: Bool
    public let selectCurrent: Bool

    public init(reloadData: Bool, updateLayout: Bool, selectCurrent: Bool) {
        self.reloadData = reloadData
        self.updateLayout = updateLayout
        self.selectCurrent = selectCurrent
    }
}

public enum BurstFilmstripUpdatePolicy {
    public static func resolve(
        previousItems: [PhotoUID],
        currentItems: [PhotoUID],
        previousSelectedUID: PhotoUID?,
        currentSelectedUID: PhotoUID?,
        previousItemSide: Double?,
        currentItemSide: Double,
        previousShowsScroller: Bool?,
        currentShowsScroller: Bool
    ) -> BurstFilmstripUpdate {
        let reloadData = previousItems != currentItems
        let selectionChanged = previousSelectedUID != currentSelectedUID
        let sideChanged = previousItemSide.map { abs($0 - currentItemSide) > 0.01 } ?? true
        let scrollerChanged = previousShowsScroller.map { $0 != currentShowsScroller } ?? true
        return BurstFilmstripUpdate(
            reloadData: reloadData,
            updateLayout: reloadData || sideChanged || scrollerChanged,
            selectCurrent: reloadData || selectionChanged
        )
    }
}
