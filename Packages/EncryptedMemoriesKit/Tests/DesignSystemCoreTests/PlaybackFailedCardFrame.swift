import SwiftUI

@testable import DesignSystemCore

/// Where the video failure card lies, read from the layout. How its material draws depends on the renderer: the hosted
/// macOS test runner draws it without the backdrop layer that a local Mac draws. The package tests on macOS and the
/// iOS app tests share this file.
@MainActor
final class PlaybackFailedCardFrame {
    /// The card's frame in the coordinates of the view that `recording(_:)` wraps, or nil before the card is laid out.
    private(set) var value: CGRect?

    /// `view` with a transparent overlay that records the frame of its card. The overlay takes no events.
    func recording(_ view: some View) -> some View {
        view.overlayPreferenceValue(PlaybackFailedView.CardBoundsKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.onChange(of: anchor.map { proxy[$0] }, initial: true) { _, frame in self.value = frame }
            }
            .allowsHitTesting(false)
        }
    }

    /// Runs `layOut` until the card has a frame that three passes in a row keep, at least 10 and at most 100 passes
    /// 30 ms apart. The card first measures itself and then decides whether it scrolls, so its frame can change after
    /// it first appears.
    func settle(layOut: () -> Void) async throws {
        var previous: CGRect?
        var unchanged = 0
        for pass in 0..<100 {
            layOut()
            try await Task.sleep(for: .milliseconds(30))
            unchanged = value != nil && value == previous ? unchanged + 1 : 0
            previous = value
            if pass >= 9, unchanged >= 2 { return }
        }
    }
}
