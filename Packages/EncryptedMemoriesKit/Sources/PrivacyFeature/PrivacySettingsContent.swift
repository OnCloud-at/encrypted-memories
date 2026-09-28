import PhotosCore
import SwiftUI

/// The shared settings controls; each app supplies its native Settings container.
public struct PrivacySettingsContent: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    @AppStorage(AppSettingsKey.removeLocationWhenSharing) private var removeLocationWhenSharing =
        AppSettingsDefault.removeLocationWhenSharing

    public init() {}

    public var body: some View {
        Section {
            Toggle(L10n.string("settings.privacy_map_and_places"), isOn: $mapAndPlacesEnabled)
        } footer: {
            Text(L10n.string("settings.privacy_map_explanation"))
        }
        Section {
            Toggle(L10n.string("settings.privacy_remove_location"), isOn: $removeLocationWhenSharing)
        } footer: {
            Text(L10n.string("settings.privacy_remove_location_explanation"))
        }
        Section {
            Link(
                L10n.string("settings.privacy_policy"),
                destination: URL(string: "https://memories.oncloud.at/privacy.html")!
            )
        }
    }
}
