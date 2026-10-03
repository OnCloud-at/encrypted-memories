import AVFAudio
import PhotoViewerCore
import XCTest

@MainActor
final class MobileVideoAudioSessionTests: XCTestCase {
    func testAVideoPlaysWithTheSilentSwitchAndTheDefaultReturnsAfterTheLastVideo() {
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .soloAmbient, "browsing follows the Ring/Silent switch")

        VideoAudioSession.begin()
        XCTAssertEqual(session.category, .playback, "a video plays its sound with the switch set to silent")
        // Paging starts the next video before the previous page goes away.
        VideoAudioSession.begin()
        VideoAudioSession.end()
        XCTAssertEqual(session.category, .playback, "the next video keeps its sound")
        VideoAudioSession.end()
        XCTAssertEqual(session.category, .soloAmbient)

        VideoAudioSession.end()
        VideoAudioSession.begin()
        XCTAssertEqual(session.category, .playback, "an extra end never leaves a video without sound")
        VideoAudioSession.end()
    }
}
