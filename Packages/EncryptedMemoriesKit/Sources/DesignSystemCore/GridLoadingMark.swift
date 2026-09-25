import PhotosCore
import SwiftUI

/// The loading state of a grid page (a route, a collection, the year view): the app's shimmering logo from the
/// launch veil instead of a spinner, the same on macOS, iOS and iPadOS.
public struct GridLoadingMark: View {
    private let caption: String?

    public init(caption: String? = nil) {
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: 14) {
            LoadingMark()
                .frame(width: 64, height: 64)
            if let caption {
                Text(caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? L10n.string("loading.content"))
    }
}
