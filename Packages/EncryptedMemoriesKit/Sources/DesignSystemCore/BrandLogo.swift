import SwiftUI

/// Shared Encrypted Memories brand mark sourced from `DesignSystemCore/Resources/Branding.xcassets`.
/// App targets use this view instead of carrying platform-local logo drawings or asset copies.
public struct MemoriesBrandMark: View {
    private let height: CGFloat

    public init(height: CGFloat) {
        self.height = height
    }

    public var body: some View {
        Image("EncryptedMemoriesMono", bundle: .module)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(ProtonColor.brandMark)
            .accessibilityHidden(true)
    }
}
