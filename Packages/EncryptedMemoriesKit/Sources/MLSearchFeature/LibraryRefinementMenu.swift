import PhotosCore
import SwiftUI
import TimelineCore

/// Shared library filter entries for iPhone, iPad, and Mac: all items, favorites, photos, and videos. Each platform
/// places them in its native menu; Core applies the filters in the search projection.
public struct LibraryRefinementMenuContent: View {
    @Binding private var refinement: TimelineRefinement
    private let favoritesAvailable: Bool

    public init(refinement: Binding<TimelineRefinement>, favoritesAvailable: Bool) {
        _refinement = refinement
        self.favoritesAvailable = favoritesAvailable
    }

    public var body: some View {
        Section {
            Button {
                refinement = .all
            } label: {
                Label(
                    L10n.string("library.filter_all"),
                    systemImage: refinement.isActive ? "square.grid.3x3" : "checkmark"
                )
            }
        }

        Section {
            Toggle(isOn: favoritesBinding) {
                Label(PhotoTag.favorites.title, systemImage: "heart")
            }
            .disabled(!favoritesAvailable)
            Toggle(isOn: mediaKindBinding(.photo)) {
                Label(L10n.string("library.filter_photos"), systemImage: "photo")
            }
            Toggle(isOn: mediaKindBinding(.video)) {
                Label(PhotoTag.videos.title, systemImage: "video")
            }
        }

        if refinement.isActive {
            Section {
                Button {
                    refinement = .all
                } label: {
                    Label(L10n.string("library.filter_remove"), systemImage: "minus.circle")
                }
            }
        }
    }

    private var favoritesBinding: Binding<Bool> {
        Binding(
            get: { refinement.favoritesOnly },
            set: { refinement.favoritesOnly = $0 }
        )
    }

    private func mediaKindBinding(_ kind: TimelineRefinement.MediaKind) -> Binding<Bool> {
        Binding(
            get: { refinement.mediaKinds.contains(kind) },
            set: { selected in
                if selected {
                    refinement.mediaKinds.insert(kind)
                } else {
                    refinement.mediaKinds.remove(kind)
                }
            }
        )
    }
}

extension TimelineRefinement {
    /// The active filters as one list, for example "Favorites and Videos"; "All Items" without a filter.
    public var localizedSummary: String {
        var labels: [String] = []
        if favoritesOnly { labels.append(PhotoTag.favorites.title) }
        if mediaKinds.contains(.photo) { labels.append(L10n.string("library.filter_photos")) }
        if mediaKinds.contains(.video) { labels.append(PhotoTag.videos.title) }
        return labels.isEmpty ? L10n.string("library.filter_all") : ListFormatter.localizedString(byJoining: labels)
    }
}
