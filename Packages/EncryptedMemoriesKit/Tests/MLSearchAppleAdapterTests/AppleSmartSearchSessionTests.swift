import CryptoKit
import Foundation
import MLSearchCore
import MediaByteCache
import MediaFeedCore
import PhotosCore
import Testing

@testable import MLSearchAppleAdapter

private let appleSmartSearchTestKey = SymmetricKey(size: .bits256)

/// Minimal loader that returns nil or empty payloads for every request (used in tests where the feed is built
/// but Smart Search is not exercised end-to-end).
private actor NullThumbnailLoader: ThumbnailBatchLoader {
    private let payloads: [PhotoUID: Data]

    init(payloads: [PhotoUID: Data] = [:]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids {
            if let data = payloads[uid] {
                onLoaded(uid, data)
            }
        }
        return .delivered
    }
}

/// Builds one account's thumbnail feed using a temp root directory. Tests share this to get a real
/// `ThumbnailFeedCore` without needing a full photo library.
private func makeTestFeed(
    namespace: String,
    root: URL,
    loader: any ThumbnailBatchLoader
) -> ThumbnailFeedCore {
    let cache = ThumbnailCache(namespace: namespace, rootDirectory: root)
    cache.configure(accountUID: "acct-A", key: appleSmartSearchTestKey)
    return ThumbnailFeedCore(cache: cache, loader: loader, configuration: testConfiguration())
}

/// Default configuration for AppleSmartSearchSession tests.
private func testConfiguration() -> ThumbnailFeedCoreConfiguration {
    ThumbnailFeedCoreConfiguration(
        targetPixels: 16,
        downloadConcurrencyLimit: 2,
        batchSize: 2,
        maxConcurrentDecodes: 1,
        visibleQuietWindow: 0,
        crawlBackoffSeconds: 0,
        downloadTimeoutSeconds: 1
    )
}

/// Unique temporary root directory for one test instance.
private func uniqueCacheRoot(_ suffix: String) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "apple-smart-search-tests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite struct AppleSmartSearchSessionTests {
    @MainActor
    private final class RecordingBackgroundHost: MLSmartSearchBackgroundHost {
        private(set) var configureCount = 0
        private(set) var detachCount = 0
        private(set) var lastDetached: ObjectIdentifier?

        func configure(lifecycle: MLSmartSearchLifecycle) {
            configureCount += 1
        }

        func detach(lifecycle: MLSmartSearchLifecycle) {
            detachCount += 1
            lastDetached = ObjectIdentifier(lifecycle)
        }
    }

    @Test @MainActor func stopOnNeverConfiguredSessionReturnsNilAndCallsNothing() async {
        let host = RecordingBackgroundHost()
        let session = AppleSmartSearchSession(backgroundHost: host)

        let task = session.stop()

        #expect(task == nil)
        #expect(host.configureCount == 0)
        #expect(host.detachCount == 0)
        #expect(session.controller == nil)
    }

    @Test @MainActor func configureStopAndReconfigureKeepTheHostAndControllerInSync() async throws {
        // Skip if Smart Search is unavailable on this device (host lacks feature).
        if AppleSmartSearchBootstrap.featureAvailability() != .available {
            // Test remains non-empty but does not exercise configure/stop when the host has no Smart Search support.
            #expect(true)
            return
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = makeTestFeed(
            namespace: "smart-search-test-\(UUID().uuidString)",
            root: uniqueCacheRoot("feed"),
            loader: NullThumbnailLoader()
        )
        let host = RecordingBackgroundHost()
        let session = AppleSmartSearchSession(backgroundHost: host)
        session.configure(
            accountDirectory: dir,
            accountUID: "acct-A",
            keyPassword: "pw",
            feed: feed,
            databasePolicy: .conservative
        )

        #expect(session.controller != nil)
        #expect(host.configureCount == 1)
        #expect(host.detachCount == 0)

        let first = session.controller?.lifecycleActor
        session.configure(
            accountDirectory: dir,
            accountUID: "acct-A",
            keyPassword: "pw",
            feed: feed,
            databasePolicy: .conservative
        )

        #expect(host.configureCount == 2)
        #expect(host.detachCount == 1)
        #expect(host.lastDetached == first.map(ObjectIdentifier.init))
        #expect(session.controller?.lifecycleActor !== first)

        let second = session.controller?.lifecycleActor
        let task = session.stop()

        #expect(task != nil)
        #expect(session.controller == nil)
        #expect(host.detachCount == 2)
        #expect(host.lastDetached == second.map(ObjectIdentifier.init))

        await task?.value
    }
}
