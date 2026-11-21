import PhotosCore
import SwiftUI

/// The album row of the viewer's Info when the albums of the photo could not be loaded: the short reason and the
/// shared compact Try again button. The Mac panel and the iOS sheet show the same content; each sets the font of its
/// row around it.
public struct ViewerAlbumMembershipsFailedView: View {
    private let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Self.message, systemImage: Self.systemImage)
                .foregroundStyle(.secondary)
            RetryButton(.compact, action: onRetry)
        }
    }

    nonisolated static var message: String { L10n.string("infopanel.albums_load_failed") }
    nonisolated static let systemImage = "exclamationmark.triangle"
}
