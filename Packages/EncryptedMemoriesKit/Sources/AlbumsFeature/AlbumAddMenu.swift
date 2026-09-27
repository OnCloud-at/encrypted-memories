import AlbumCore
import PhotosCore
import SwiftUI

/// Apple-style "Add to" submenu: New Album first, then every album that takes photos. Each platform places it in
/// its native menu; adding, capability gating, and failures stay in `AlbumActionCoordinator`.
public struct AlbumAddMenu: View {
    private let coordinator: AlbumActionCoordinator
    private let photoUIDs: [PhotoUID]
    private let onNewAlbum: () -> Void
    private let onAdded: (AlbumID) -> Void

    public init(
        coordinator: AlbumActionCoordinator,
        photoUIDs: [PhotoUID],
        onNewAlbum: @escaping () -> Void,
        onAdded: @escaping (AlbumID) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.photoUIDs = photoUIDs
        self.onNewAlbum = onNewAlbum
        self.onAdded = onAdded
    }

    public var body: some View {
        Menu {
            Button {
                onNewAlbum()
            } label: {
                Label(L10n.string("albums.new_album_menu"), systemImage: "plus")
            }
            .disabled(!coordinator.canCreate)
            if coordinator.albums.isEmpty, coordinator.loadErrorMessage != nil {
                Divider()
                Button {
                    Task { await coordinator.refresh() }
                } label: {
                    Label(L10n.string("albums.try_again"), systemImage: "arrow.clockwise")
                }
            } else if !coordinator.albums.isEmpty {
                Divider()
                ForEach(coordinator.albums) { album in
                    Button {
                        add(to: album.id)
                    } label: {
                        Label(album.title, systemImage: "rectangle.stack")
                    }
                }
            }
        } label: {
            Label(L10n.string("albums.add_to_menu"), systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(photoUIDs.isEmpty || !coordinator.canAddPhotos || coordinator.isWorking)
    }

    private func add(to albumID: AlbumID) {
        let uids = photoUIDs
        Task {
            if await coordinator.add(uids, to: albumID) {
                onAdded(albumID)
            }
        }
    }
}
