import Foundation
import OSLog

/// One-time cold-launch removal of the system URL cache and cookie file that the SDK network client
/// wrote before it switched to an ephemeral session (#605). Nothing ever read them.
///
/// The purge never lists either container. It removes only the literal names below, directly inside
/// `Library/Caches/<bundle id>` and `Library/Cookies`, and never follows a symbolic link. Every other
/// entry stays, including the Core ML compile cache next to the URL cache and all app caches.
/// On macOS it runs only inside the app's sandbox container, where `Library/Cookies` is the app's own.
public enum UnusedNetworkStorePurge {
    static let completedKey = "network.unusedStorePurged.v1"
    static let urlCacheEntryNames = ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"]
    static let cookieFileName = "Cookies.binarycookies"
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "NetworkStorePurge")
    #if os(macOS)
        static let requiresSandboxContainer = true
    #else
        static let requiresSandboxContainer = false
    #endif

    /// The app's own Library, Caches directory and bundle identifier.
    public struct Location: Sendable, Equatable {
        let libraryDirectory: URL
        let cachesDirectory: URL
        let bundleIdentifier: String

        /// Resolved from the system search paths; nil when the system reports none.
        public static var current: Location? {
            let fm = FileManager.default
            guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
                let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
                let bundleIdentifier = Bundle.main.bundleIdentifier
            else { return nil }
            return Location(libraryDirectory: library, cachesDirectory: caches, bundleIdentifier: bundleIdentifier)
        }
    }

    public struct Result: Sendable, Equatable {
        public let removed: [URL]
        public let failed: [URL]

        public var succeeded: Bool { failed.isEmpty }
    }

    /// Runs the purge unless an earlier launch completed it. Returns nil when it did not run.
    /// Any failure leaves the completion flag unset, so the next cold launch tries again.
    @discardableResult
    public static func purgeOnce(defaults: UserDefaults = .standard, location: Location? = .current) -> Result? {
        guard let location else { return nil }
        return purgeOnce(
            defaults: defaults,
            libraryDirectory: location.libraryDirectory,
            cachesDirectory: location.cachesDirectory,
            bundleIdentifier: location.bundleIdentifier,
            removeItem: { try TransientPlaintextPurge.removeWithoutFollowingLinks(at: $0, boundary: $0) }
        )
    }

    static func purgeOnce(
        defaults: UserDefaults,
        libraryDirectory: URL,
        cachesDirectory: URL,
        bundleIdentifier: String,
        requiresSandboxContainer: Bool = Self.requiresSandboxContainer,
        removeItem: (URL) throws -> Void
    ) -> Result? {
        guard !defaults.bool(forKey: completedKey) else { return nil }
        // Both containers must sit in the app's own Library.
        guard
            !requiresSandboxContainer
                || isSandboxContainerLibrary(libraryDirectory, bundleIdentifier: bundleIdentifier),
            cachesDirectory.standardizedFileURL.deletingLastPathComponent().path
                == libraryDirectory.standardizedFileURL.path
        else { return nil }

        var removed: [URL] = []
        var failed: [URL] = []
        let containers: [(parent: URL, name: String, entries: [String])] = [
            (cachesDirectory, bundleIdentifier, urlCacheEntryNames),
            (libraryDirectory, "Cookies", [cookieFileName]),
        ]
        for (parent, name, entries) in containers {
            let parent = parent.standardizedFileURL
            let container = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            // A name with `/` or `..` would leave the search-path directory.
            guard container.deletingLastPathComponent().path == parent.path, container.lastPathComponent == name else {
                failed.append(container)
                continue
            }
            // A link in place of the container points outside the app's own files.
            guard itemType(at: container) == .typeDirectory else { continue }
            for entry in entries {
                let target = container.appendingPathComponent(entry).standardizedFileURL
                guard itemType(at: target) != nil else { continue }
                // An entry that disappeared on its own during removal counts as removed.
                try? removeItem(target)
                if itemType(at: target) == nil {
                    removed.append(target)
                } else {
                    failed.append(target)
                }
            }
        }
        if failed.isEmpty {
            defaults.set(true, forKey: completedKey)
        } else {
            logger.error("Could not remove \(failed.count) unused network store entries; retrying at next launch.")
        }
        return Result(removed: removed, failed: failed)
    }

    /// iOS apps always run in their own container. A macOS app outside its own sandbox container
    /// (`Containers/<bundle id>/Data/Library`) shares `Library/Cookies` with other apps,
    /// so the purge must not run there.
    static func isSandboxContainerLibrary(_ library: URL, bundleIdentifier: String) -> Bool {
        let library = library.standardizedFileURL
        let data = library.deletingLastPathComponent()
        let container = data.deletingLastPathComponent()
        return library.lastPathComponent == "Library"
            && data.lastPathComponent == "Data"
            && container.lastPathComponent == bundleIdentifier
            && container.deletingLastPathComponent().lastPathComponent == "Containers"
    }

    /// The type of the item itself, without following a final symbolic link; nil when nothing exists.
    private static func itemType(at url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }
}
