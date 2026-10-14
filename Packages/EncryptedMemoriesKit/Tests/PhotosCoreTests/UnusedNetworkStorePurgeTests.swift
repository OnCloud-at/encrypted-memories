import XCTest

@testable import PhotosCore

/// Verifies the one-time removal of the unused URL cache and cookie file (#605): exactly the named
/// entries go, everything next to them stays, and only a complete run marks the purge done.
final class UnusedNetworkStorePurgeTests: XCTestCase {
    private let bundleIdentifier = "at.oncloud.encryptedmemories"
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var library: URL!
    private var caches: URL!
    private var urlCache: URL!
    private var cookies: URL!

    override func setUpWithError() throws {
        suiteName = "unused-network-store-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-network-store-\(UUID().uuidString)", isDirectory: true)
        // The macOS sandbox container layout; the purge refuses any other Library on macOS.
        library = root.appendingPathComponent("Containers/\(bundleIdentifier)/Data/Library", isDirectory: true)
        caches = library.appendingPathComponent("Caches", isDirectory: true)
        urlCache = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        cookies = library.appendingPathComponent("Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: urlCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cookies, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func seedUnusedStores() throws {
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm"] {
            try write(urlCache.appendingPathComponent(name))
        }
        try write(urlCache.appendingPathComponent("fsCachedData/0B1C2D3E"))
        try write(cookies.appendingPathComponent("Cookies.binarycookies"))
    }

    private func purge(
        bundleIdentifier: String? = nil,
        library: URL? = nil,
        removeItem: (URL) throws -> Void = {
            try TransientPlaintextPurge.removeWithoutFollowingLinks(at: $0, boundary: $0)
        }
    ) -> UnusedNetworkStorePurge.Result? {
        let library = library ?? self.library!
        return UnusedNetworkStorePurge.purgeOnce(
            defaults: defaults,
            libraryDirectory: library,
            cachesDirectory: library.appendingPathComponent("Caches", isDirectory: true),
            bundleIdentifier: bundleIdentifier ?? self.bundleIdentifier,
            removeItem: removeItem
        )
    }

    private var isDone: Bool { defaults.bool(forKey: UnusedNetworkStorePurge.completedKey) }

    func testRemovesExactlyTheNamedEntriesAndKeepsEverythingNextToThem() throws {
        try seedUnusedStores()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("must-survive.txt")
        try write(outsideFile)
        try FileManager.default.createSymbolicLink(
            at: urlCache.appendingPathComponent("fsCachedData/outside-link"), withDestinationURL: outside)
        let survivors = [
            urlCache.appendingPathComponent("com.apple.e5rt.e5bundlecache/24A434/model/compiled.bin"),
            urlCache.appendingPathComponent("Cache.db.keep"),
            urlCache.appendingPathComponent("fsCachedData-other/entry"),
            caches.appendingPathComponent("EncryptedMemories/thumbnails.enc"),
            caches.appendingPathComponent("other.bundle/Cache.db"),
            library.appendingPathComponent("Application Support/EncryptedMemories/library.sqlite"),
            library.appendingPathComponent("Application Support/Cache.db"),
            library.appendingPathComponent("Cookies.binarycookies"),
            cookies.appendingPathComponent("Other.binarycookies"),
        ]
        for survivor in survivors {
            try write(survivor)
        }

        let result = try XCTUnwrap(purge())

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            Set(result.removed.map(\.lastPathComponent)),
            ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData", "Cookies.binarycookies"])
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"] {
            XCTAssertFalse(exists(urlCache.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
        for survivor in survivors {
            XCTAssertTrue(exists(survivor), survivor.path)
        }
        XCTAssertTrue(exists(urlCache), "the container itself stays")
        XCTAssertTrue(exists(cookies), "the cookie folder itself stays")
        XCTAssertTrue(exists(outsideFile), "a link inside fsCachedData is not followed")
        XCTAssertTrue(isDone)
    }

    func testRunsOnlyOnce() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())
        XCTAssertTrue(isDone)

        try seedUnusedStores()
        XCTAssertNil(purge(), "a completed purge does not run again")
        XCTAssertTrue(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertTrue(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
    }

    func testMissingEntriesAndContainersAreNotAnError() throws {
        let result = try XCTUnwrap(purge())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(isDone)

        defaults.removeObject(forKey: UnusedNetworkStorePurge.completedKey)
        try FileManager.default.removeItem(at: urlCache)
        try FileManager.default.removeItem(at: cookies)
        let withoutContainers = try XCTUnwrap(purge())
        XCTAssertTrue(withoutContainers.succeeded)
        XCTAssertTrue(isDone)
    }

    func testOneFailedRemovalDoesNotStopTheOthersAndKeepsThePurgePending() throws {
        try seedUnusedStores()
        let wal = urlCache.appendingPathComponent("Cache.db-wal").standardizedFileURL

        let failed = try XCTUnwrap(
            purge(removeItem: { url in
                if url.lastPathComponent == "Cache.db-wal" { throw CocoaError(.fileWriteNoPermission) }
                try TransientPlaintextPurge.removeWithoutFollowingLinks(at: url, boundary: url)
            }))

        XCTAssertEqual(failed.failed, [wal])
        XCTAssertEqual(failed.removed.count, 4)
        XCTAssertTrue(exists(wal))
        XCTAssertFalse(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertFalse(exists(urlCache.appendingPathComponent("fsCachedData")))
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
        XCTAssertFalse(isDone, "a failed removal must be retried at the next launch")

        let retry = try XCTUnwrap(purge())
        XCTAssertEqual(retry.removed, [wal])
        XCTAssertFalse(exists(wal))
        XCTAssertTrue(isDone)
    }

    func testBundleIdentifierCannotLeaveTheCachesDirectory() throws {
        let escaped = library.appendingPathComponent("escape/Cache.db")
        try write(escaped)

        let result = try XCTUnwrap(purge(bundleIdentifier: "../escape"))

        XCTAssertTrue(exists(escaped))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(isDone)
    }

    func testLinkedContainersAreNotFollowed() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("Cache.db")
        let outsideCookies = outside.appendingPathComponent("Cookies.binarycookies")
        try write(outsideCache)
        try write(outsideCookies)
        try FileManager.default.removeItem(at: urlCache)
        try FileManager.default.removeItem(at: cookies)
        try FileManager.default.createSymbolicLink(at: urlCache, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: cookies, withDestinationURL: outside)

        let result = try XCTUnwrap(purge())

        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(exists(outsideCache))
        XCTAssertTrue(exists(outsideCookies))
    }

    #if os(macOS)
        func testDoesNothingOutsideAMacSandboxContainer() throws {
            let sharedLibrary = root.appendingPathComponent("Users/someone/Library", isDirectory: true)
            let sharedCookies = sharedLibrary.appendingPathComponent("Cookies/Cookies.binarycookies")
            let sharedCache = sharedLibrary.appendingPathComponent("Caches/\(bundleIdentifier)/Cache.db")
            try write(sharedCookies)
            try write(sharedCache)

            XCTAssertNil(purge(library: sharedLibrary))

            XCTAssertTrue(exists(sharedCookies))
            XCTAssertTrue(exists(sharedCache))
            XCTAssertFalse(isDone)
        }
    #endif

    /// Sign-out clears the app's preferences, so the next cold launch removes any URL cache or
    /// cookie file that appeared since the last purge.
    func testSignOutArmsThePurgeForTheNextLaunch() throws {
        try seedUnusedStores()
        XCTAssertNotNil(purge())

        try seedUnusedStores()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults, persistentDomainName: suiteName)
        let afterSignOut = try XCTUnwrap(purge())

        XCTAssertEqual(afterSignOut.removed.count, 5)
        XCTAssertFalse(exists(urlCache.appendingPathComponent("Cache.db")))
        XCTAssertFalse(exists(cookies.appendingPathComponent("Cookies.binarycookies")))
    }
}
