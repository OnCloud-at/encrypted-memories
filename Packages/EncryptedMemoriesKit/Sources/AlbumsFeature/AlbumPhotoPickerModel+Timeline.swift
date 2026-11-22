import Foundation
import PhotosCore
import TimelineCore

/// Where the picker reads the whole library from: what All Photos shows, how far it is known, and a load when it is not
/// known yet. The shared timeline model of macOS, iOS and iPadOS is the production source.
@MainActor
public protocol AlbumPhotoPickerLibrarySource: AnyObject {
    /// What All Photos shows, photos that are still backing up included.
    var wholeLibraryGridItems: [PhotoItem] { get }
    var wholeLibraryInventoryAuthority: SourceInventoryAuthority { get }
    var wholeLibraryContentRevision: UInt64 { get }
    var wholeLibraryInventoryAuthorityRevision: UInt64 { get }
    /// Moves when photos that are still backing up join or leave the library, not with their upload progress.
    var pendingMembershipRevision: UInt64 { get }
    /// Returns nil once the whole library is known, or the failure message.
    func loadWholeLibraryIfNeeded() async -> String?
}

extension TimelineViewModel: AlbumPhotoPickerLibrarySource {}

extension AlbumPhotoPickerModel {
    /// Everything that the picker reads from its library source and its album. The sheet updates the picker whenever
    /// this value changes.
    struct LibraryInputs: Hashable, Sendable {
        let wholeLibraryRevision: UInt64
        let authorityRevision: UInt64
        let pendingRevision: UInt64
        let failure: String?
        let albumRevision: UInt64
        let albumLoaded: Bool
    }

    func inputs(
        from library: any AlbumPhotoPickerLibrarySource, albumRevision: UInt64, albumLoaded: Bool
    ) -> LibraryInputs {
        LibraryInputs(
            wholeLibraryRevision: library.wholeLibraryContentRevision,
            authorityRevision: library.wholeLibraryInventoryAuthorityRevision,
            pendingRevision: library.pendingMembershipRevision, failure: libraryLoadFailure,
            albumRevision: albumRevision, albumLoaded: albumLoaded)
    }

    /// Loads the whole library once when the source does not know it yet. A failure stays until the next load, which
    /// Retry starts.
    func loadLibrary(from library: any AlbumPhotoPickerLibrarySource) async {
        libraryLoadFailure = nil
        libraryLoadFailure = await library.loadWholeLibraryIfNeeded()
    }

    /// Applies what the source shows and the album's own photos. `albumItems` is nil while the album itself still
    /// loads.
    func update(from library: any AlbumPhotoPickerLibrarySource, albumItems: [PhotoItem]?) async {
        await update(
            library: .loaded(
                library.wholeLibraryGridItems, authority: library.wholeLibraryInventoryAuthority,
                failure: libraryLoadFailure),
            albumNodeIDs: albumItems.map(Self.albumNodeIDs(of:)))
    }
}
