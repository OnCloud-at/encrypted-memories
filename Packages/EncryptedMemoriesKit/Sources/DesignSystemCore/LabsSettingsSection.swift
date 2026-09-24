import PhotosCore
import SwiftUI

/// Shared Labs settings for macOS, iOS and iPadOS: one toggle for each feature that this build offers.
public struct LabsSettingsSection: View {
    private let features: [LabFeature]

    public init(build: AppBuildInfo = AppBuildInfo()) {
        features = LabFeature.offered(for: build)
    }

    public var body: some View {
        Section {
            if features.isEmpty {
                ContentUnavailableView {
                    Label {
                        // The title wraps instead of truncating in long languages and large text sizes.
                        Text(L10n.string("labs.empty_title"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "flask")
                    }
                } description: {
                    Text(L10n.string("labs.empty_message"))
                }
            } else {
                ForEach(features) { feature in
                    LabFeatureToggle(feature: feature)
                }
            }
        } footer: {
            Text(L10n.string("labs.intro"))
        }
    }
}

private struct LabFeatureToggle: View {
    let feature: LabFeature
    @AppStorage private var isOn: Bool

    init(feature: LabFeature) {
        self.feature = feature
        _isOn = AppStorage(wrappedValue: false, feature.preferenceKey)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(feature.localizedTitle)
            Text(feature.localizedSummary)
        }
    }
}
