import PhotosCore
import SwiftUI

/// Shown when the library could not be loaded; offers a retry when the failure is retryable. macOS, iOS and iPadOS
/// use this one view, so a library load failure has one symbol everywhere.
public struct LibraryLoadErrorView: View {
    private let message: String
    private let retryable: Bool
    private let selectableMessage: Bool
    private let onRetry: () -> Void

    /// `selectableMessage` lets people select and copy the message, as the Mac library does.
    public init(message: String, retryable: Bool, selectableMessage: Bool = false, onRetry: @escaping () -> Void) {
        self.message = message
        self.retryable = retryable
        self.selectableMessage = selectableMessage
        self.onRetry = onRetry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.icloud")
        } description: {
            if message.isEmpty {
                EmptyView()
            } else if selectableMessage {
                Text(message).textSelection(.enabled)
            } else {
                Text(message)
            }
        } actions: {
            if retryable {
                RetryButton(.prominent, action: onRetry)
            }
        }
    }
}
