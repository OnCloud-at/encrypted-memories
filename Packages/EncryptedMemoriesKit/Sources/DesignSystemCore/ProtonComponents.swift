import PhotosCore
import SwiftUI

/// Placeholder shown by the root view during app boot / session preparation. The app's window-level launch
/// veil (a frosted, behind-window Liquid-Glass surface over a transparent window, with the animated
/// `LoadingMark`) covers the whole window during exactly these states, so this view is normally never seen.
/// It carries only the shared small spinner as a graceful fallback for the rare case where the veil's safety
/// timeout fades it while preparation is still ongoing - never a black screen, never heavy text. A caller that
/// names the state gets one quiet secondary line under the spinner, laid out like `GridLoadingMark`. VoiceOver reads
/// the caption, or "Loading" without one.
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
