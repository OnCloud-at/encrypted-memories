import PhotosCore
import SwiftUI

/// Shown when the library could not be loaded; offers a retry when the failure is retryable. The library and the
/// album photo picker use this one view on macOS, iOS and iPadOS. Each platform keeps its symbol, and the Mac lets
/// people select and copy the message.
public struct LibraryLoadErrorView: View {
    private let message: String
    private let retryable: Bool
    private let onRetry: () -> Void

    public init(message: String, retryable: Bool, onRetry: @escaping () -> Void) {
        self.message = message
        self.retryable = retryable
        self.onRetry = onRetry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: Self.systemImage)
        } description: {
            if !message.isEmpty {
                #if os(macOS)
                    Text(message).textSelection(.enabled)
                #else
                    Text(message)
                #endif
            }
        } actions: {
            if retryable {
                RetryButton(.prominent, action: onRetry)
            }
        }
    }

    #if os(macOS)
        static let systemImage = "exclamationmark.triangle"
    #else
        static let systemImage = "exclamationmark.icloud"
    #endif
}
