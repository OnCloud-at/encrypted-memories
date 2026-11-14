import PhotosCore
import SwiftUI

/// The shared settings controls; each app supplies its native Settings container.
@MainActor
public struct PrivacySettingsContent: View {
    private let gate: AccessGate
    @State private var protection: ProtectedScopeSettings
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    @AppStorage(AppSettingsKey.removeLocationWhenSharing) private var removeLocationWhenSharing =
        AppSettingsDefault.removeLocationWhenSharing
    #if os(iOS)
        @AppStorage(AppSettingsKey.blurAppPreview) private var blurAppPreview =
            AppSettingsDefault.blurAppPreview
    #endif

    public init(gate: AccessGate = AppProtection.gate) {
        self.gate = gate
        _protection = State(initialValue: ProtectedScopeSettings(gate: gate, scope: .app))
    }

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
        #if os(iOS)
            Section {
                Toggle(L10n.string("settings.privacy_blur_preview"), isOn: $blurAppPreview)
            } footer: {
                Text(L10n.string("settings.privacy_blur_preview_explanation"))
            }
        #endif
        Section {
            Toggle(AppLockCopy.switchTitle(for: gate.availability), isOn: protection.enabled)
                .disabled(!protection.canChange)
            if gate.isEnabled(.app) {
                Picker(L10n.string("settings.privacy_app_lock_after"), selection: protection.gracePeriod) {
                    ForEach(ProtectedScopeGracePeriod.appOptions, id: \.self) { duration in
                        Text(AppLockCopy.delayTitle(duration)).tag(duration)
                    }
                }
                #if os(iOS)
                    .pickerStyle(.navigationLink)
                #else
                    .pickerStyle(.menu)
                #endif
                .disabled(!protection.canChange)
            }
        } footer: {
            Text(
                gate.availability == .noDeviceLock
                    ? AppLockCopy.noDeviceLockReason : L10n.string("settings.privacy_app_lock_footer"))
        }
        Section {
            Link(
                L10n.string("settings.privacy_policy"),
                destination: URL(string: "https://memories.oncloud.at/privacy.html")!
            )
        }
    }
}
