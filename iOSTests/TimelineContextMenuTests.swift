import GridCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import Testing
import UIKit

@testable import EncryptedMemoriesMobile
@testable import TimelineUIKitFeature

@Suite(.serialized) @MainActor
struct TimelineContextMenuTests {
    @Test func stationaryLiftStillOffersMenuAndDoesNotSelect() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = fixture.host
        let controller = try #require(host.dragOutController)
        let drag = UIDragInteraction(delegate: controller)
        let menu = UIContextMenuInteraction(delegate: controller)
        let session = TestDragSession(point: try fixture.center(of: 0))
        let items = controller.dragInteraction(drag, itemsForBeginning: session)
        #expect(items.count == 1)
        #expect(!controller.sessionActive)
        let location = host.scrollView.convert(session.point, from: host.contentView)
        #expect(controller.contextMenuInteraction(menu, configurationForMenuAtLocation: location) != nil)
        #expect(!host.selectionMode)
        #expect(host.selectedUIDs.isEmpty)

        controller.dragInteraction(drag, sessionWillBegin: session)
        #expect(controller.sessionActive)
        #expect(controller.contextMenuInteraction(menu, configurationForMenuAtLocation: location) == nil)
        controller.dragInteraction(drag, session: session, didEndWith: .cancel)
        #expect(!controller.sessionActive)
    }

    @Test(arguments: [TileContentDisplayMode.squareFillCrop, .aspectFitInsideSquare])
    func menuAndLiftPreviewUsePressedThumbnailAndRoundedAspect(mode: TileContentDisplayMode) async throws {
        let fixture = try await Fixture(mode: mode)
        defer { fixture.close() }
        let host = fixture.host
        let controller = try #require(host.dragOutController)
        let menu = UIContextMenuInteraction(delegate: controller)
        host.selectionMode = true
        host.selectedUIDs = Set(fixture.photos.map(\.uid))
        let pressed = try #require(host.dragOutLiftItems(around: fixture.photos[0]).last)
        let index = try #require(fixture.photos.firstIndex { $0.uid == pressed.uid })
        let point = try fixture.center(of: index)
        let configuration = try #require(
            controller.contextMenuInteraction(
                menu, configurationForMenuAtLocation: host.scrollView.convert(point, from: host.contentView)))
        let preview = try #require(
            controller.contextMenuInteraction(
                menu, configuration: configuration,
                highlightPreviewForItemWithIdentifier: configuration.identifier))
        #expect(
            abs(preview.view.bounds.width / preview.view.bounds.height - (mode == .squareFillCrop ? 1 : 1.5)) < 0.000001
        )
        #expect(preview.parameters.visiblePath != nil)
        #expect(preview.target.container === host.scrollView)
        #expect(preview.target.center == host.scrollView.convert(point, from: host.contentView))
        let imageView = try #require(preview.view as? UIImageView)
        #expect(imageView.image?.cgImage === fixture.feed.memoryCGImage(for: pressed.uid))
        #expect(imageView.layer.cornerRadius > 0)

        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = pressed
        let lift = try #require(
            controller.dragInteraction(
                UIDragInteraction(delegate: controller), previewForLifting: item,
                session: TestDragSession(point: point)))
        #expect(lift.view.bounds.size == preview.view.bounds.size)
        #expect(lift.parameters.visiblePath != nil)
    }

    @Test func menuUsesNativeGroupsAndSourceAnchorsAcrossColumns() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = fixture.host
        let controller = try #require(host.dragOutController)
        host.contextMenuActions = { _ in [.copy, .share, .favorite, .addToAlbum, .information, .trash] }
        let menu = controller.makeActionMenu(items: [fixture.photos[0]])
        let sections = menu.children.compactMap { $0 as? UIMenu }
        #expect(sections.count == 4)
        #expect(sections.first?.preferredElementSize == .medium)
        let actions = sections.flatMap(\.children).compactMap { $0 as? UIAction }
        #expect(
            actions.map { $0.identifier.rawValue } == [
                "copy", "share", "favorite", "addToAlbum", "information", "trash",
            ])
        #expect(actions.last?.attributes.contains(.destructive) == true)
        for index in fixture.photos.indices {
            let point = try fixture.center(of: index)
            let interaction = UIContextMenuInteraction(delegate: controller)
            let configuration = try #require(
                controller.contextMenuInteraction(
                    interaction, configurationForMenuAtLocation: host.scrollView.convert(point, from: host.contentView))
            )
            let preview = try #require(
                controller.contextMenuInteraction(
                    interaction, configuration: configuration,
                    highlightPreviewForItemWithIdentifier: configuration.identifier))
            #expect(preview.target.center == host.scrollView.convert(point, from: host.contentView))
            #expect(configuration.preferredMenuElementOrder == .fixed)
            let content = try #require(controller.makeMenuPreviewController(for: fixture.photos[index]))
            #expect(content.preferredContentSize.width > preview.view.bounds.width)
            #expect(content.preferredContentSize.width == content.preferredContentSize.height)
        }
    }

    @Test func copiedProviderOutlivesItsGridController() async throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        var host: UIKitTimelineGridHostView? = UIKitTimelineGridHostView()
        host?.dragOutProvider = TestOriginalProvider()
        weak let weakController = host?.dragOutController
        let photo = PhotoItem(
            uid: PhotoUID(volumeID: "menu-test", nodeID: "copy"),
            captureTime: Date(), mediaType: "image/jpeg")
        host?.dragOutController?.copyToPasteboard(items: [photo], pasteboard: pasteboard)
        host = nil
        #expect(weakController == nil)
        let provider = try #require(pasteboard.itemProviders.first)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: "public.jpeg") { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #expect(data == Data([1, 2, 3]))
    }

    @Test func contextActionsPresentExplicitItems() {
        let menu = MobileGridContextMenuController()
        let model = MobileLibraryModel()
        let router = MobileViewerRouter()
        let photo = PhotoItem(
            uid: PhotoUID(volumeID: "menu-test", nodeID: "explicit"),
            captureTime: Date(), mediaType: "image/jpeg")
        menu.perform(.information, items: [photo], model: model, router: router)
        #expect(router.presentation?.items == [photo])
        #expect(router.presentation?.showsInfoInitially == true)
        menu.perform(.trash, items: [photo], model: model, router: router)
        #expect(menu.trashItems?.photos == [photo])
        menu.perform(.addToAlbum, items: [photo], model: model, router: router)
        #expect(menu.albumItems?.photos == [photo])
    }

    @Test func informationCanOpenWhileAnotherMutationIsPending() {
        let menu = MobileGridContextMenuController()
        let model = MobileLibraryModel()
        let router = MobileViewerRouter()
        let photo = PhotoItem(
            uid: PhotoUID(volumeID: "menu-test", nodeID: "pending-info"),
            captureTime: Date(), mediaType: "image/jpeg")
        menu.perform(.favorite, items: [photo], model: model, router: router)
        #expect(menu.isBusy)
        menu.perform(.information, items: [photo], model: model, router: router)
        #expect(router.presentation?.items == [photo])
        #expect(router.presentation?.showsInfoInitially == true)
    }

    @Test func disabledProviderCannotOfferMenu() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let controller = try #require(fixture.host.dragOutController)
        fixture.host.dragOutProvider = nil
        #expect(
            controller.contextMenuInteraction(
                UIContextMenuInteraction(delegate: controller),
                configurationForMenuAtLocation: .zero) == nil)
    }

    @MainActor private final class Fixture {
        let window: UIWindow
        let host = UIKitTimelineGridHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let feed: UIKitThumbnailFeed
        let photos = (0..<3).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "menu-test", nodeID: "photo-\($0)"),
                captureTime: Date(), mediaType: "image/jpeg")
        }

        init(mode: TileContentDisplayMode = .squareFillCrop) async throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            let cache = ThumbnailCache(rootDirectory: root)
            feed = UIKitThumbnailFeed(cache: cache, loader: EmptyThumbnailLoader())
            let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 60)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
            }
            let data = try #require(bitmap.jpegData(compressionQuality: 1))
            for photo in photos { await cache.store(data, for: photo.uid) }
            _ = await feed.warmDecoded(photos.map(\.uid))
            host.configure(
                items: photos, thumbnailFeed: feed, level: 0,
                fillOrder: .topLeading, displayMode: mode, selectionMode: false)
            host.dragOutProvider = TestOriginalProvider()
            let presenter = UIViewController()
            window.rootViewController = presenter
            presenter.view.addSubview(host)
            window.isHidden = false
        }

        func close() {
            host.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
        }

        func center(of index: Int) throws -> CGPoint {
            let context = try #require(host.currentGridContext())
            let slot = try #require(
                context.engine.slotRect(
                    flatIndex: index, level: context.level, width: host.bounds.width,
                    columnPhase: host.committedPhase))
            return CGPoint(x: slot.midX, y: slot.midY)
        }
    }
}

private struct EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        .delivered
    }
}

private struct TestOriginalProvider: OriginalFileProvider {
    func writeOriginal(
        for uid: PhotoUID, to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        try Data([1, 2, 3]).write(to: destination)
        onProgress(1)
    }
}

@MainActor private final class TestDragSession: NSObject, UIDragSession {
    let point: CGPoint
    init(point: CGPoint) { self.point = point }
    var items: [UIDragItem] = []
    var localContext: Any?
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}
