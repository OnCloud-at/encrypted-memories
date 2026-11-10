import PhotosCore
import SwiftUI

extension View {
    /// The failure alert of "Revert to Original": one message and one OK, no retry. The viewer shows it while it is
    /// open; the library window shows it when the revert fails after the viewer closed. Only the button ends it, so a
    /// dismissal that SwiftUI reports earlier never clears the state that the caller owns.
    public func revertToOriginalFailedAlert(isPresented: Bool, onDismiss: @escaping () -> Void) -> some View {
        alert(
            L10n.string("viewer.revert_original_failed"),
            isPresented: Binding(get: { isPresented }, set: { _ in })
        ) {
            Button(L10n.string("action.ok"), role: .cancel, action: onDismiss)
        }
    }
}
