import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileSearchThumbnailTests: XCTestCase {
    @MainActor func testSamePhotoReloadsWhenItsAuthenticatedFeedArrivesOrChanges() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = PhotoUID(volumeID: "preview-test", nodeID: "same-photo")
        let green = try await feed(color: .green, name: "first", uid: uid, root: root)
        let red = try await feed(color: .red, name: "replacement", uid: uid, root: root)
        let state = SearchThumbnailProbeState()
        let host = UIHostingController(rootView: SearchThumbnailProbe(uid: uid, state: state))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(centerColor(host.view).green)
        state.feed = green
        try await waitUntil { self.centerColor(host.view).green }
        XCTAssertTrue(centerColor(host.view).green, "An arriving feed must replace the placeholder")

        state.feed = red
        try await waitUntil { self.centerColor(host.view).red }
        XCTAssertTrue(centerColor(host.view).red, "A replacement feed must replace the previous account image")

        state.feed = nil
        try await waitUntil { !self.centerColor(host.view).red }
        XCTAssertFalse(centerColor(host.view).red, "Removing the feed must clear the loaded image")
        await green.stopPrefetch()
        await red.stopPrefetch()
    }

    @MainActor func testCancelledFeedCannotPublishAfterReplacement() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = PhotoUID(volumeID: "preview-test", nodeID: "late-result")
        let greenData = try colorData(.green)
        let oldLoader = BlockingThumbnailLoader(data: greenData)
        let oldFeed = UIKitThumbnailFeed(
            cache: ThumbnailCache(rootDirectory: root.appendingPathComponent("old")),
            loader: oldLoader,
            concurrency: 1,
            batch: 1)
        let replacement = try await feed(
            color: .red, name: "replacement", uid: uid, root: root)
        let state = SearchThumbnailProbeState(feed: oldFeed)
        let host = UIHostingController(rootView: SearchThumbnailProbe(uid: uid, state: state))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            Task { await oldLoader.release() }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        await oldLoader.waitUntilEntered()
        state.feed = replacement
        try await waitUntil { self.centerColor(host.view).red }

        await oldLoader.release()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(centerColor(host.view).red, "A cancelled feed must not overwrite its replacement")
        XCTAssertFalse(centerColor(host.view).green)
        state.feed = nil
        try await waitUntil { !self.centerColor(host.view).red }
        await oldFeed.stopPrefetch()
        await replacement.stopPrefetch()
    }

    @MainActor private func feed(
        color: UIColor,
        name: String,
        uid: PhotoUID,
        root: URL
    ) async throws -> UIKitThumbnailFeed {
        let cache = ThumbnailCache(rootDirectory: root.appendingPathComponent(name))
        await cache.store(try colorData(color), for: uid)
        let feed = UIKitThumbnailFeed(cache: cache, loader: EmptyThumbnailLoader())
        _ = await feed.warmDecoded([uid])
        XCTAssertNotNil(feed.memoryImage(for: uid))
        return feed
    }

    @MainActor private func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }

    @MainActor private func centerColor(_ view: UIView) -> (red: Bool, green: Bool) {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard
            let center = image.cgImage?.cropping(
                to: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1))
        else { return (false, false) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return (
            rendered && pixel[0] > 220 && pixel[1] < 30,
            rendered && pixel[1] > 220 && pixel[0] < 30
        )
    }

    private func colorData(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.pngData())
    }
}

@MainActor @Observable private final class SearchThumbnailProbeState {
    var feed: UIKitThumbnailFeed?

    init(feed: UIKitThumbnailFeed? = nil) {
        self.feed = feed
    }
}

private struct SearchThumbnailProbe: View {
    let uid: PhotoUID
    let state: SearchThumbnailProbeState

    var body: some View {
        MobileSearchThumbnail(
            uid: uid,
            size: 64,
            cornerRadius: 4,
            placeholderSymbol: "photo",
            thumbnailFeed: state.feed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private actor BlockingThumbnailLoader: ThumbnailBatchLoader {
    private let data: Data
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) {
        self.data = data
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        for uid in uids {
            onLoaded(uid, data)
        }
        return .delivered
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        ThumbnailBatchLoadResult(itemErrors: Dictionary(uniqueKeysWithValues: uids.map { ($0, "missing") }))
    }
}
