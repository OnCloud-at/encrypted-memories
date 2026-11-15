import PhotosCore
import SwiftUI

/// The state of a video that could not play, shared by the Mac viewer and the iPhone and iPad viewer: the native
/// unavailable view with the reason and, when a new attempt can work, the shared prominent Try again button. It sits
/// over the video page in the content layer, so it keeps a standard material card instead of Liquid Glass. The card is
/// as tall as its content and keeps a margin to the page edges; its width follows the page up to a readable width.
public struct PlaybackFailedView: View {
    private let error: VideoPlaybackError
    private let retry: () -> Void

    public init(_ error: VideoPlaybackError, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        unavailableView
            .frame(maxWidth: Self.readableWidth)
            // Only the height hugs the content; the width still follows the page, so no width is fixed.
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding()
            // Both viewer pages are dark in every appearance, so the card uses the dark scheme too.
            .environment(\.colorScheme, .dark)
    }

    /// A cause that is confirmed permanent shows no Try again. That view has no actions at all, so no empty actions
    /// slot adds space below the reason.
    @ViewBuilder private var unavailableView: some View {
        if error.isRetryable {
            ContentUnavailableView {
                label
            } description: {
                reason
            } actions: {
                RetryButton(.prominent, action: retry)
            }
        } else {
            ContentUnavailableView {
                label
            } description: {
                reason
            }
        }
    }

    private var label: some View { Label(Self.title, systemImage: Self.systemImage) }
    private var reason: some View { Text(error.userMessage) }

    /// Keeps the card compact on a large viewer window; on a narrower page the card takes the page width minus its
    /// margin. It is a card width, unlike `ActivityProgressStateLayout.readableWidth`, which sizes a progress line.
    nonisolated static let readableWidth: CGFloat = 360
    nonisolated static var title: String { L10n.string("viewer.playback_failed") }
    nonisolated static let systemImage = "exclamationmark.triangle"
}
