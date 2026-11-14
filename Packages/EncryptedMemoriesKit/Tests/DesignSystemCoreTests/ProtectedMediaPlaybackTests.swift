import AVFoundation
import Testing

@testable import DesignSystemCore

@MainActor @Suite struct ProtectedMediaPlaybackTests {
    @Test func coveragePausesAndDetachesThenRestoresTheSamePlayer() {
        let playback = ProtectedMediaPlayback()
        let player = AVPlayer()
        var attached: AVPlayer?
        playback.update(player, attached: attached, isCovered: false) { attached = $0 }
        #expect(attached === player)
        player.rate = 1
        #expect(player.rate == 1, "Playback must provide a positive control before concealment")
        playback.update(player, attached: attached, isCovered: true) { attached = $0 }
        #expect(player.rate == 0)
        #expect(attached == nil)
        playback.update(player, attached: attached, isCovered: false) { attached = $0 }
        #expect(attached === player, "Returning must restore the viewer's original player")
        #expect(player.rate == 0, "Returning alone must not resume paused playback")
    }

    @Test func playbackThatStartsWhileCoveredPausesAgain() async {
        let playback = ProtectedMediaPlayback()
        let player = AVPlayer()
        var attached: AVPlayer?
        playback.update(player, attached: attached, isCovered: true) { attached = $0 }
        player.rate = 1
        #expect(player.rate == 1, "Starting playback must provide a positive control")
        for _ in 0..<50 where player.rate != 0 { await Task.yield() }
        #expect(player.rate == 0, "A player that starts while covered must pause again")
        playback.update(player, attached: attached, isCovered: false) { attached = $0 }
        player.rate = 1
        for _ in 0..<50 { await Task.yield() }
        #expect(player.rate == 1, "Uncovered playback must stay untouched")
    }

    @Test func thePosterIsAttachedOncePerPlayerAndKeptThroughTheCover() {
        let playback = ProtectedMediaPlayback()
        let first = AVPlayer()
        var attached: AVPlayer?
        func update(_ player: AVPlayer, covered: Bool) -> ProtectedMediaPlayback.PosterAction {
            playback.update(player, attached: attached, isCovered: covered) { attached = $0 }
        }
        #expect(update(first, covered: false) == .attach)
        #expect(update(first, covered: false) == .refresh, "A poster still waiting for the first frame refreshes")
        #expect(update(first, covered: true) == .keep, "The covering update must not show the poster again")
        #expect(update(first, covered: true) == .keep)
        #expect(update(first, covered: false) == .keep, "Returning from the cover keeps the revealed poster state")
        #expect(update(first, covered: false) == .refresh)
        let second = AVPlayer()
        #expect(update(second, covered: true) == .attach, "A new player gets its poster once, also while covered")
        #expect(update(second, covered: false) == .keep)
    }
}
