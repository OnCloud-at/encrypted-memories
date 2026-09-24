import PhotosCore

/// The collection that opened a viewer. Platform hosts supply only this context; the shared policy decides
/// which destructive mutation is truthful for the current item.
public enum ViewerCollectionContext: Equatable, Sendable {
    case library
    case trash
    /// An album another account shares. Its photos live on that account's volume, so the viewer never
    /// trashes or favorites them; it can only save copies to the account's own library.
    case sharedAlbum

    /// Maps every library route in one shared place. Albums, smart collections, Map and the main timeline
    /// all mutate like the library; Recently Deleted restores instead of trashing again.
    public init(filter: PhotoFilter) {
        switch filter {
        case .trash: self = .trash
        case .sharedAlbum: self = .sharedAlbum
        default: self = .library
        }
    }

    /// Favorites are a tag on the account's own photos. Shared photos cannot carry it.
    public var allowsFavorites: Bool { self != .sharedAlbum }
}

public enum ViewerMutationAction: Equatable, Sendable {
    case moveToTrash
    case restore
    /// Copies the shared photo into the account's own library. The shared original is unchanged.
    case saveToLibrary
}

public enum ViewerMutationPolicy {
    public static func action(for context: ViewerCollectionContext) -> ViewerMutationAction {
        switch context {
        case .library: .moveToTrash
        case .trash: .restore
        case .sharedAlbum: .saveToLibrary
        }
    }
}
