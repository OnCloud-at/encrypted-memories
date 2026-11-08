import PhotoViewerCore
import SwiftUI
import UIKit
import VisionKit
import XCTest

@testable import EncryptedMemoriesMobile

@MainActor
final class MobileLivePhotoHoldTests: XCTestCase {
    func testInstalledLongPressUsesSharedDurationAndNativeTransitions() throws {
        var calls: [String] = []
        let (window, _, scroll, coordinator) = try makeMobileHoldHost(
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
        let (window, _, _, coordinator) = try makeMobileHoldHost(
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

    private func makeMobileHoldHost(
        onStart: @escaping () -> Void, onStop: @escaping () -> Void
    ) throws -> (UIWindow, UIHostingController<MobileZoomableImage>, UIScrollView, MobileZoomableImage.Coordinator) {
        let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView: MobileZoomableImage(
                image: UIImage(), reduceMotion: true, onSingleTap: {}, onCloseRequested: {},
                onMotionStart: onStart, onMotionStop: onStop))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        var views = [try XCTUnwrap(host.view)]
        var result: (UIScrollView, MobileZoomableImage.Coordinator)?
        while let view = views.popLast() {
            if let scroll = view as? UIScrollView, let coordinator = scroll.delegate as? MobileZoomableImage.Coordinator
            {
                result = (scroll, coordinator)
                break
            }
            views += view.subviews
        }
        let (scroll, coordinator) = try XCTUnwrap(result, "The production photo adapter must install its scroll view")
        return (window, host, scroll, coordinator)
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
