import DesignSystemCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

/// The shared video failure card on iPhone and iPad: on a narrow, tall page, 375 by 800 points like an iPhone in
/// portrait, the card is only about as tall as its content and never wider than the page.
final class MobilePlaybackFailedLayoutTests: XCTestCase {
    @MainActor func testTheCardHugsItsContentOnANarrowTallPage() {
        for error: VideoPlaybackError in [.networkUnavailable, .decryptionFailed] {
            let host = UIHostingController(rootView: PlaybackFailedView(error, retry: {}))
            let size = host.sizeThatFits(in: CGSize(width: 375, height: 800))
            XCTAssertLessThan(size.height, 400, "the card grows beyond its content: \(error) \(size)")
            XCTAssertLessThanOrEqual(size.width, 375, "the card is wider than the page: \(error) \(size)")
        }
    }
}
