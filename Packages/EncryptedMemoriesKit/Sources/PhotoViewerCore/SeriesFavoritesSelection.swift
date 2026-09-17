import Foundation
import PhotosCore

/// Platform-neutral state of the "Select Favorites" mode for one series (burst).
///
/// The model owns the focused photo, the favorite marks and the choice that Confirm offers. Image loading,
/// paging and the backend operation stay in platform adapters and in `SeriesDissolutionOrchestrator`.
public struct SeriesFavoritesSelection: Equatable, Sendable {
    /// What Confirm does with the current marks.
    public enum Confirmation: Equatable, Sendable {
        /// No favorite is marked, or the series cannot change. Confirm only closes the mode.
        case close
        /// The user chooses between "Keep Everything" and "Keep Only N Favorites".
        case choose(favoriteCount: Int)
    }

    public let items: [PhotoItem]
    /// False for a series outside the account's own library, for example in a shared album. The mode then
    /// only browses the series: no marks and no dissolution.
    public let canKeepOnlyFavorites: Bool
    public private(set) var focusedIndex: Int
    public private(set) var favoriteUIDs: Set<PhotoUID> = []

    public init(items: [PhotoItem], focusedUID: PhotoUID?, canKeepOnlyFavorites: Bool) {
        self.items = items
        self.canKeepOnlyFavorites = canKeepOnlyFavorites
        focusedIndex = focusedUID.flatMap { uid in items.firstIndex { $0.uid == uid } } ?? 0
    }

    public var focusedItem: PhotoItem? {
        items.indices.contains(focusedIndex) ? items[focusedIndex] : nil
    }

    /// The marked photos in series order, which is the order the standalone copies are made in.
    public var orderedFavoriteUIDs: [PhotoUID] {
        items.map(\.uid).filter(favoriteUIDs.contains)
    }

    public var confirmation: Confirmation {
        canKeepOnlyFavorites && !favoriteUIDs.isEmpty ? .choose(favoriteCount: favoriteUIDs.count) : .close
    }

    public func isFavorite(_ uid: PhotoUID) -> Bool {
        favoriteUIDs.contains(uid)
    }

    /// Returns false when the index is outside the series or already focused.
    @discardableResult
    public mutating func focus(index: Int) -> Bool {
        guard items.indices.contains(index), index != focusedIndex else { return false }
        focusedIndex = index
        return true
    }

    public mutating func toggleFavorite(_ uid: PhotoUID) {
        guard canKeepOnlyFavorites, items.contains(where: { $0.uid == uid }) else { return }
        if favoriteUIDs.remove(uid) == nil { favoriteUIDs.insert(uid) }
    }
}
