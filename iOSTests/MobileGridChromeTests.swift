import DesignSystemCore
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

/// Exercise the production grid and chrome policies in a populated native navigation/tab hierarchy.
/// Attachments support OS visual comparison; they are not pixel-equality or physical-device acceptance.
final class MobileGridChromeTests: XCTestCase {
    @MainActor func testSelectionChromePreservesGridAndFloatingNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ThumbnailCache(rootDirectory: cacheDirectory)
        let feed = UIKitThumbnailFeed(cache: cache, loader: ChromeProbeLoader())
        let items = (0..<90).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "chrome-probe", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg")
        }
        for (index, item) in items.enumerated() {
            let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
                UIColor(hue: CGFloat(index % 8) / 8, saturation: 0.55, brightness: 0.75, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                for stripe in 0..<12 {
                    UIColor.white.withAlphaComponent(stripe.isMultiple(of: 2) ? 0.5 : 0.05).setFill()
                    context.fill(CGRect(x: 0, y: stripe * 20, width: 240, height: 10))
                }
            }
            await cache.store(try XCTUnwrap(bitmap.jpegData(compressionQuality: 1)), for: item.uid)
        }
        _ = await feed.warmDecoded(items.map(\.uid))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let state = ChromeProbeState()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(
            rootView: ChromeProbeShell(items: items, feed: feed, state: state))
        window.makeKeyAndVisible()
        defer {
            descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }.forEach { $0.setActive(false) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var originalGrid: UIKitTimelineGridHostView?
        for (step, isSelecting) in [false, false, false, true, false].enumerated() {
            state.isSelecting = isSelecting
            state.showsLoadingCover = step == 0
            state.showsActivity = step < 2
            try await Task.sleep(for: .seconds(2))
            let grids = descendants(window).compactMap { $0 as? UIKitTimelineGridHostView }
            XCTAssertEqual(grids.count, 1)
            let grid = try XCTUnwrap(grids.first)
            if let originalGrid {
                XCTAssertTrue(grid === originalGrid, "Selection must not remount the photo grid")
            } else {
                originalGrid = grid
                grid.scrollView.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
            }
            XCTAssertEqual(grid.scrollView.topEdgeEffect.style, .soft)
            try await Task.sleep(for: .seconds(1))
            let tabBar = try XCTUnwrap(descendants(window).compactMap { $0 as? UITabBar }.first)
            XCTAssertEqual(tabBar.isHidden, isSelecting, "Selection actions and root tabs must alternate")
            let navigationBar = try XCTUnwrap(descendants(window).compactMap { $0 as? UINavigationBar }.first)
            XCTAssertFalse(navigationBar.isHidden)
            let name = "chrome-iOS-\(UIDevice.current.systemVersion)-step-\(step)-selecting-\(isSelecting)"
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable private final class ChromeProbeState {
    var isSelecting = false
    var showsLoadingCover = true
    var showsActivity = true
}

private struct ChromeProbeShell: View {
    @Namespace private var activityTransition
    let items: [PhotoItem]
    let feed: UIKitThumbnailFeed
    let state: ChromeProbeState

    var body: some View {
        TabView {
            Tab("Mediathek", systemImage: "photo.on.rectangle") {
                NavigationStack {
                    UIKitTimelineGrid(
                        items: items, thumbnailFeed: feed, level: 0, fillOrder: .topLeading,
                        selectionMode: state.isSelecting
                    )
                    .ignoresSafeArea()
                    .overlay(alignment: .top) { TopFrostBar(height: 106) }
                    .mobileNavigationTitle("Mediathek")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItem(placement: .topBarTrailing) { Button("Auswählen") {} }
                        ToolbarItem(placement: .bottomBar) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Spacer(minLength: 28)
                                Text("Auswahl")
                                Spacer(minLength: 28)
                                Image(systemName: "trash")
                            }
                            .frame(minWidth: 300)
                            .opacity(state.isSelecting ? 1 : 0)
                            .allowsHitTesting(state.isSelecting)
                        }
                        .sharedBackgroundVisibility(state.isSelecting ? .automatic : .hidden)
                    }
                    .mobileSelectionBars(isSelecting: state.isSelecting)
                }
                .overlay {
                    LibraryActivityBannerOverlay(
                        isPresented: state.showsActivity,
                        message: "Mediathek wird geladen …",
                        bottomPadding: state.isSelecting ? 84 : 20
                    )
                }
            }
            Tab("Sammlungen", systemImage: "rectangle.stack") { Text("Sammlungen") }
            Tab("Karte", systemImage: "map") { Text("Karte") }
            Tab(role: .search) { NavigationStack { Text("Suche").searchable(text: .constant("")) } }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabViewStyle(.tabBarOnly)
        .mobileTabBarBackgroundPolicy()
        .tint(.purple)
        .overlay {
            MobileLibraryLoadingView(
                isPresented: state.showsLoadingCover,
                activityMessage: "Mediathek wird geladen …",
                activityState: .working
            )
        }
        .libraryActivityTransition(namespace: activityTransition, loadingCoverPresented: state.showsLoadingCover)
    }
}

private struct ChromeProbeLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}
