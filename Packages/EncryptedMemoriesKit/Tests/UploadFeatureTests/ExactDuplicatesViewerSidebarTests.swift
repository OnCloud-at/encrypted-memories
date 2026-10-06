#if os(macOS)
    import AppKit
    import MediaByteCache
    import MediaCache
    import Observation
    import PhotoViewerFeature
    import PhotosCore
    import SwiftUI
    import XCTest

    /// The Mac viewer with a filmstrip, of a group of duplicates and of a burst, in a window laid out like the library
    /// window: the split-view sidebar, the viewer beside it that moves with the sidebar, and the window toolbar with
    /// Keep This Copy and Merge. Showing or hiding the sidebar, also at other window widths, must finish its layout.
    /// A layout that never finishes makes AppKit raise an exception after more Update Constraints passes than the
    /// window has views, which stops the app.
    @MainActor
    final class ExactDuplicatesViewerSidebarTests: XCTestCase {
        func testShowingAndHidingTheSidebarBesideTheViewerOfAGroupFinishesItsLayout() async throws {
            let items = Self.photos(tags: [], burstMembers: [])
            let viewer = PhotoViewerModel(items: items, index: 1, feed: try makeFeed(), media: ColorMedia())
            defer { viewer.stop() }
            try await assertTheSidebarTogglesBeside(viewer, itemFilmstripLabel: "Identical copies")
        }

        func testShowingAndHidingTheSidebarBesideTheViewerOfABurstFinishesItsLayout() async throws {
            let items = Self.photos(tags: [.bursts], burstMembers: ["photo-0", "photo-1", "photo-2"])
            let viewer = PhotoViewerModel(
                items: items, index: 1, feed: try makeFeed(), media: ColorMedia(),
                burstProvider: BurstMembers(items: items))
            defer { viewer.stop() }
            try await assertTheSidebarTogglesBeside(viewer, itemFilmstripLabel: nil)
        }

        private func assertTheSidebarTogglesBeside(
            _ viewer: PhotoViewerModel, itemFilmstripLabel: String?
        ) async throws {
            // The minimum width of the viewer must not follow the width that the viewer measured. A minimum that
            // follows it lets the viewer shrink only a little in each layout pass, and the sidebar toggle below
            // would then stop the test process instead of failing this test.
            let minimumWidths = try await minimumWidths(of: viewer, itemFilmstripLabel: itemFilmstripLabel)
            XCTAssertEqual(minimumWidths.count, 2)
            guard let first = minimumWidths.first, minimumWidths.allSatisfy({ $0 == first }), first < 320 else {
                XCTFail("The minimum width of the viewer follows its measured width: \(minimumWidths)")
                return
            }

            let sidebar = SidebarState()
            let controller = NSHostingController(
                rootView: SidebarWindowRoute(sidebar: sidebar, viewer: viewer, itemFilmstripLabel: itemFilmstripLabel))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1_080, height: 720))
            Self.showUnseen(window)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(1_000))
            XCTAssertTrue(viewer.hasBurstFilmstrip || itemFilmstripLabel != nil)

            for width in [1_080.0, 900, 1_300, 1_080] {
                window.setContentSize(NSSize(width: width, height: 720))
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebar.toggle() }
                    try await Task.sleep(for: .milliseconds(600))
                }
            }
            withAnimation(.easeInOut(duration: 0.22)) { sidebar.toggle() }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(sidebar.visibility, .detailOnly)

            // The filmstrip panel keeps its look: 20 points from each side of the viewer, its photos 12 points inside.
            controller.view.layoutSubtreeIfNeeded()
            let strip = try XCTUnwrap(Self.filmstrip(in: controller.view), "no filmstrip")
            let frame = strip.convert(strip.bounds, to: nil)
            XCTAssertEqual(frame.minX, 32, accuracy: 1)
            XCTAssertEqual(frame.width, 1_080 - 64, accuracy: 1)
        }

        /// The minimum width of the viewer alone, after it laid out at 1,080 and at 1,300 points.
        private func minimumWidths(
            of viewer: PhotoViewerModel, itemFilmstripLabel: String?
        ) async throws -> [CGFloat] {
            let controller = NSHostingController(
                rootView: PhotoViewerView(model: viewer, onClose: {}, itemFilmstripLabel: itemFilmstripLabel))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            Self.showUnseen(window)
            defer { window.orderOut(nil) }
            var widths: [CGFloat] = []
            for width in [1_080.0, 1_300] {
                window.setContentSize(NSSize(width: width, height: 720))
                try await Task.sleep(for: .milliseconds(800))
                controller.view.layoutSubtreeIfNeeded()
                widths.append(controller.sizeThatFits(in: NSSize(width: 0, height: 720)).width)
            }
            return widths
        }

        /// Puts `window` on screen, so AppKit lays it out like the library window, but invisible and without taking
        /// clicks: the test runs while the person works on this Mac.
        private static func showUnseen(_ window: NSWindow) {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        }

        private func makeFeed() throws -> ThumbnailFeed {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("duplicates-viewer-sidebar-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return ThumbnailFeed(
                cache: ThumbnailCache(namespace: "duplicates-viewer-sidebar-\(UUID().uuidString)", rootDirectory: root),
                loader: ColorThumbnails())
        }

        private static func photos(tags: Set<PhotoTag>, burstMembers: [String]) -> [PhotoItem] {
            (0..<3).map {
                PhotoItem(
                    uid: PhotoUID(volumeID: "v", nodeID: "photo-\($0)"),
                    captureTime: Date(timeIntervalSince1970: 1_749_456_000), mediaType: "image/png", tags: tags,
                    burstMemberIDs: burstMembers)
            }
        }

        /// The scroll view of the native filmstrip collection.
        private static func filmstrip(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSCollectionView { return scroll }
            for subview in view.subviews {
                if let found = filmstrip(in: subview) { return found }
            }
            return nil
        }
    }

    /// The members of one burst, as the library knows them.
    struct BurstMembers: BurstGroupProvider {
        let items: [PhotoItem]
        func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { items }
    }

    @Observable @MainActor
    private final class SidebarState {
        var visibility: NavigationSplitViewVisibility = .all

        func toggle() { visibility = visibility == .detailOnly ? .all : .detailOnly }
    }

    /// The library window of the Mac app around the viewer: the viewer is a sibling of the split view and moves
    /// beside the floating sidebar with the sidebar's curve.
    private struct SidebarWindowRoute: View {
        @Bindable var sidebar: SidebarState
        let viewer: PhotoViewerModel
        let itemFilmstripLabel: String?
        private static let sidebarWidth: CGFloat = 220

        var body: some View {
            ZStack {
                NavigationSplitView(columnVisibility: $sidebar.visibility) {
                    List { Text(verbatim: "Library") }
                        .navigationSplitViewColumnWidth(Self.sidebarWidth)
                } detail: {
                    Color.clear
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(verbatim: "Vienna").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(verbatim: "June 9, 2025").font(.system(size: 11)).lineLimit(1)
                        }
                        .fixedSize()
                        .padding(.horizontal, 16)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                        } label: {
                            Label("Keep This Copy", systemImage: "checkmark.circle")
                        }
                        Button {
                        } label: {
                            Label("Merge", systemImage: "arrow.triangle.merge")
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        Button {
                        } label: {
                            Label("Favorite", systemImage: "heart")
                        }
                    }
                }
                PhotoViewerView(model: viewer, onClose: {}, itemFilmstripLabel: itemFilmstripLabel)
                    .padding(.leading, sidebar.visibility == .detailOnly ? 0 : Self.sidebarWidth)
                    .animation(.easeInOut(duration: 0.22), value: sidebar.visibility)
            }
        }
    }
#endif
