import PhotosCore
import SwiftUI

/// The one Retry action of macOS, iOS and iPadOS, titled "Try again". `.prominent` is the main action of an empty or
/// error state; `.compact` is a small text button inside a row, a note or a banner; `.system` leaves the drawing to an
/// alert or a toolbar. Every style uses the same title.
public struct RetryButton: View {
    public enum Style: Sendable {
        /// The primary action below an empty or error state.
        case prominent
        /// A small text button inside a row, a note or a banner.
        case compact
        /// A button that an alert or a toolbar draws in its own style.
        case system
    }

    /// The single title of every Retry action.
    static var title: String { L10n.string("action.retry") }

    private let style: Style
    private let action: () -> Void

    public init(_ style: Style, action: @escaping () -> Void) {
        self.style = style
        self.action = action
    }

    public var body: some View {
        let button = Button(Self.title, action: action)
        switch style {
        case .prominent:
            button
                .buttonStyle(.glassProminent)
                .tint(ProtonColor.primary)
        case .compact:
            button
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.footnote)
                .tint(ProtonColor.primary)
        case .system:
            button
        }
    }
}
