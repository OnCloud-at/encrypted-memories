import AVFoundation

/// Updates the native video surface without changing the viewer's player or seek position.
@MainActor
public enum ProtectedMediaPlayback {
    public static func update(_ player: AVPlayer, attached: AVPlayer?, isCovered: Bool, attach: (AVPlayer?) -> Void) {
        if isCovered { player.pause() }
        let visiblePlayer = isCovered ? nil : player
        if attached !== visiblePlayer { attach(visiblePlayer) }
    }
}
