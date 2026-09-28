import PhotosCore
import SwiftUI

/// The shared settings controls; each app supplies its native Settings container.
public struct PrivacySettingsContent: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled

    public init() {}

    public var body: some View {
        Section {
            Toggle(L10n.string("settings.privacy_map_and_places"), isOn: $mapAndPlacesEnabled)
            Link(
                L10n.string("settings.privacy_policy"),
                destination: URL(string: "https://memories.oncloud.at/privacy.html")!
            )
        } footer: {
            Text(L10n.string("settings.privacy_map_explanation"))
        }
    }
}
