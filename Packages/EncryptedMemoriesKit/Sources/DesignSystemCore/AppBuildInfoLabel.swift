import PhotosCore
import SwiftUI

/// One shared version label, with the source commit, used by every native settings surface.
public struct AppBuildInfoLabel: View {
    private let info: AppBuildInfo

    public init(info: AppBuildInfo = AppBuildInfo()) {
        self.info = info
    }

    public var body: some View {
        // Links open the system browser: the version its release page, the commit its source (CI builds only).
        HStack(spacing: 4) {
            Link(destination: info.releaseURL) { styled(Text(info.localizedVersion)) }
            if let shortCommit = info.shortCommit {
                styled(Text(verbatim: "·"))
                    .accessibilityHidden(true)
                if let commitURL = info.commitURL {
                    Link(destination: commitURL) { styled(Text(verbatim: shortCommit)) }
                } else {
                    styled(Text(verbatim: shortCommit))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.caption2)
            .foregroundStyle(ProtonColor.textHint)
            .monospacedDigit()
    }
}
