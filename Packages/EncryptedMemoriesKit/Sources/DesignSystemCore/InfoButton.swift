import PhotosCore
import SwiftUI

/// A small native "i" that keeps a secondary explanation out of a calm status row. The row keeps its
/// height; the details are one tap away on every platform.
public struct InfoButton: View {
    private let title: String
    private let message: String
    @State private var isPresented = false

    public init(title: String, message: String) {
        self.title = title
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
        .accessibilityLabel(title)
        .accessibilityHint(message)
        .alert(title, isPresented: $isPresented) {
            Button(L10n.string("action.done"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
