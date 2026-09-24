import AlbumCore
import AlbumsFeature
import AppKit
import DesignSystem
import DesignSystemCore
import MediaCache
import PhotosCore
import SwiftUI
import TimelineFeature

/// Collapsible left sidebar - a native macOS sidebar `List` (Liquid-Glass vibrant material, native
/// selection): Proton smart filters (tags) on top, user albums below.
struct SidebarView: View {
    let albums: [AlbumSummary]
    let isLoadingAlbums: Bool
    let albumCatalogFailed: Bool
    let sharedAlbums: [SharedAlbumSummary]
    let sharedAlbumPresentation: (SharedAlbumSummary) -> SharedAlbumPresentation
    let isLoadingSharedAlbums: Bool
    let sharedAlbumCatalogFailed: Bool
    let canLeaveSharedAlbum: Bool
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    @Binding var selection: PhotoFilter
    let onRetryAlbums: () -> Void
    let onRetrySharedAlbums: () -> Void
    let onLeaveSharedAlbum: (SharedAlbumSummary) -> Void
    @State private var pendingSharedAlbumLeave: SharedAlbumSummary?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
            Section {
                Label("sidebar.all_photos", systemImage: "photo.on.rectangle.angled")
                    .tag(PhotoFilter.all)
                ForEach(PhotoTag.allCases, id: \.self) { tag in
                    Label(tag.title, systemImage: tag.systemImage)
                        .tag(PhotoFilter.tag(tag))
                }
                Label("sidebar.map", systemImage: "map")
                    .tag(PhotoFilter.map)
            }
            Section("sidebar.albums") {
                if isLoadingAlbums, albums.isEmpty {
                    Label("sidebar.albums_loading", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                } else if albumCatalogFailed, albums.isEmpty {
                    Button(action: onRetryAlbums) {
                        Label("sidebar.albums_failed", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                } else if albums.isEmpty {
                    Label("sidebar.no_albums", systemImage: "tray")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                if albumCatalogFailed, !albums.isEmpty {
                    Button(action: onRetryAlbums) {
                        Label("sidebar.albums_failed", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(albums) { album in
                    OwnedAlbumSidebarRow(
                        album: album,
                        thumbnailFeed: thumbnailFeed,
                        sourceAnalysisRevision: sourceAnalysisRevision
                    )
                    .tag(PhotoFilter.album(id: album.id, title: album.title))
                }
            }
            Section(L10n.string("collections.section_shared_with_me")) {
                if isLoadingSharedAlbums, sharedAlbums.isEmpty {
                    Label(
                        L10n.string("collections.loading_shared_albums"),
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .foregroundStyle(.secondary)
                    .disabled(true)
                } else if sharedAlbumCatalogFailed, sharedAlbums.isEmpty {
                    Button(action: onRetrySharedAlbums) {
                        Label(L10n.string("albums.shared_load_failed"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                } else if sharedAlbums.isEmpty {
                    Label(L10n.string("collections.empty_shared_albums"), systemImage: "person.2.crop.square.stack")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                ForEach(sharedAlbums) { album in
                    SharedAlbumSidebarRow(
                        album: album,
                        presentation: sharedAlbumPresentation(album),
                        thumbnailFeed: thumbnailFeed,
                        sourceAnalysisRevision: sourceAnalysisRevision
                    )
                    .tag(
                        PhotoFilter.sharedAlbum(
                            volumeID: album.node.volumeID,
                            nodeID: album.node.nodeID,
                            title: album.title
                        )
                    )
                    .contextMenu {
                        if canLeaveSharedAlbum {
                            Button(L10n.string("albums.leave_shared_action"), role: .destructive) {
                                pendingSharedAlbumLeave = album
                            }
                        }
                    }
                }
            }
            Section {
                Label("sidebar.recently_deleted", systemImage: "trash")
                    .tag(PhotoFilter.trash)
            }
            Section {
                Divider()
                SettingsLink {
                    Label("sidebar.settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .help("sidebar.settings")
                .accessibilityLabel("sidebar.settings")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)  // let the within-window glass (and the grid behind it) show through
        .confirmationDialog(
            L10n.string("albums.leave_shared_title"),
            isPresented: Binding(
                get: { pendingSharedAlbumLeave != nil },
                set: { if !$0 { pendingSharedAlbumLeave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("albums.leave_shared_action"), role: .destructive) {
                guard let album = pendingSharedAlbumLeave else { return }
                onLeaveSharedAlbum(album)
                pendingSharedAlbumLeave = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingSharedAlbumLeave = nil
            }
        } message: {
            Text(L10n.string("albums.leave_shared_message"))
        }
    }
}

/// Sidebar cover thumbnail shared by owned and shared album rows. Falls back to a symbol until the
/// thumbnail feed has the cover in memory or on disk.
private struct AlbumSidebarCover: View {
    let coverUID: PhotoUID?
    let fallbackSystemImage: String
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64
    @State private var coverImage: NSImage?
    @State private var loadedCoverUID: PhotoUID?

    private struct CoverLoadKey: Equatable {
        let uid: PhotoUID?
        let analysisRevision: UInt64
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: CoverLoadKey(uid: coverUID, analysisRevision: sourceAnalysisRevision)) {
            if loadedCoverUID != coverUID {
                coverImage = nil
                loadedCoverUID = coverUID
            }
            guard coverImage == nil else { return }
            guard let coverUID else { return }
            coverImage = thumbnailFeed.memoryImage(for: coverUID)
            if coverImage == nil {
                coverImage = await thumbnailFeed.analysisImage(for: coverUID)
            }
        }
    }
}

private struct OwnedAlbumSidebarRow: View {
    let album: AlbumSummary
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64

    var body: some View {
        HStack(spacing: 8) {
            AlbumSidebarCover(
                coverUID: album.coverPhotoUID,
                fallbackSystemImage: "rectangle.stack",
                thumbnailFeed: thumbnailFeed,
                sourceAnalysisRevision: sourceAnalysisRevision
            )
            Text(album.title)
                .lineLimit(1)
        }
    }
}

private struct SharedAlbumSidebarRow: View {
    let album: SharedAlbumSummary
    let presentation: SharedAlbumPresentation
    let thumbnailFeed: ThumbnailFeed
    let sourceAnalysisRevision: UInt64

    /// The row stays compact; the read-only reason lives in the tooltip and accessibility hint.
    private var helpText: String {
        [presentation.detailLine, presentation.invitationDetail, presentation.writeRestrictionReason]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            AlbumSidebarCover(
                coverUID: album.coverPhotoUID,
                fallbackSystemImage: "person.2.crop.square.stack",
                thumbnailFeed: thumbnailFeed,
                sourceAnalysisRevision: sourceAnalysisRevision
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .lineLimit(1)
                Text(presentation.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let invitation = presentation.invitationDetail {
                    Text(invitation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint ?? "")
    }
}
