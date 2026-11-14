import DesignSystemCore
import PhotosCore
import SwiftUI

struct BackendErrorView: View {
    let message: String
    /// False only when the open failure is confirmed permanent; the Retry button stays hidden then,
    /// because another attempt with the same session cannot succeed.
    let isRetryable: Bool
    let retry: () -> Void
    let signOut: () -> Void
    @State private var confirmSignOut = false

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("error.library_open_failed")
            } icon: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(ProtonColor.warning)
            }
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 10) {
                if isRetryable {
                    RetryButton(.prominent, action: retry).frame(minWidth: 120)
                }
                Button(L10n.string("action.sign_out")) { confirmSignOut = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
        .signOutConfirmation(isPresented: $confirmSignOut, onConfirm: signOut)
    }
}
