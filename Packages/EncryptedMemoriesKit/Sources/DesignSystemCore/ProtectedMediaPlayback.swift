import AVFoundation
import SwiftUI

/// Keeps one native video surface silent and empty while protected content is covered, without changing the
/// viewer's player or seek position. Each surface owns one instance.
@MainActor
public final class ProtectedMediaPlayback {
    private weak var player: AVPlayer?
    private var isCovered = false
    private var rateObservation: NSKeyValueObservation?

    public init() {}

    /// What the host does with its poster after an update.
    public enum PosterAction: Equatable {
        /// A different player arrived: show its poster until its first frame is ready.
        case attach
        /// The same player stayed on screen: refresh a poster that is still waiting for the first frame.
        case refresh
        /// Keep the poster state as it is: the surface is covered, returns from the cover, or gets the same player
        /// back after the host cleared or replaced its attachment outside this hook.
        case keep
    }

    /// Pauses and detaches the player while covered and attaches it again afterwards without resuming playback.
    /// Playback that starts while covered pauses again.
    @discardableResult
    public func update(
        _ player: AVPlayer, attached: AVPlayer?, isCovered: Bool, attach: (AVPlayer?) -> Void
    ) -> PosterAction {
        let changed = self.player !== player
        let stayedOnScreen = !changed && !isCovered && attached === player
        if changed || self.isCovered != isCovered {
            self.player = player
            self.isCovered = isCovered
            rateObservation = isCovered ? observeRate(of: player) : nil
        }
        if isCovered { player.pause() }
        let visiblePlayer = isCovered ? nil : player
        if attached !== visiblePlayer { attach(visiblePlayer) }
        if changed { return .attach }
        return stayedOnScreen ? .refresh : .keep
    }

    private func observeRate(of player: AVPlayer) -> NSKeyValueObservation {
        player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard change.newValue != 0 else { return }
            Task { @MainActor [weak self] in self?.pauseWhileCovered() }
        }
    }

    private func pauseWhileCovered() {
        if isCovered { player?.pause() }
    }
}

extension View {
    /// Runs `action` whenever protected content becomes covered, including content that appears covered.
    public func onProtectedCover(_ action: @escaping () -> Void) -> some View {
        modifier(ProtectedCoverAction(action: action))
    }
}

private struct ProtectedCoverAction: ViewModifier {
    @Environment(\.protectedContentIsCovered) private var isCovered
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isCovered, initial: true) { _, covered in
            if covered { action() }
        }
    }
}
