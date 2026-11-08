import PhotoViewerCore
import SwiftUI
import UIKit
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

    func testPanPinchAndPageChangeStopWithoutDuplicateStops() throws {
        var calls: [String] = []
        let (window, host, scroll, coordinator) = try makeMobileHoldHost(
            onStart: { calls.append("start") }, onStop: { calls.append("stop") })
        defer { window.isHidden = true }
        let injected = InjectedMotionPress()
        for pinch in [false, true] {
            injected.state = .began
            coordinator.handleLongPress(injected)
            if pinch {
                coordinator.scrollViewWillBeginZooming(scroll, with: nil)
            } else {
                coordinator.scrollViewWillBeginDragging(scroll)
            }
            XCTAssertEqual(calls.count, pinch ? 4 : 2)
            injected.state = .ended
            coordinator.handleLongPress(injected)
        }
        injected.state = .began
        coordinator.handleLongPress(injected)
        var page = host.rootView
        page.isCurrent = false
        host.rootView = page
        host.view.layoutIfNeeded()
        XCTAssertEqual(calls, ["start", "stop", "start", "stop", "start", "stop"])
        XCTAssertFalse(try XCTUnwrap(coordinator.motionPress).isEnabled)
    }

    func testRemovingMotionCallbacksStopsBeforeTheirReplacement() throws {
        var calls: [String] = []
        let (window, host, _, coordinator) = try makeMobileHoldHost(
            onStart: { calls.append("start") }, onStop: { calls.append("stop") })
        defer { window.isHidden = true }
        let injected = InjectedMotionPress()
        injected.state = .began
        coordinator.handleLongPress(injected)
        var page = host.rootView
        page.onMotionStart = nil
        page.onMotionStop = nil
        host.rootView = page
        host.view.layoutIfNeeded()
        XCTAssertEqual(calls, ["start", "stop"])
        XCTAssertFalse(try XCTUnwrap(coordinator.motionPress).isEnabled)
    }

    func testTeardownStopsTheActiveHold() throws {
        var calls: [String] = []
        let (window, _, scroll, coordinator) = try makeMobileHoldHost(
            onStart: { calls.append("start") }, onStop: { calls.append("stop") })
        defer { window.isHidden = true }
        let injected = InjectedMotionPress()
        injected.state = .began
        coordinator.handleLongPress(injected)
        MobileZoomableImage.dismantleUIView(scroll, coordinator: coordinator)
        XCTAssertEqual(calls, ["start", "stop"])
        injected.state = .ended
        coordinator.handleLongPress(injected)
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
