import DesignSystemCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

/// The shared video failure card on iPhone and iPad, in a live window. On a narrow, tall page, 375 by 800 points like
/// an iPhone in portrait, the card is only about as tall as its content, keeps its margin, sits in the middle and does
/// not scroll. On a page shorter than the card, like an iPhone in landscape at the largest text size, it starts at its
/// margin, continues below the page and reports that it scrolls.
final class MobilePlaybackFailedLayoutTests: XCTestCase {
    @MainActor func testTheCardHugsItsContentOnANarrowTallPage() async throws {
        for error: VideoPlaybackError in [.networkUnavailable, .decryptionFailed] {
            let page = try await HostedCardPage(error, size: CGSize(width: 375, height: 800))
            defer { page.close() }
            let card = try XCTUnwrap(page.cardFrame(), "the card has no layout: \(error)")
            XCTAssertLessThan(card.height, 400, "the card grows beyond its content: \(error) \(card)")
            XCTAssertGreaterThan(card.minX, 0, "the card touches the leading edge: \(error) \(card)")
            XCTAssertLessThan(card.maxX, 375, "the card touches the trailing edge: \(error) \(card)")
            XCTAssertEqual(card.midY, 400, accuracy: 2, "the card is not in the middle of the page: \(error) \(card)")
            XCTAssertFalse(page.reportsScrolling, "a card that fits reports scrolling: \(error)")
        }
    }

    @MainActor func testTheCardScrollsOnAShortPage() async throws {
        for height in [CGFloat(300), 200] {
            let page = try await HostedCardPage(
                .networkUnavailable, size: CGSize(width: 375, height: height), dynamicTypeSize: .accessibility5)
            defer { page.close() }
            let card = try XCTUnwrap(page.cardFrame(), "the card has no layout")
            XCTAssertEqual(card.minY, 16, accuracy: 1, "the card does not start at its margin: \(card)")
            XCTAssertGreaterThan(card.height, height, "the card is not taller than the page: \(card)")
            XCTAssertTrue(page.reportsScrolling, "a card taller than the page does not report scrolling: \(height)")
        }
    }
}

/// The card in a live window of a fixed size, where it lays out, and the scrolling it reports to its page.
@MainActor
private final class HostedCardPage {
    private final class Report {
        var scrolls = false
    }

    private let hosted: HostedTestWindow
    private var window: UIWindow { hosted.window }
    private let report = Report()
    private let card = PlaybackFailedCardFrame()

    init(
        _ error: VideoPlaybackError, size: CGSize, dynamicTypeSize: DynamicTypeSize = .large
    ) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        hosted = HostedTestWindow(scene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let report = report
        let host = UIHostingController(
            rootView: card.recording(
                PlaybackFailedView(error, retry: {})
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .onPreferenceChange(PlaybackFailedView.ScrollsKey.self) { report.scrolls = $0 }))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        let window = window
        do {
            try await card.settle { window.layoutIfNeeded() }
        } catch {
            hosted.close()
            throw error
        }
    }

    var reportsScrolling: Bool { report.scrolls }

    func close() {
        hosted.close()
    }

    /// The frame of the card in window coordinates: the page fills the window.
    func cardFrame() -> CGRect? {
        card.value
    }
}
