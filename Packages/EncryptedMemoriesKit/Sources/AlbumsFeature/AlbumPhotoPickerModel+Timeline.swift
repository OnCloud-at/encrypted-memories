import Foundation
import PhotosCore
import TimelineCore

/// The picker reads the whole library from the host's shared timeline model, the same way on macOS, iOS and iPadOS.
extension AlbumPhotoPickerModel {
    /// Everything that the picker reads from a timeline model and its album. The host updates the picker whenever
    /// this value changes.
    public struct TimelineInputs: Hashable, Sendable {
        let wholeLibraryRevision: UInt64
        let authorityRevision: UInt64
        let pendingRevision: UInt64
        let failure: String?
        let albumRevision: UInt64
        let albumLoaded: Bool
    }

    /// - Parameters:
    ///   - albumRevision: Changes whenever the album's own grid changes.
    ///   - albumLoaded: Whether the album's own grid has loaded.
    public func inputs(from timeline: TimelineViewModel, albumRevision: UInt64, albumLoaded: Bool) -> TimelineInputs {
        TimelineInputs(
            wholeLibraryRevision: timeline.wholeLibraryContentRevision,
            authorityRevision: timeline.wholeLibraryInventoryAuthorityRevision,
            pendingRevision: timeline.pendingPresentation.revision, failure: libraryLoadFailure,
            albumRevision: albumRevision, albumLoaded: albumLoaded)
    }

    /// Loads the whole library once when the timeline model does not know it yet. The album grid under the sheet
    /// keeps its route. A failure stays until the next load, which Retry starts.
    public func loadLibrary(from timeline: TimelineViewModel) async {
        libraryLoadFailure = nil
        libraryLoadFailure = await timeline.loadWholeLibraryIfNeeded()
    }

    /// Applies what All Photos shows, photos that are still backing up included, and the album's own photos.
    /// `albumNodeIDs` is nil while the album itself still loads.
    public func update(from timeline: TimelineViewModel, albumNodeIDs: Set<String>?) async {
        await update(
            library: .loaded(
                timeline.wholeLibraryGridItems, authority: timeline.wholeLibraryInventoryAuthority,
                failure: libraryLoadFailure.map { .init(message: $0, retryable: true) }),
            albumNodeIDs: albumNodeIDs)
    }
}
