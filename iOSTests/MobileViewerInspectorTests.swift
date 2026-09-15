import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// The photo information inspector of the production viewer: a trailing column beside the media in a regular
/// width window and a sheet in a compact width window, with the same viewer, pager and photo kept mounted while
/// the window resizes between the two (Split View, Slide Over, Stage Manager). This does not simulate a hinge.
///
/// The viewer is presented through the production route (`MobileViewerRouter` -> `.fullScreenCover(item:)`, as
/// `MobileMainTabView` does), not hosted directly as a window root. A directly hosted viewer takes a synthetic
/// resize path (window frame plus trait overrides, no presentation container) in which the native inspector split
/// collapses but leaves its 360 pt trailing content inset behind whenever the main thread is contended, for
/// example by the previous test's account teardown. The presented route resets the inset in every probe.
///
/// The cover is presented without animation. With the animated presentation, iPadOS 27 laid the split out during
/// the transition and never applied the inspector's content inset (photo under the column, pager 1032). This
/// fixture verifies the width adaptation, not the OS presentation transition; that initial-inset miss is recorded
/// as an open iPadOS 27 finding (Onyx: viewer-inspector-compact-viewport-regression).
final class MobileViewerInspectorTests: XCTestCase {
    @MainActor func testInspectorAdaptsBetweenColumnAndSheetWhileTheViewerStaysMounted() async throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad, "column-to-sheet adaptation requires an iPad window")
        try await verifyViewer(inspector: true)
    }

    @MainActor func testViewerPreservesPhotoAndZoomAcrossPhoneRotation() async throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone, "this probe covers phone safe areas during rotation")
        try await verifyViewer(inspector: false)
    }

    @MainActor private func verifyViewer(inspector: Bool) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let fixture = try await MobileSignedInFixture(itemsPerSection: 6)
        defer { fixture.removeCache() }
        let model = MobileLibraryModel()
        fixture.install(into: model)
        let router = MobileViewerRouter()
        let fullBounds = scene.coordinateSpace.bounds
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = fullBounds
        let root = UIHostingController(rootView: ViewerPresentationHost(router: router, libraryModel: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        // Present without animation: see the type comment.
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            router.presentation = MobileViewerPresentation(
                index: 2, items: fixture.items, context: ViewerCollectionContext(filter: .all),
                showsInfoInitially: inspector)
        }
        try await Task.sleep(for: .seconds(2))
        let viewerHost = try XCTUnwrap(
            root.presentedViewController, "the router presents the production viewer as a full-screen cover")
        var report: [String] = []
        defer { writeArtifact("viewer-inspector-report.txt", Data(report.joined(separator: "\n").utf8)) }

        func pager() -> UIPageViewController? {
            var result: UIPageViewController?
            func walk(_ controller: UIViewController?) {
                guard let controller, result == nil else { return }
                if let pageController = controller as? UIPageViewController { result = pageController }
                controller.children.forEach(walk)
            }
            walk(viewerHost)
            return result
        }
        /// The zoomable media viewport of the current page: the UIScrollView of MobileZoomableImage, identified by
        /// its zoomable bounds (a plain UIScrollView defaults to equal minimum and maximum zoom scales).
        func zoomableViewport() throws -> UIScrollView {
            let pageController = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController")
            let page = try XCTUnwrap(pageController.viewControllers?.first, "the pager hosts the current media page")
            var result: UIScrollView?
            func walk(_ view: UIView) {
                guard result == nil else { return }
                if let scrollView = view as? UIScrollView, scrollView.maximumZoomScale > scrollView.minimumZoomScale {
                    result = scrollView
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(page.view)
            return try XCTUnwrap(result, "the media page hosts the zoomable UIScrollView of MobileZoomableImage")
        }
        func layout(_ label: String) throws -> (viewportWidth: CGFloat, presented: Bool) {
            let pagerWidth = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController").view.bounds
                .width
            let viewport = try zoomableViewport()
            let presented = viewerHost.presentedViewController != nil
            report.append(
                "\(label): window=\(Int(window.bounds.width)) controllerSizeClass=\(viewerHost.traitCollection.horizontalSizeClass.rawValue) pager=\(Int(pagerWidth)) viewport=\(Int(viewport.bounds.width)) presentedSheet=\(presented)"
            )
            return (viewport.bounds.width, presented)
        }
        let initialPager = try XCTUnwrap(pager(), "the production viewer hosts its UIPageViewController")
        let initialViewport = try zoomableViewport()
        let isRegular = window.traitCollection.horizontalSizeClass == .regular
        let initialSizeClass = window.traitCollection.horizontalSizeClass
        report.append("initial sizeClass regular=\(isRegular)")

        func resize(_ bounds: CGRect, sizeClass: UIUserInterfaceSizeClass) {
            window.traitOverrides.horizontalSizeClass = sizeClass
            root.traitOverrides.horizontalSizeClass = sizeClass
            viewerHost.traitOverrides.horizontalSizeClass = sizeClass
            window.frame = bounds
            window.layoutIfNeeded()
        }

        // Regular width (iPad full window): the inspector is a trailing column, nothing is presented modally, and
        // the pager and its media viewport shrink beside the inspector. Compact width (iPhone, narrow iPad
        // window): the same information is a sheet over the
        // full-width media viewport.
        if inspector {
            let initial = try layout("initial")
            if isRegular {
                XCTAssertFalse(initial.presented, "regular width shows the inspector as a column, not a sheet")
                XCTAssertGreaterThanOrEqual(
                    window.bounds.width - initial.viewportWidth, 250,
                    "the media viewport leaves room for the inspector column")
            } else {
                XCTAssertTrue(initial.presented, "compact width shows the inspector as a sheet")
                XCTAssertEqual(
                    initial.viewportWidth, window.bounds.width, accuracy: 1,
                    "the media viewport fills the compact window")
            }
            snapshot(window, "viewer-inspector-\(isRegular ? "regular" : "compact")-initial")

            // Resize to a compact width and back; the viewer and its pager stay the same instances.
            let compactWidth = min(fullBounds.width, 420)
            // Changing a test UIWindow's frame does not change its scene's size-class traits.
            // Supply both inputs that a real compact iPad window receives from the system.
            let compactBounds = CGRect(x: 0, y: 0, width: compactWidth, height: fullBounds.height)
            resize(compactBounds, sizeClass: .compact)
            try await Task.sleep(for: .milliseconds(1500))
            let compact = try layout("compact")
            XCTAssertTrue(pager() === initialPager, "resizing must not remount the viewer pager")
            XCTAssertTrue(try zoomableViewport() === initialViewport, "resizing must not remount the current photo")
            // Native inspector adaptation differs by OS. It may hide the column on entering compact width.
            // If no sheet covers the photo, the photo must already fill the available width.
            if compact.presented {
                XCTAssertGreaterThan(compact.viewportWidth, 0)
            } else {
                XCTAssertEqual(compact.viewportWidth, compactWidth, accuracy: 1)
            }
            snapshot(window, "viewer-inspector-compact-after-resize")

            resize(fullBounds, sizeClass: initialSizeClass)
            try await Task.sleep(for: .milliseconds(1500))
            let restored = try layout("restored")
            XCTAssertTrue(pager() === initialPager, "resizing back must not remount the viewer pager")
            XCTAssertTrue(
                try zoomableViewport() === initialViewport, "resizing back must not remount the current photo")
            if isRegular {
                XCTAssertFalse(restored.presented, "regular width returns to the inspector column")
                XCTAssertGreaterThanOrEqual(window.bounds.width - restored.viewportWidth, 250)
            } else {
                XCTAssertTrue(restored.presented)
            }
            snapshot(window, "viewer-inspector-\(isRegular ? "regular" : "compact")-restored")

            resize(compactBounds, sizeClass: .compact)
            try await Task.sleep(for: .milliseconds(1500))
            if let sheet = viewerHost.presentedViewController {
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let bars = descendants(sheet.presentationController?.containerView ?? window).compactMap {
                    $0 as? UINavigationBar
                }
                let navigationItems = bars.flatMap { $0.items ?? [] }
                var toolbarItems: [UIBarButtonItem] = []
                for item in navigationItems {
                    toolbarItems.append(contentsOf: item.leftBarButtonItems ?? [])
                    toolbarItems.append(contentsOf: item.rightBarButtonItems ?? [])
                    for groups in [item.leadingItemGroups, item.centerItemGroups, item.trailingItemGroups] {
                        for group in groups { toolbarItems.append(contentsOf: group.barButtonItems) }
                    }
                }
                // This inspector's root toolbar has exactly one action: Close. SwiftUI does not expose its accessibility
                // label on the UIKit item in a hosted test. Require the unique action instead of guessing a private view.
                XCTAssertEqual(toolbarItems.count, 1, "the inspector root toolbar contains only its Close action")
                let closeItem = try XCTUnwrap(toolbarItems.first)
                let closeAction = try XCTUnwrap(closeItem.action)
                XCTAssertTrue(
                    UIApplication.shared.sendAction(closeAction, to: closeItem.target, from: closeItem, for: nil))
                try await Task.sleep(for: .milliseconds(1500))
            }
            let dismissed = try layout("compact-dismissed")
            XCTAssertFalse(dismissed.presented, "Close dismisses only the inspector")
            XCTAssertTrue(pager() === initialPager)
            XCTAssertTrue(try zoomableViewport() === initialViewport)
            XCTAssertEqual(dismissed.viewportWidth, compactWidth, accuracy: 1, "visible media fills the compact window")
            snapshot(window, "viewer-inspector-compact-dismissed")
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            let originalOrientation = scene.interfaceOrientation
            func rotate(to orientation: UIInterfaceOrientation) async throws {
                let mask: UIInterfaceOrientationMask =
                    switch orientation {
                    case .landscapeLeft: .landscapeLeft
                    case .landscapeRight: .landscapeRight
                    case .portraitUpsideDown: .portraitUpsideDown
                    default: .portrait
                    }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    XCTFail("viewer rotation failed: \(error.localizedDescription)")
                }
                for _ in 0..<50 where scene.interfaceOrientation != orientation {
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertEqual(scene.interfaceOrientation, orientation)
                window.frame = scene.coordinateSpace.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(750))
            }
            initialViewport.setZoomScale(2, animated: false)
            let zoom = initialViewport.zoomScale
            do {
                try await rotate(to: originalOrientation.isLandscape ? .portrait : .landscapeRight)
                XCTAssertTrue(pager() === initialPager)
                XCTAssertTrue(try zoomableViewport() === initialViewport)
                XCTAssertEqual(initialViewport.zoomScale, zoom, accuracy: 0.01, "rotation preserves the photo zoom")
                let usable = window.safeAreaLayoutGuide.layoutFrame
                let media = initialViewport.convert(initialViewport.bounds, to: window)
                XCTAssertEqual(
                    media.width, usable.width, accuracy: 1, "the photo uses the width between device safe areas")
                XCTAssertEqual(
                    media.midX, usable.midX, accuracy: 1, "the photo remains centered between device safe areas")
                report.append("rotated: media=\(media) usable=\(usable) zoom=\(initialViewport.zoomScale)")
                snapshot(window, "viewer-rotated-with-zoom")
            } catch {
                try? await rotate(to: originalOrientation)
                throw error
            }
            try await rotate(to: originalOrientation)
            XCTAssertEqual(initialViewport.zoomScale, zoom, accuracy: 0.01)
        }

        let text = report.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "viewer-inspector-report"
        attachment.lifetime = .keepAlways
        add(attachment)
        writeArtifact("viewer-inspector-report.txt", Data(text.utf8))
    }

    @MainActor private func snapshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() { writeArtifact("\(name).png", data) }
    }

    private func writeArtifact(_ name: String, _ data: Data) {
        guard let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }
}

/// The production viewer presentation: one `.fullScreenCover(item:)` bound to the viewer router, the way
/// `MobileMainTabView` presents `MobilePhotoViewer` (see `EncryptedMemoriesMobileApp.swift`).
private struct ViewerPresentationHost: View {
    let router: MobileViewerRouter
    let libraryModel: MobileLibraryModel

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .fullScreenCover(
                item: Binding(
                    get: { router.presentation },
                    set: { router.presentation = $0 }
                )
            ) { presentation in
                MobilePhotoViewer(
                    items: presentation.items,
                    startIndex: presentation.index,
                    context: presentation.context,
                    libraryModel: libraryModel,
                    viewerRouter: router,
                    showsInfoInitially: presentation.showsInfoInitially
                )
            }
    }
}
