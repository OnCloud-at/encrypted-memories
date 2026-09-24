import Foundation
import MediaByteCache
import MediaCache
import PhotoViewerCore
import PhotosCore
import XCTest

@testable import PhotoViewerFeature

final class BurstFilmstripArchitectureTests: XCTestCase {
    func testShortCallFormReloadsOnlyOnIdentityChangeNotSelection() {
        let uids = [PhotoUID(volumeID: "v", nodeID: "a"), PhotoUID(volumeID: "v", nodeID: "b")]
        let update = BurstFilmstripUpdatePolicy.resolve(
            previousItems: uids,
            currentItems: uids,
            previousSelectedUID: uids[0],
            currentSelectedUID: uids[1]
        )
        XCTAssertFalse(update.reloadData, "same UIDs must not trigger a full reload")
        XCTAssertTrue(update.selectCurrent, "a selection change must still move the native selection")
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
