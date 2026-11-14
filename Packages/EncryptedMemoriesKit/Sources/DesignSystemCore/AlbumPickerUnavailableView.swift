import PhotosCore
import SwiftUI

/// The native empty, search and Photos-access states shared by the album-sync pickers.
/// Each app supplies its own existing permission message, which names its system settings.
public struct AlbumPickerUnavailableView: View {
    private enum Content {
        case noAlbums
        case noMatches(String)
        case accessDenied(String)
    }

    private let content: Content

    public init() {
        content = .noAlbums
    }

    public init(searchText: String) {
        content = .noMatches(searchText)
    }

    public init(accessDeniedMessage: String) {
        content = .accessDenied(accessDeniedMessage)
    }

    public var body: some View {
        Group {
            switch content {
            case .noAlbums:
                ContentUnavailableView(Self.noAlbumsTitle, systemImage: "rectangle.stack")
            case .noMatches(let searchText):
                ContentUnavailableView.search(text: searchText)
            case .accessDenied(let message):
                ContentUnavailableView(message, systemImage: "lock.rectangle.stack")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    nonisolated static var noAlbumsTitle: String { L10n.string("albums.none_available") }
}
