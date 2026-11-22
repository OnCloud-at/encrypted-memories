import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

@MainActor
func findViewerScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView, scrollView.delegate != nil {
        return scrollView
    }
    for subview in view.subviews {
        if let scrollView = findViewerScrollView(in: subview) {
            return scrollView
        }
    }
    return nil
}

@MainActor
func makeHostedViewer(
    image: UIImage,
    size: CGSize,
    onMotionStart: (() -> Void)? = nil,
    onMotionStop: (() -> Void)? = nil
) throws -> (HostedTestWindow, UIHostingController<MobileZoomableImage>, UIScrollView) {
    let scene = try XCTUnwrap(UIApplication.shared.foregroundWindowScene)
    let hosted = HostedTestWindow(scene: scene)
    let window = hosted.window
    let host = UIHostingController(
        rootView: MobileZoomableImage(
            image: image,
            reduceMotion: true,
            onSingleTap: {},
            onCloseRequested: {},
            onMotionStart: onMotionStart,
            onMotionStop: onMotionStop
        ))
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    host.view.layoutIfNeeded()
    let scrollView: UIScrollView
    do {
        scrollView = try XCTUnwrap(findViewerScrollView(in: host.view))
    } catch {
        hosted.close()
        throw error
    }
    scrollView.layoutIfNeeded()
    return (hosted, host, scrollView)
}
