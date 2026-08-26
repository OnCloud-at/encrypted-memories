import Foundation
import MediaByteCache
import MediaCache
import PhotosCore
import XCTest

@testable import PhotoViewerFeature

final class BurstFilmstripArchitectureTests: XCTestCase {
    func testViewerFullImageCacheIsCostBounded() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhotoViewerFeatureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // EncryptedMemoriesKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo
        let model = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(model.contains("private static let fullImageCacheByteLimit"))
        XCTAssertTrue(model.contains("c.totalCostLimit = fullImageCacheByteLimit"))
        XCTAssertTrue(model.contains("CachedSharpImage(image: image, pixelSize: pixelSize)"))
        XCTAssertTrue(model.contains("cost: decodedImageCost(image)"))
        XCTAssertFalse(model.contains("countLimit = 40"), "viewer full-res cache must not be count-only")
        XCTAssertFalse(
            model.contains("Self.fullImageCache.setObject(full"), "full-res inserts must include decoded byte cost")
    }

    func testViewerPreviewCacheReadAndDecodeStayOffMainActor() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhotoViewerFeatureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // EncryptedMemoriesKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo
        let model = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"),
            encoding: .utf8
        )

        guard let start = model.range(of: "private func loadPreviewImage(_ uid: PhotoUID) async -> NSImage?"),
            let end = model.range(of: "    // MARK: - Media resolution", range: start.upperBound..<model.endIndex)
        else {
            XCTFail("expected loadPreviewImage before media resolution")
            return
        }
        let body = String(model[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(body.contains("cache.diskData(for: uid).flatMap { Self.decodePreviewImage($0) }"))
        XCTAssertTrue(body.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(
            model.contains("NSImage(data: previewData)"), "preview decode must not run in the MainActor load task")
        XCTAssertFalse(
            body.contains("if let cache = previewCache, let data = cache.diskData"),
            "preview cache disk read/decrypt must not run synchronously on the MainActor")
    }

    func testBurstFilmstripUsesSharedViewerModelAndDoesNotOwnBackendLoading() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhotoViewerFeatureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // EncryptedMemoriesKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo

        let model = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(model.contains("private let burstProvider: BurstGroupProvider?"))
        XCTAssertTrue(model.contains("public func selectBurstIndex"))
        XCTAssertTrue(model.contains("public func nextInContext"))
        XCTAssertTrue(model.contains("public func previousInContext"))
        XCTAssertTrue(model.contains("private func loadDisplayedItem(_ item: PhotoItem)"))
        XCTAssertTrue(model.contains("public var exportItemsForDownload"))

        let view = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"),
            encoding: .utf8
        )
        let compactView = view.filter { !$0.isWhitespace }
        XCTAssertTrue(view.contains("BurstFilmstripView("))
        XCTAssertTrue(view.contains("model.selectBurstIndex($0)"))
        XCTAssertTrue(view.contains("model.canNavigatePrevious"))
        XCTAssertTrue(view.contains("model.canNavigateNext"))
        XCTAssertTrue(compactView.contains("burstFilmstripItemSide(panelWidth:width"))
        XCTAssertTrue(compactView.contains("burstFilmstripNeedsScroller(panelWidth:width"))
        XCTAssertFalse(
            view.contains("min(max(contentSize.width - 40, 320), 1240)"),
            "The series filmstrip must scale with the viewer width, not stay capped to a narrow fixed panel")
        XCTAssertFalse(
            view.contains("burstGroup(containing:"), "The SwiftUI/AppKit view must not call the backend directly")

        let filmstrip = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotoViewerFeature/BurstFilmstripView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(filmstrip.contains("let itemSide: CGFloat"))
        XCTAssertTrue(filmstrip.contains("scrollView.contentView.drawsBackground = false"))
        XCTAssertTrue(filmstrip.contains("scrollView.hasHorizontalScroller = showsHorizontalScroller"))
        XCTAssertTrue(filmstrip.contains("layout.itemSize = NSSize(width: itemSide, height: itemSide)"))
        XCTAssertTrue(filmstrip.contains("BurstFilmstripUpdatePolicy.resolve"))
        XCTAssertFalse(
            filmstrip.contains("collectionView.reloadData()\n        context.coordinator.selectCurrent()"),
            "steady SwiftUI updates must not reload and reselect the entire filmstrip")

        let mainView = try String(
            contentsOf: repo.appendingPathComponent("App/Views/MainView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(mainView.contains("makeExportRequest(for: items"))
        XCTAssertTrue(mainView.contains("backend.burstGroup(containing: item.uid)"))
        XCTAssertTrue(mainView.contains("export.series_zip_suffix"))
        XCTAssertTrue(mainView.contains("downloadViewerSelection(viewerModel)"))
    }

    func testMobileViewerUsesSharedBurstStateAndOverlayFilmstrip() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mobile = try String(
            contentsOf: repo.appendingPathComponent("iOSApp/MobilePhotoViewer.swift"),
            encoding: .utf8
        )
        let viewerSupport = try String(
            contentsOf: repo.appendingPathComponent("iOSApp/MobileViewerSupport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(mobile.contains("@State private var burstSelection = BurstSelectionModel()"))
        XCTAssertTrue(mobile.contains("burstSelection.seedKnownGroup"))
        XCTAssertTrue(mobile.contains("provider.burstGroup(containing: item.uid)"))
        XCTAssertTrue(mobile.contains("MobileBurstFilmstrip("))
        XCTAssertTrue(viewerSupport.contains(".opacity(showsChrome ? 1 : 0)"))
        XCTAssertTrue(viewerSupport.contains(".allowsHitTesting(showsChrome)"))
        XCTAssertFalse(
            mobile.contains(".transition(.move(edge: .bottom).combined(with: .opacity))"),
            "the mounted chrome must animate without replacing its overlay tree")
        XCTAssertFalse(
            mobile.contains("safeAreaInset"),
            "the mobile filmstrip must overlay media instead of shifting fitted viewer geometry")
    }

    @MainActor
    func testViewerSeedsKnownBurstMembersBeforeProviderResponse() async {
        let root = Self.cacheRoot("burst-filmstrip")
        let items = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            makeItem("b", burstMembers: ["a", "b", "c"]),
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: items,
            index: 1,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-filmstrip-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: EmptyBurstProvider()
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.burstItems.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(model.burstIndex, 1)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip, "An empty provider response must not clear a known timeline burst group")

        model.selectBurstIndex(2)
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.exportItemsForDownload.map(\.uid.nodeID), ["a", "b", "c"])
    }

    @MainActor
    func testContextualNavigationPrefersFilmstripThenFallsThroughToLibrary() async {
        let root = Self.cacheRoot("burst-navigation")
        let title = makeItem("b", burstMembers: ["a", "b", "c"])
        let nextLibraryItem = makeItem("d", burstMembers: [])
        let burst = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            title,
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: [title, nextLibraryItem],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-navigation-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider(),
            burstProvider: StaticBurstProvider(items: burst)
        )
        model.start()
        defer { model.stop() }

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.current.uid.nodeID, "b")
        XCTAssertEqual(model.index, 0)

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.index, 0, "Right arrow should stay inside the series before changing library item")

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "d")
        XCTAssertEqual(model.index, 1, "At the series edge, right arrow should fall through to the next library item")
    }

    @MainActor
    func testUIDPageSelectionUsesFullIdentityAndResetsNestedBurstSelection() async {
        let root = Self.cacheRoot("uid-page-selection")
        let first = makeItem("same", burstMembers: [])
        let second = PhotoItem(
            uid: PhotoUID(volumeID: "other-volume", nodeID: "same"),
            captureTime: Date(timeIntervalSince1970: 2),
            mediaType: "image/jpeg"
        )
        let model = PhotoViewerModel(
            items: [first, second],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "uid-page-selection-\(UUID().uuidString)", rootDirectory: root),
                loader: EmptyThumbnailLoader()
            ),
            media: FailingMediaProvider()
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.selectPage(uid: second.uid))
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.current.uid, second.uid)
        XCTAssertFalse(model.selectPage(uid: PhotoUID(volumeID: "missing", nodeID: "same")))
        XCTAssertEqual(model.index, 1)
    }

    private func makeItem(_ id: String, burstMembers: [String]) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: Double(id.unicodeScalars.first?.value ?? 0)),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: burstMembers
        )
    }

    private static func cacheRoot(_ prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult { .delivered }
}

private struct FailingMediaProvider: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw TestError.unavailable }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw TestError.unavailable
    }
}

private struct EmptyBurstProvider: BurstGroupProvider {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
}

private struct StaticBurstProvider: BurstGroupProvider {
    let items: [PhotoItem]
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { items }
}

private enum TestError: Error {
    case unavailable
}
