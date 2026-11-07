import Foundation
import PhotosCore

/// Platform-neutral selection state for Proton burst / series photos.
///
/// The model owns only item identity, selection, navigation, and loading flags. Backend loading and native
/// filmstrip presentation stay in platform feature adapters.
public struct BurstSelectionModel: Equatable, Sendable {
    public private(set) var items: [PhotoItem]
    public private(set) var selectedIndex: Int?
    public private(set) var isLoading: Bool
    public private(set) var loadFailed: Bool

    public init(
        items: [PhotoItem] = [],
        selectedIndex: Int? = nil,
        isLoading: Bool = false,
        loadFailed: Bool = false
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.isLoading = isLoading
        self.loadFailed = loadFailed
    }

    public var hasFilmstrip: Bool { items.count > 1 }
    public var canMoveNext: Bool {
        hasFilmstrip && selectedIndex.map { $0 < items.count - 1 } == true
    }
    public var canMovePrevious: Bool {
        hasFilmstrip && selectedIndex.map { $0 > 0 } == true
    }

    public func current(fallback: PhotoItem) -> PhotoItem {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return fallback }
        return items[selectedIndex]
    }

    /// Decides what a viewer export or share of the shown page carries. Every platform viewer asks
    /// this one rule, so a burst leaves the viewer only when all its photos are known.
    ///
    /// - Parameters:
    ///   - current: the photo the page shows (a filmstrip member or the original of an edit).
    ///   - page: the page's own photo, which owns the burst read.
    ///   - belongsToPage: false while this model still holds another page's state, for example
    ///     right after a swipe and before the new page's read has started.
    /// - Returns: `.burstLoading` while the burst of the page is not known yet,
    ///   `.burstReadFailed` with the page photo after its read failed (an export can read the
    ///   whole group again from it), otherwise `.success` with the loaded series or the photo.
    public func viewerExportDecision(
        current: PhotoItem,
        page: PhotoItem,
        belongsToPage: Bool
    ) -> BurstExportExpansion.Result {
        guard belongsToPage else {
            return page.isBurstCandidate ? .burstLoading : .success(items: [current], expandedSingleSeries: false)
        }
        if isLoading { return .burstLoading }
        // A filmstrip whose group read failed is partial knowledge: its items would silently
        // carry only part of the series.
        if loadFailed { return .burstReadFailed(failedSources: [page]) }
        if hasFilmstrip { return .success(items: items, expandedSingleSeries: true) }
        return .success(items: [current], expandedSingleSeries: false)
    }

    public func gridReturnCandidates(current: PhotoItem, base: PhotoItem) -> [PhotoItem] {
        current.uid == base.uid ? [base] : [current, base]
    }

    public mutating func reset() {
        items = []
        selectedIndex = nil
        isLoading = false
        loadFailed = false
    }

    public mutating func seedKnownGroup(for item: PhotoItem, knownItems: [PhotoItem]) {
        let memberUIDs = item.burstMemberUIDs
        guard memberUIDs.count > 1 else { return }
        var itemByUID: [PhotoUID: PhotoItem] = [:]
        itemByUID.reserveCapacity(knownItems.count)
        for candidate in knownItems where itemByUID[candidate.uid] == nil {
            itemByUID[candidate.uid] = candidate
        }
        let known = memberUIDs.compactMap { itemByUID[$0] }
        guard known.count > 1 else { return }
        items = known
        selectedIndex = known.firstIndex(where: { $0.uid == item.uid }) ?? 0
        isLoading = false
        loadFailed = false
    }

    @discardableResult
    public mutating func beginLoadingIfCandidate(_ item: PhotoItem) -> Bool {
        // Timeline enrichment can seed only the members that are present in the active route. Skip the backend
        // lookup only when that seed covers every member declared by the item; a partial filmstrip must still be
        // completed by the provider.
        let knownUIDs = Set(items.map(\.uid))
        let hasCompleteKnownGroup =
            item.burstMemberUIDs.count > 1
            && item.burstMemberUIDs.allSatisfy(knownUIDs.contains)
        guard item.isBurstCandidate, !hasCompleteKnownGroup else { return false }
        isLoading = true
        loadFailed = false
        return true
    }

    public mutating func applyLoadedGroup(_ group: [PhotoItem], containing item: PhotoItem) {
        isLoading = false
        loadFailed = false
        guard group.count > 1 else {
            if hasFilmstrip { return }
            items = []
            selectedIndex = nil
            return
        }
        items = group
        selectedIndex = group.firstIndex(where: { $0.uid == item.uid }) ?? 0
    }

    public mutating func failLoading() {
        isLoading = false
        loadFailed = true
        if !hasFilmstrip {
            items = []
            selectedIndex = nil
        }
    }

    public mutating func selectIndex(_ newIndex: Int) -> PhotoItem? {
        guard items.indices.contains(newIndex), selectedIndex != newIndex else { return nil }
        selectedIndex = newIndex
        return items[newIndex]
    }

    public mutating func selectNext() -> PhotoItem? {
        guard canMoveNext, let selectedIndex else { return nil }
        return selectIndex(selectedIndex + 1)
    }

    public mutating func selectPrevious() -> PhotoItem? {
        guard canMovePrevious, let selectedIndex else { return nil }
        return selectIndex(selectedIndex - 1)
    }
}
