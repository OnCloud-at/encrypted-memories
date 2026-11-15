import PhotosCore
import SwiftUI

/// The shared loading state for windows and sheets: the small spinner and an optional quiet caption.
/// Without a caption, only the spinner is visible. VoiceOver reads the caption, or "Loading" without one.
public struct ProtonLoadingView: View {
    private let caption: String?
    public init(caption: String? = nil) { self.caption = caption }

    public var body: some View {
        VStack(spacing: 14) {
            ProgressSpinner()
            if let caption {
                Text(caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(caption))
    }

    nonisolated static func accessibilityLabel(_ caption: String?) -> String {
        ProgressSpinner.label(caption)
    }
}
