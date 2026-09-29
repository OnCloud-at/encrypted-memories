import Foundation

/// The trash, restore and empty-trash mutations of this session, laid over every later listing. A listing that
/// started before a mutation, or that lags the server, cannot bring a photo back into a route that it left.
/// Every library host keeps one value of this type instead of its own sets.
public struct TimelineRemovalOverlay: Sendable, Equatable {
    /// Photos that left the library routes.
    public private(set) var hiddenFromLibrary: Set<PhotoUID> = []
    /// Photos that left the trash route, by a restore or by emptying the trash.
    public private(set) var hiddenFromTrash: Set<PhotoUID> = []

    public init() {}

    public mutating func trashed(_ uids: Set<PhotoUID>) {
        hiddenFromLibrary.formUnion(uids)
        hiddenFromTrash.subtract(uids)
    }

    public mutating func restored(_ uids: Set<PhotoUID>) {
        hiddenFromLibrary.subtract(uids)
        hiddenFromTrash.formUnion(uids)
    }

    public mutating func trashEmptied(_ uids: Set<PhotoUID>) {
        hiddenFromTrash.formUnion(uids)
    }

    /// The photos that a listing of `route` must not show.
    public func hidden(on route: PhotoFilter) -> Set<PhotoUID> {
        route == .trash ? hiddenFromTrash : hiddenFromLibrary
    }
}
