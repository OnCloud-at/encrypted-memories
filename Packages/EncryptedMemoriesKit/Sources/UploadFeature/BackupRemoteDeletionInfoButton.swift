import PhotosCore
import SwiftUI

/// One native, cross-platform explanation for items that Proton proved were backed up and later
/// deleted remotely. Keeping the long copy behind this button prevents the calm progress row from
/// changing height while preserving the exact safety semantics on every platform.
public struct BackupRemoteDeletionInfoButton: View {
    private let message: String
    @State private var isPresented = false

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel(message)
        .alert(L10n.string("backup.remote_deletions_info_title"), isPresented: $isPresented) {
            Button(L10n.string("backup.failed_sheet_done"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
