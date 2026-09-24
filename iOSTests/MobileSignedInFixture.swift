import Foundation
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import UIKit

@testable import EncryptedMemoriesMobile

/// A deterministic, offline account for hosted tests.
///
/// It replaces only the account backend and its content inside the process-wide `MobileAccountRuntime`. Every
/// production layer above it (scene roots, tab shell, timeline screens, grids, selection, search, viewer) renders
/// unchanged. No real account, keychain entry, network request, or physical device is involved.
@MainActor final class MobileSignedInFixture {
    static let sectionNames = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]

    let session = ProtonSession(
        uid: "fixture-account", accessToken: "fixture-access", refreshToken: "fixture-refresh",
        keyPassword: "fixture-key")
    let sections: [TimelineSection]
    let backend: MobileFixtureBackend
    let cache: ThumbnailCache
    let feed: UIKitThumbnailFeed
    var items: [PhotoItem] { sections.flatMap(\.items) }

    private let runtime: MobileAccountRuntime
    private let cacheDirectory: URL

    init(runtime: MobileAccountRuntime = .shared, itemsPerSection: Int = 36) async throws {
        guard !BackupLocalDataPurge.isPurgePending() else { throw MobileFixtureError.pendingAccountPurge }
        self.runtime = runtime
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "signed-in-fixture-" + UUID().uuidString)
        var sections: [TimelineSection] = []
        var thumbnails: [PhotoUID: Data] = [:]
        let calendar = Calendar(identifier: .gregorian)
        for (sectionIndex, name) in Self.sectionNames.enumerated() {
            let sectionDate = calendar.date(from: DateComponents(year: 2026, month: sectionIndex + 1, day: 12))!
            var items: [PhotoItem] = []
            for index in 0..<itemsPerSection {
                let uid = PhotoUID(volumeID: "fixture", nodeID: "\(name)-\(index)")
                let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                    UIColor(
                        hue: CGFloat(sectionIndex) / CGFloat(Self.sectionNames.count), saturation: 0.55,
                        brightness: 0.45 + 0.5 * CGFloat(index % 6) / 6, alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
                }
                guard let data = bitmap.jpegData(compressionQuality: 0.8) else { throw MobileFixtureError.bitmap }
                thumbnails[uid] = data
                items.append(
                    PhotoItem(
                        uid: uid, captureTime: sectionDate.addingTimeInterval(TimeInterval(index) * 60),
                        mediaType: "image/jpeg"))
            }
            sections.append(
                TimelineSection(id: "fixture-\(name)", date: sectionDate, title: "Fixture \(name)", items: items))
        }
        self.sections = sections
        backend = MobileFixtureBackend(sections: sections, thumbnails: thumbnails)
        cache = ThumbnailCache(rootDirectory: cacheDirectory)
        feed = UIKitThumbnailFeed(cache: cache, loader: backend)
        for (uid, data) in thumbnails {
            await cache.store(data, for: uid)
        }
        _ = await feed.warmDecoded(thumbnails.keys.map { $0 })
    }

    /// Signs the shared account runtime in with this fixture. Library content first, then the session, so the
    /// runtime's session observer finds an already configured account and does not start a network backend.
    func install() {
        runtime.libraryModel.installIsolatedLibrary(
            session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
            thumbnailFeed: feed)
        runtime.sessionModel.installIsolatedSession(session)
    }

    /// Installs only the library content into an isolated model (no session, no shared runtime): for probes that
    /// host one production screen in a test window.
    func install(into model: MobileLibraryModel) {
        model.installIsolatedLibrary(
            session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
            thumbnailFeed: feed, thumbnailCache: cache)
    }

    func install(
        into model: MobileLibraryModel,
        backend: any PhotosBackend,
        sections: [TimelineSection],
        thumbnailFeed: UIKitThumbnailFeed,
        thumbnailCache: ThumbnailCache
    ) {
        model.installIsolatedLibrary(
            session: session, store: runtime.sessionModel.sessionStore, backend: backend, sections: sections,
            thumbnailFeed: thumbnailFeed, thumbnailCache: thumbnailCache)
    }

    /// Clears fixture state through the session observer without requesting another persistent-data purge.
    func clearSession() {
        runtime.sessionModel.installIsolatedSession(nil)
    }

    func removeCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

enum MobileFixtureError: Error {
    case bitmap
    case unavailable
    case pendingAccountPurge
}

/// Every provider of the account backend, answered from memory. Media beyond thumbnails is unavailable, which
/// the production viewer handles like an offline account.
struct MobileFixtureBackend: PhotosBackend {
    let sections: [TimelineSection]
    let thumbnails: [PhotoUID: Data]
    var favoriteLoader: (@Sendable () async throws -> Set<PhotoUID>)? = nil
    var favoriteWriter: (@Sendable ([PhotoUID], Bool) async throws -> Void)? = nil

    func loadTimeline() async throws -> [TimelineSection] { sections }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { sections }

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        guard let data = thumbnails[uid] else { throw MobileFixtureError.unavailable }
        return data
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        var missing: [PhotoUID: String] = [:]
        for uid in uids {
            if let data = thumbnails[uid] {
                onLoaded(uid, data)
            } else {
                missing[uid] = "fixture has no thumbnail"
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: missing)
    }

    func preview(for uid: PhotoUID) async throws -> Data { try await thumbnail(for: uid) }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw MobileFixtureError.unavailable
    }
    func streamOriginalBytes(
        for uid: PhotoUID, onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw MobileFixtureError.unavailable
    }
    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    )
        async throws
    {
        throw MobileFixtureError.unavailable
    }
    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        throw MobileFixtureError.unavailable
    }
    func prefetchEncrypted(for uid: PhotoUID) async throws {}
    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        PhotoMetadata(filename: "\(uid.nodeID).jpg", mimeType: "image/jpeg", pixelWidth: 160, pixelHeight: 160)
    }
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
    func favoriteUIDs() async throws -> Set<PhotoUID> {
        try await favoriteLoader?() ?? []
    }
    func setFavorites(_ uids: [PhotoUID], _ favorite: Bool) async throws {
        try await favoriteWriter?(uids, favorite)
    }
    func saveToLibrary(_ uids: [PhotoUID]) async throws -> PhotoLibrarySaveResult {
        PhotoLibrarySaveResult(saved: Set(uids), failed: [])
    }
    func trash(_ uids: [PhotoUID]) async throws {}
    func restore(_ uids: [PhotoUID]) async throws {}
    func emptyTrash() async throws {}
    func metadataRowCount() async -> Int { sections.reduce(0) { $0 + $1.items.count } }
    func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {}
}
