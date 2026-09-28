import Foundation
import PhotosCore

/// How a new timeline differs from the one shown before.
///
/// Hosts on iOS, iPadOS and macOS compute it off the main actor together with the new projection, so a library
/// refresh without changes makes no pass over every photo on the main actor.
public struct TimelineProjectionChange: Sendable, Equatable {
    /// An item, its metadata, or the order differs.
    public let contentChanged: Bool
    /// The identity order differs, so grids need a new frame.
    public let identitiesChanged: Bool
    /// Identities of the new timeline, in timeline order.
    public let uids: [PhotoUID]
    /// Identities that the previous timeline did not contain, in timeline order.
    public let addedUIDs: [PhotoUID]

    public init(from previous: TimelineSnapshot, to next: TimelineSnapshot, nextUIDs: [PhotoUID]) {
        contentChanged = previous != next
        // Equal content has equal identities, so only a content change needs the identity passes.
        identitiesChanged = contentChanged && !previous.items.lazy.map(\.uid).elementsEqual(nextUIDs)
        uids = nextUIDs
        addedUIDs =
            identitiesChanged
            ? LibraryInventoryDelta.addedUIDs(previous: previous.items.map(\.uid), current: nextUIDs)
            : []
    }

    public init(from previous: TimelineSnapshot, to projection: TimelineContentProjection) {
        self.init(from: previous, to: projection.snapshot, nextUIDs: projection.uids)
    }
}
