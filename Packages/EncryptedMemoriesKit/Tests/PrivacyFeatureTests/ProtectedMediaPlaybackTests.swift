import AVFoundation
import DesignSystemCore
import XCTest

@MainActor
final class ProtectedMediaPlaybackTests: XCTestCase {
    func testCoveragePausesAndDetachesThenRestoresTheSamePlayer() {
        let player = AVPlayer()
        var attached: AVPlayer?
        ProtectedMediaPlayback.update(player, attached: attached, isCovered: false) { attached = $0 }
        XCTAssertTrue(attached === player)
        player.rate = 1
        XCTAssertEqual(player.rate, 1, "Playback must provide a positive control before concealment")
        ProtectedMediaPlayback.update(player, attached: attached, isCovered: true) { attached = $0 }
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(attached)
        ProtectedMediaPlayback.update(player, attached: attached, isCovered: false) { attached = $0 }
        XCTAssertTrue(attached === player, "Returning must restore the viewer's original player")
        XCTAssertEqual(player.rate, 0, "Returning alone must not resume paused playback")
    }
}
