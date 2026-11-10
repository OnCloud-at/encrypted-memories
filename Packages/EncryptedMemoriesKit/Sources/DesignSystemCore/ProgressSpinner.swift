import PhotosCore
import SwiftUI

/// The one native spinner of macOS, iOS and iPadOS, in the primary color. `.small` is the inline spinner for rows,
/// sections, toolbar buttons and the activity banner; `.large` is for a window or a sheet that waits as a whole.
/// VoiceOver reads "Loading" unless the caller names what loads. Spinners over photos and full-screen loading use the
/// loading marks instead.
public struct ProgressSpinner: View {
    public enum Size: Sendable {
        case small
        case large
    }

    private let size: Size
    private let accessibilityLabel: String?

    public init(_ size: Size = .small, accessibilityLabel: String? = nil) {
        self.size = size
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ProgressView()
            .controlSize(Self.controlSize(size))
            .tint(ProtonColor.primary)
            .accessibilityLabel(Self.label(accessibilityLabel))
    }

    nonisolated static func controlSize(_ size: Size) -> ControlSize {
        switch size {
        case .small: .small
        case .large: .large
        }
    }

    nonisolated static func label(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return L10n.string("loading.content") }
        return name
    }
}
