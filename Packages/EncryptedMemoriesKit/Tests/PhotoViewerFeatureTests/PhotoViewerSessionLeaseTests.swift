import CryptoKit
import Foundation
import MediaByteCache
import MediaCache
import PhotosCore
import XCTest

@testable import PhotoViewerFeature

/// The viewer must stop all work for a photo once the account of one of its caches changed. The lease of every cache
/// the viewer holds is checked; a cache that the viewer does not hold imposes nothing.
@MainActor
final class PhotoViewerSessionLeaseTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    private final class CountingMedia: FullMediaProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var originalReads: Int { lock.withLock { reads } }

        func preview(for uid: PhotoUID) async throws -> Data { throw CancellationError() }

        func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            lock.withLock { reads += 1 }
            throw CancellationError()
        }
    }

    private struct EmptyLoader: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult { .delivered }
    }

    private func makeCache() -> ThumbnailCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-lease-\(UUID().uuidString)", isDirectory: true)
        let cache = ThumbnailCache(namespace: "lease-\(UUID().uuidString)", rootDirectory: root)
        cache.configure(accountUID: "account-A", key: key)
        return cache
    }

    private func switchAccount(of cache: ThumbnailCache) {
        cache.configure(accountUID: "account-B", key: key)
    }

    private func makeModel(
        media: CountingMedia, previewCache: ThumbnailCache?, originalsCache: ThumbnailCache?
    ) -> PhotoViewerModel {
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "a"), captureTime: Date(timeIntervalSince1970: 1),
            mediaType: "image/jpeg")
        return PhotoViewerModel(
            items: [item], index: 0,
            feed: ThumbnailFeed(cache: makeCache(), loader: EmptyLoader()),
            media: media, previewCache: previewCache, originalsCache: originalsCache)
    }

    /// Asks for the sharp original and reports how often the provider was read. A refused request reads nothing.
    private func originalReads(of model: PhotoViewerModel, media: CountingMedia) async -> Int {
        model.requestOriginal()
        let deadline = ContinuousClock.now + .seconds(2)
        while media.originalReads == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        model.stop()
        return media.originalReads
    }

    func testAViewerWithoutCachesReadsTheOriginal() async {
        let media = CountingMedia()
        let model = makeModel(media: media, previewCache: nil, originalsCache: nil)

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 1)
    }

    func testAViewerWhoseCachesKeepTheirAccountReadsTheOriginal() async {
        let media = CountingMedia()
        let model = makeModel(media: media, previewCache: makeCache(), originalsCache: makeCache())

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 1)
    }

    func testAnAccountChangeOfThePreviewCacheStopsTheViewer() async {
        let media = CountingMedia()
        let preview = makeCache()
        let model = makeModel(media: media, previewCache: preview, originalsCache: makeCache())
        switchAccount(of: preview)

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 0)
    }

    func testAnAccountChangeOfTheOriginalsCacheStopsTheViewer() async {
        let media = CountingMedia()
        let originals = makeCache()
        let model = makeModel(media: media, previewCache: makeCache(), originalsCache: originals)
        switchAccount(of: originals)

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 0)
    }

    func testAnAccountChangeOfTheOnlyPreviewCacheStopsTheViewer() async {
        let media = CountingMedia()
        let preview = makeCache()
        let model = makeModel(media: media, previewCache: preview, originalsCache: nil)
        switchAccount(of: preview)

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 0)
    }

    func testAnAccountChangeOfTheOnlyOriginalsCacheStopsTheViewer() async {
        let media = CountingMedia()
        let originals = makeCache()
        let model = makeModel(media: media, previewCache: nil, originalsCache: originals)
        switchAccount(of: originals)

        let reads = await originalReads(of: model, media: media)

        XCTAssertEqual(reads, 0)
    }

    #if DEBUG
        private final class CaptureCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var captures = 0
            var total: Int { lock.withLock { captures } }
            func next() -> Int {
                lock.withLock {
                    captures += 1
                    return captures
                }
            }
        }

        /// The viewer captures the lease of its originals cache twice, one capture after the other: once as the
        /// lease of the originals cache and once as the lease of its session cache. The account teardown runs off
        /// the main thread, so the account can change between the two captures. The second lease is then current and
        /// only the check of the first lease stops the viewer.
        func testAnAccountChangeBetweenTheTwoLeaseCapturesOfTheOriginalsCacheStopsTheViewer() async {
            let media = CountingMedia()
            let originals = makeCache()
            let counter = CaptureCounter()
            let key = self.key
            originals.setSupportLockProbeForTesting { path, _ in
                guard path == .capture, counter.next() == 2 else { return }
                originals.configure(accountUID: "account-B", key: key)
            }
            defer { originals.setSupportLockProbeForTesting(nil) }
            let model = makeModel(media: media, previewCache: makeCache(), originalsCache: originals)
            XCTAssertEqual(counter.total, 2, "the viewer captures the lease of the originals cache twice")

            let reads = await originalReads(of: model, media: media)

            XCTAssertEqual(reads, 0)
        }
    #endif
}
