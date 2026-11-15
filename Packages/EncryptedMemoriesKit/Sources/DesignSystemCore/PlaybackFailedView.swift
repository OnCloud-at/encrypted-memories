import PhotosCore
import SwiftUI

/// The state of a video that could not play, shared by the Mac viewer and the iPhone and iPad viewer: the native
/// unavailable view with the reason and, when a new attempt can work, the shared prominent Try again button. It sits
/// over the video page in the content layer, so it keeps a standard material card instead of Liquid Glass. The card is
/// as tall as its content and keeps a margin to the page edges; its width follows the page up to a readable width. A
/// page shorter than the card scrolls it, and its page learns so through `ScrollsKey`.
public struct PlaybackFailedView: View {
    private let error: VideoPlaybackError
    private let retry: () -> Void
    /// The card's height at its ideal size, measured by a hidden probe that does not depend on the page height.
    @State private var cardHeight: CGFloat = 0
    /// The height of the page. Both viewers place the card inside their safe area, so all of it is usable.
    @State private var pageHeight: CGFloat = 0
    /// Whether the card is taller than its page and sits in a scroll view.
    @State private var scrolls = false

    public init(_ error: VideoPlaybackError, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        // The page itself takes no touch or click: a card that fits covers only its own rectangle, so the page below
        // keeps every gesture outside it. A page shorter than the card, such as an iPhone in landscape or a large
        // text size, scrolls the card instead of cutting it.
        Color.clear
            .overlay {
                if scrolls {
                    ScrollView(.vertical) {
                        card.frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    card
                }
            }
            .background(alignment: .top) {
                framed(unavailableView)
                    .padding()
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        cardHeight = $0
                        decideScrolling()
                    }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                pageHeight = $0
                decideScrolling()
            }
            // A page with its own vertical drag, such as the swipe down that closes the iPhone viewer, reads this, so
            // a pan on a card that scrolls only scrolls it.
            .preference(key: ScrollsKey.self, value: scrolls)
            // Both viewer pages are dark in every appearance, so the card uses the dark scheme too.
            .environment(\.colorScheme, .dark)
    }

    /// True while the card is taller than its page and scrolls; false while it fits.
    public struct ScrollsKey: PreferenceKey {
        public static let defaultValue = false

        public static func reduce(value: inout Bool, nextValue: () -> Bool) {
            value = value || nextValue()
        }
    }

    private func decideScrolling() {
        scrolls = Self.scrolls(cardHeight: cardHeight, pageHeight: pageHeight, current: scrolls)
    }

    /// Within this distance of the page height the card keeps its current form, so a sub-point layout rounding never
    /// switches between the card and the scrolling card.
    nonisolated static let fitTolerance: CGFloat = 0.5

    /// Whether a card of `cardHeight` scrolls on a page of `pageHeight`, given whether it scrolls now.
    nonisolated static func scrolls(cardHeight: CGFloat, pageHeight: CGFloat, current: Bool) -> Bool {
        guard cardHeight > 0, pageHeight > 0 else { return current }
        if cardHeight > pageHeight + fitTolerance { return true }
        if cardHeight < pageHeight - fitTolerance { return false }
        return current
    }

    private var card: some View {
        framed(unavailableView)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding()
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label(Self.title, systemImage: Self.systemImage)
        } description: {
            Text(error.userMessage)
        } actions: {
            // A cause that is confirmed permanent shows no Try again.
            if error.isRetryable {
                RetryButton(.prominent, action: retry)
            }
        }
    }

    /// The card's content at a readable width and only as tall as it needs, with its inner padding.
    private func framed(_ content: some View) -> some View {
        content
            .frame(maxWidth: Self.readableWidth)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
    }

    /// Keeps the card compact on a large viewer window; on a narrower page the card takes the page width minus its
    /// margin. It is a card width, unlike `ActivityProgressStateLayout.readableWidth`, which sizes a progress line.
    nonisolated static let readableWidth: CGFloat = 360
    nonisolated static var title: String { L10n.string("viewer.playback_failed") }
    nonisolated static let systemImage = "exclamationmark.triangle"
}
