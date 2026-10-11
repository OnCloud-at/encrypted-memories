import Foundation
import PhotosCore

/// The one way both apps empty Recently Deleted. A duplicate merge that waits for its check can have left the last copy
/// of a group in the trash, so the trash is emptied only after every open merge is checked.
public enum RecentlyDeletedEmptying {
    /// Thrown when an open merge could not be checked. Nothing was deleted; a later attempt checks again.
    public struct PendingMergeCheck: Error, Equatable {}

    public static func empty(
        _ trash: any TrashProvider, checkingMergesWith duplicates: (any ExactDuplicateMerging)?
    ) async throws {
        guard await duplicates?.confirmNoPendingMerges() ?? true else { throw PendingMergeCheck() }
        try await trash.emptyTrash()
    }
}
