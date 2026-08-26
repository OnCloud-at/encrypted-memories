import PhotosCore
import SwiftUI

/// One shared version/build label used by every native settings surface.
public struct AppBuildInfoLabel: View {
    private let info: AppBuildInfo

    public init(info: AppBuildInfo = AppBuildInfo()) {
        self.info = info
    }

    public var body: some View {
        Text(info.localizedSettingsSummary)
            .font(.caption2)
            .foregroundStyle(ProtonColor.textHint)
            .monospacedDigit()
    }
}
