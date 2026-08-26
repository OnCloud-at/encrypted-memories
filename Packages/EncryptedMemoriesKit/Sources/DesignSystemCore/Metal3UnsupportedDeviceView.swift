import PhotosCore
import SwiftUI

/// Shared, branded fallback for Apple devices below the app's Metal 3 hardware floor.
public struct Metal3UnsupportedDeviceView: View {
    private let productName: String

    public init(productName: String = ProductBrand.displayName) {
        self.productName = productName
    }

    public var body: some View {
        ContentUnavailableView {
            VStack(spacing: 18) {
                MemoriesBrandMark(height: 68)
                    .padding(18)
                    .protonGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                Text(L10n.string("device.unsupported_title"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ProtonColor.textNorm)
            }
        } description: {
            VStack(spacing: 10) {
                Text(L10n.string("device.requires_metal3 \(productName)"))
                Text(L10n.string("device.unsupported_reassurance"))
            }
            .foregroundStyle(ProtonColor.textWeak)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 560)
    }
}
