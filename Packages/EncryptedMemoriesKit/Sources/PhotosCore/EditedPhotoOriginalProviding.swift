import Foundation

/// Optional backend capability: the hidden original of a photo or video that was edited in Photos. The photo library
/// backup uploads the original as a related file of the edited photo.
public protocol EditedPhotoOriginalProviding: Sendable {
    /// The original as a viewer item, or nil when the photo has no proven original. The viewer asks only for plain
    /// photos and videos (`EditedPhotoOriginalLookup.qualifies`); a backend answers nil for any other item.
    func editedOriginal(of item: PhotoItem) async throws -> PhotoItem?
}
