import PhotosCore
import SwiftUI

/// One native destructive confirmation for every Apple-platform sign-out entry point.
public extension View {
    func signOutConfirmation(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(
            L10n.string("sign_out.confirmation_title \(ProductBrand.displayName)"),
            isPresented: isPresented
        ) {
            Button(L10n.string("action.sign_out"), role: .destructive, action: onConfirm)
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("sign_out.confirmation_message"))
        }
    }
}
