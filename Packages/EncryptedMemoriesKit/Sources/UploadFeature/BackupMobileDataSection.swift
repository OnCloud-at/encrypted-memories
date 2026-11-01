import PhotosCore
import SwiftUI

/// "Use Cellular Data" in the Backup settings of macOS, iOS and iPadOS. The value persists in the shared defaults
/// that every backup upload path reads; `onChange` lets the host resume a backup that waits for Wi-Fi.
public struct BackupMobileDataSection<BeforeMobileData: View>: View {
    @AppStorage(AppSettingsKey.backupUsesMobileData)
    private var usesMobileData = AppSettingsDefault.backupUsesMobileData
    private let onChange: @MainActor () -> Void
    private let showsMobileData: Bool
    private let beforeMobileData: BeforeMobileData

    /// The preceding rows stay visible when the host hides the cellular-data control.
    public init(
        showsMobileData: Bool = true,
        onChange: @escaping @MainActor () -> Void = {},
        @ViewBuilder beforeMobileData: () -> BeforeMobileData
    ) {
        self.onChange = onChange
        self.showsMobileData = showsMobileData
        self.beforeMobileData = beforeMobileData()
    }

    public var body: some View {
        Section {
            beforeMobileData
            if showsMobileData {
                Toggle(L10n.string("settings.backup_use_mobile_data"), isOn: $usesMobileData)
                    .accessibilityIdentifier("backup.useMobileData")
                    .onChange(of: usesMobileData) { _, _ in onChange() }
            }
        } footer: {
            if showsMobileData {
                Text(L10n.string("settings.backup_use_mobile_data_footer"))
            }
        }
    }
}

extension BackupMobileDataSection where BeforeMobileData == EmptyView {
    public init(onChange: @escaping @MainActor () -> Void = {}) {
        self.init(onChange: onChange, beforeMobileData: { EmptyView() })
    }
}
