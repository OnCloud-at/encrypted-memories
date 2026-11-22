import AlbumCore
import Foundation
import Observation
import PhotosCore

/// What the picker knows about the library it offers photos from.
public enum AlbumPhotoPickerLibrary: Sendable, Equatable {
    case loading
    /// The items shown so far, how far they are known, and the message of the last load, if it failed. A saved
    /// library can stay shown after a failed load; the failure then explains why the picker cannot wait for more.
    case loaded([PhotoItem], authority: SourceInventoryAuthority, failure: String? = nil)
}

/// What the picker shows.
public enum AlbumPhotoPickerContent: Sendable, Equatable {
    case loading
    /// The library could not load; Retry loads it again.
    case failed(message: String)
    case emptyLibrary
    case nothingToAdd
    case choose
}

/// The result of one Add.
public enum AlbumPhotoPickerSubmitOutcome: Sendable, Equatable {
    case added
    case failed
    /// Nothing was sent, for example while another album change runs. The selection stays.
    case notStarted
}

/// The photos a person can add to one owned album from the album's menu, and their choice. The add itself is the
/// shared `AlbumActionCoordinator.add` write, so capability gating, the shared-album guard and failures stay in one
/// place.
///
/// The candidates are fixed once the grid shows them: a later library update can neither take a photo out from
/// under the person's selection nor reset a grid that keeps its own selection.
@MainActor
@Observable
public final class AlbumPhotoPickerModel {
    public let albumID: AlbumID
    public private(set) var candidates: [PhotoItem] = []
    public private(set) var selection: Set<PhotoUID> = []
    public private(set) var content: AlbumPhotoPickerContent = .loading
    /// The failure of the picker's last whole-library load, shown with Retry while the library is not known.
    public internal(set) var libraryLoadFailure: String?
    let coordinator: AlbumActionCoordinator
    @ObservationIgnored private var candidateUIDs: Set<PhotoUID> = []
    @ObservationIgnored private var updateGeneration: UInt64 = 0

    public init(albumID: AlbumID, coordinator: AlbumActionCoordinator) {
        self.albumID = albumID
        self.coordinator = coordinator
    }

    /// The album menu offers the picker only for an owned album whose backend accepts photos. Shared albums stay
    /// read-only.
    public static func isOffered(for filter: PhotoFilter, coordinator: AlbumActionCoordinator) -> Bool {
        guard case .album = filter else { return false }
        return coordinator.canAddPhotos
    }

    /// The one place that decides which library photos the picker offers: every photo the library grid shows,
    /// except those the album already holds. Photos that are still backing up stay in; the album write links them
    /// after their upload. One pass over the library.
    nonisolated static func candidates(
        from libraryItems: [PhotoItem], excludingAlbumNodeIDs albumNodeIDs: Set<String>
    ) -> [PhotoItem] {
        libraryItems.filter { $0.uid.isLocalPending || !albumNodeIDs.contains($0.uid.nodeID) }
    }

    /// Node identities the album holds. Albums and the library live on the same account volume, but grids group
    /// Live Photos and bursts on their own, so every member node of a shown album item counts, and the volume
    /// does not.
    public nonisolated static func albumNodeIDs(of albumItems: [PhotoItem]) -> Set<String> {
        var nodeIDs = Set<String>()
        for item in albumItems {
            nodeIDs.insert(item.uid.nodeID)
            nodeIDs.formUnion(item.burstMemberIDs)
            if let relatedVideoID = item.relatedVideoID { nodeIDs.insert(relatedVideoID) }
        }
        return nodeIDs
    }

    /// Applies the latest library and album state. `albumNodeIDs` is nil while the album itself still loads.
    public func update(library: AlbumPhotoPickerLibrary, albumNodeIDs: Set<String>?) async {
        guard content != .choose else { return }
        updateGeneration &+= 1
        let generation = updateGeneration
        guard case .loaded(let items, let authority, let failure) = library else {
            content = .loading
            return
        }
        let failed = failure.map { AlbumPhotoPickerContent.failed(message: $0) }
        if items.isEmpty, authority != .authoritative, let failed {
            content = failed
            return
        }
        guard let albumNodeIDs else {
            content = .loading
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            Self.candidates(from: items, excludingAlbumNodeIDs: albumNodeIDs)
        }.value
        guard generation == updateGeneration, content != .choose else { return }
        if !computed.isEmpty {
            candidates = computed
            candidateUIDs = Set(computed.map(\.uid))
            content = .choose
        } else if authority != .authoritative {
            // Without a known library only a running load can still bring photos; a failed one cannot.
            content = failed ?? .loading
        } else {
            content = items.isEmpty ? .emptyLibrary : .nothingToAdd
        }
    }

    public var canSubmit: Bool { !selection.isEmpty && !coordinator.isWorking }

    public func toggle(_ uid: PhotoUID) {
        guard candidateUIDs.contains(uid) else { return }
        if selection.remove(uid) == nil { selection.insert(uid) }
    }

    public func replaceSelection(with uids: Set<PhotoUID>) {
        selection = uids.intersection(candidateUIDs)
    }

    /// Adds the selection in library order. On failure the selection stays, so the person can try again.
    public func submit() async -> AlbumPhotoPickerSubmitOutcome {
        guard canSubmit else { return .notStarted }
        let ordered = candidates.map(\.uid).filter { selection.contains($0) }
        if await coordinator.add(ordered, to: albumID) { return .added }
        return coordinator.actionFailure == nil ? .notStarted : .failed
    }
}
