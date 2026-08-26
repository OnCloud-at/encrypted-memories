import PhotosCore

/// The collection that opened a viewer. Platform hosts supply only this context; the shared policy decides
/// which destructive mutation is truthful for the current item.
public enum ViewerCollectionContext: Equatable, Sendable {
    case library
    case trash

    /// Maps every library route in one shared place. Albums, smart collections, Map and the main timeline
    /// all mutate like the library; only Recently Deleted restores instead of trashing again.
    public init(filter: PhotoFilter) {
        self = filter == .trash ? .trash : .library
    }
}

public enum ViewerMutationAction: Equatable, Sendable {
    case moveToTrash
    case restore
}

public enum ViewerMutationPolicy {
    public static func action(for context: ViewerCollectionContext) -> ViewerMutationAction {
        switch context {
        case .library: .moveToTrash
        case .trash: .restore
        }
    }
}
