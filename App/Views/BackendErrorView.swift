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
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 42))
                .foregroundStyle(ProtonColor.warning)
            Text("error.library_open_failed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
