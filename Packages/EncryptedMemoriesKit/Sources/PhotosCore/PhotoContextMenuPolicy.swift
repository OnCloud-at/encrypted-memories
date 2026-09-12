import Foundation

/// Existing photo operations offered by a grid context menu, independent of its native renderer.
public enum PhotoContextMenuAction: String, CaseIterable, Sendable {
    case copy, share, favorite, unfavorite, addToAlbum, information, removeFromAlbum, trash, restore

    public var title: String {
        let key: String =
            switch self {
            case .copy: "contextmenu.copy"
            case .share: "contextmenu.share"
            case .favorite: "contextmenu.favorite"
            case .unfavorite: "contextmenu.unfavorite"
            case .addToAlbum: "albums.add_selection_title"
            case .information: "contextmenu.information"
            case .removeFromAlbum: "albums.remove_photos_action"
            case .trash: "contextmenu.trash"
            case .restore: "contextmenu.restore"
            }
        return L10n.string(dynamicKey: key)
    }

    public var systemImage: String {
        switch self {
        case .copy: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .favorite: "heart"
        case .unfavorite: "heart.slash"
        case .addToAlbum: "rectangle.stack.badge.plus"
        case .information: "info.circle"
        case .removeFromAlbum: "rectangle.stack.badge.minus"
        case .trash: "trash"
        case .restore: "arrow.uturn.backward"
        }
    }

    public var group: Int {
        switch self {
        case .copy: 0
        case .share, .favorite, .unfavorite: 1
        case .addToAlbum, .information, .removeFromAlbum: 2
        case .trash, .restore: 3
        }
    }
}

public enum PhotoContextMenuPolicy {
    public static func actions(
        itemCount: Int, isTrash: Bool, canMutate: Bool, canFavorite: Bool,
        allFavorited: Bool, canAddToAlbum: Bool, canRemoveFromAlbum: Bool
    ) -> [PhotoContextMenuAction] {
        guard itemCount > 0 else { return [] }
        var actions: [PhotoContextMenuAction] = [.copy, .share]
        if !isTrash, canMutate {
            if canFavorite { actions.append(allFavorited ? .unfavorite : .favorite) }
            if canAddToAlbum { actions.append(.addToAlbum) }
            if canRemoveFromAlbum { actions.append(.removeFromAlbum) }
        }
        if itemCount == 1 { actions.append(.information) }
        if canMutate { actions.append(isTrash ? .restore : .trash) }
        return actions
    }
}
