import SwiftUI

/// The one unlock surface of every protected area. It is opaque, so no content shows through, and it holds a
/// single Unlock action. The host supplies the texts for the available method and the content bounds that keep
/// the action clear of reserved display regions. The bounds are in the cover's own coordinate space, which spans
/// the whole window including the safe areas, like a `GeometryReader` that ignores the safe area.
public struct ProtectedScopeCover: View {
    private let unlockTitle: String
    private let accessibilityLabel: String
    private let isAuthenticating: Bool
    private let contentBounds: CGRect?
    private let unlock: () -> Void

    public init(
        unlockTitle: String, accessibilityLabel: String, isAuthenticating: Bool, contentBounds: CGRect? = nil,
        unlock: @escaping () -> Void
    ) {
        self.unlockTitle = unlockTitle
        self.accessibilityLabel = accessibilityLabel
        self.isAuthenticating = isAuthenticating
        self.contentBounds = contentBounds
        self.unlock = unlock
    }

    private var content: some View {
        VStack(spacing: ProtectedScopeCoverMetrics.spacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: ProtectedScopeCoverMetrics.symbolSize))
                .foregroundStyle(ProtonColor.textWeak)
                .accessibilityHidden(true)
            Button(unlockTitle, action: unlock)
                .buttonStyle(.glassProminent)
                .tint(ProtonColor.primary)
                .disabled(isAuthenticating)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    public var body: some View {
        ZStack {
            ProtonColor.backgroundNorm
            if let contentBounds {
                content
                    .position(x: contentBounds.midX, y: contentBounds.midY)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }
}

public enum ProtectedScopeCoverMetrics {
    public static let symbolSize: CGFloat = 44
    public static let spacing: CGFloat = 24
}
