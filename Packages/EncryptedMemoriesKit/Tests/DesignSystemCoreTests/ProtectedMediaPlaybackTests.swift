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

    @Test func onlyADifferentPlayerCountsAsAChange() {
        let playback = ProtectedMediaPlayback()
        let first = AVPlayer()
        var attached: AVPlayer?
        #expect(playback.update(first, attached: attached, isCovered: false) { attached = $0 })
        #expect(!playback.update(first, attached: attached, isCovered: true) { attached = $0 })
        let returned = playback.update(first, attached: attached, isCovered: false) { attached = $0 }
        #expect(!returned, "Returning from the cover keeps the poster state of the same player")
        #expect(playback.update(AVPlayer(), attached: attached, isCovered: false) { attached = $0 })
    }
}
