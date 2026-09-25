import PhotosCore
import SwiftUI

/// An action that the person can undo for a few seconds.
public struct UndoNoticeContent: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
    public let systemImage: String
    public let undo: @MainActor () -> Void

    public init(message: String, systemImage: String, undo: @escaping @MainActor () -> Void) {
        self.message = message
        self.systemImage = systemImage
        self.undo = undo
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The shared undo notice of macOS, iOS and iPadOS: a glass capsule at the bottom of the grid, like the
/// activity banner, with an Undo button. It hides itself after six seconds.
public struct UndoNoticeOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var notice: UndoNoticeContent?
    private let bottomPadding: CGFloat
    private let leadingObstructionInset: CGFloat

    public init(notice: Binding<UndoNoticeContent?>, bottomPadding: CGFloat = 20, leadingObstructionInset: CGFloat = 0)
    {
        _notice = notice
        self.bottomPadding = bottomPadding
        self.leadingObstructionInset = max(0, leadingObstructionInset)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let notice {
                capsule(notice)
                    .padding(.bottom, bottomPadding)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(6))
                        guard !Task.isCancelled, self.notice?.id == notice.id else { return }
                        self.notice = nil
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, leadingObstructionInset)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(duration: 0.3), value: notice?.id)
    }

    private func capsule(_ notice: UndoNoticeContent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.systemImage)
                .foregroundStyle(.secondary)
            Text(notice.message)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Button(L10n.string("action.undo")) {
                self.notice = nil
                notice.undo()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glassEffect(in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }
}
