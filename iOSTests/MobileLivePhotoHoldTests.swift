import PhotoViewerCore
import UIKit
import VisionKit
import XCTest

@testable import EncryptedMemoriesMobile

@MainActor
final class MobileLivePhotoHoldTests: XCTestCase {
    func testInstalledLongPressUsesSharedDurationAndNativeTransitions() throws {
        var calls: [String] = []
        let (window, scroll, coordinator) = try makeHoldHost(
            onStart: { calls.append("start") }, onStop: { calls.append("stop") })
        defer { window.isHidden = true }
        let press = try XCTUnwrap(coordinator.motionPress)
        XCTAssertEqual(press.minimumPressDuration, LivePhotoHoldPolicy.minimumPressDuration)
        XCTAssertTrue(scroll.gestureRecognizers?.contains(press) == true)
        let injected = InjectedMotionPress()
        for terminal: UIGestureRecognizer.State in [.ended, .cancelled, .failed] {
            calls = []
            for state: UIGestureRecognizer.State in [
                .possible, .changed, terminal, .began, .began, .changed, terminal, terminal,
            ] {
                injected.state = state
                coordinator.handleLongPress(injected)
            }
            XCTAssertEqual(calls, ["start", "stop"])
        }
    }

    func testDeclinedTextSelectionQueryKeepsTheHoldPlaying() throws {
        var calls: [String] = []
        let (window, _, coordinator) = try makeHoldHost(
            onStart: { calls.append("start") }, onStop: { calls.append("stop") })
        defer { window.isHidden = true }
        let press = InjectedMotionPress()
        press.state = .began
        coordinator.handleLongPress(press)
        let interaction = ImageAnalysisInteraction(coordinator)
        XCTAssertFalse(coordinator.interaction(interaction, shouldBeginAt: .zero, for: .textSelection))
        XCTAssertEqual(calls, ["start"])
        press.state = .ended
        coordinator.handleLongPress(press)
        XCTAssertEqual(calls, ["start", "stop"])
    }

    private func makeHoldHost(
        onStart: @escaping () -> Void, onStop: @escaping () -> Void
    ) throws
        -> (UIWindow, UIScrollView, MobileZoomableImage.Coordinator)
    {
        let (window, _, scroll) = try makeHostedViewer(
            image: UIImage(), size: CGSize(width: 390, height: 844),
            onMotionStart: onStart, onMotionStop: onStop)
        return (window, scroll, try XCTUnwrap(scroll.delegate as? MobileZoomableImage.Coordinator))
    }
}

@MainActor
private final class InjectedMotionPress: UILongPressGestureRecognizer {
    private var injectedState = UIGestureRecognizer.State.possible
    override var state: UIGestureRecognizer.State {
        get { injectedState }
        set { injectedState = newValue }
    }
}
