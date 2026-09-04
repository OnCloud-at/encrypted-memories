import Foundation

/// Persisted-settings keys + defaults for the Offline Photo Library and window/sidebar chrome.
/// Centralised here (in the SDK-agnostic core) so the App glue and the test target share one
/// source of truth - UserDefaults key strings drift silently otherwise.
public enum AppSettingsKey {
    /// Offline Photo Library master switch. When on, full-resolution originals viewed in the photo viewer are
    /// persisted to the encrypted on-disk `originals` cache so reopening them (even after relaunch / offline) is
    /// instant. Grid thumbnails are mandatory infrastructure and crawl independently of this toggle.
    public static let offlineLibraryEnabled = "EncryptedMemories.offlineLibraryEnabled"
    /// Whether the offline originals disk cache is unbounded (no size cap). When false, `offlineOriginalsCapGB`
    /// bounds it and the least-recently-used originals are purged once the cap is exceeded.
    public static let offlineOriginalsCapUnlimited = "EncryptedMemories.offlineOriginalsCapUnlimited"
    /// Size cap (in gigabytes) for the offline originals disk cache when bounded.
    public static let offlineOriginalsCapGB = "EncryptedMemories.offlineOriginalsCapGB"
    /// User-resizable left sidebar width (points).
    public static let sidebarWidth = "EncryptedMemories.sidebarWidth"
    /// Whether the left sidebar is visible.
    public static let sidebarVisible = "EncryptedMemories.sidebarVisible"
    /// Saved main-window frame string (NSStringFromRect).
    public static let mainWindowFrame = "EncryptedMemories.mainWindowFrame"
    /// Records that macOS showed the Full Disk Access setup before the first folder selection.
    public static let folderBackupFullDiskAccessIntroduced =
        "EncryptedMemories.folderBackupFullDiskAccessIntroduced"
    /// Explicit iOS opt-in. The display may stay awake only while the app is foreground-active and
    /// a photo-backup pass is doing work; background execution is governed separately by BGTask.
    public static let keepDisplayAwakeDuringForegroundBackup =
        "EncryptedMemories.keepDisplayAwakeDuringForegroundBackup"
}

public enum AppSettingsDefault {
    /// Offline Photo Library is **on by default**: viewed originals are kept locally (encrypted) up to the cap.
    /// Thumbnails are always crawled while signed in, regardless of this value.
    public static let offlineLibraryEnabled = true
    /// Bounded by default (no surprise unbounded disk growth).
    public static let offlineOriginalsCapUnlimited = false
    /// Default originals-cache cap: 5 GB.
    public static let offlineOriginalsCapGB = 5.0
    /// Auto-lock remains enabled unless the user explicitly opts in for a large foreground import.
    public static let keepDisplayAwakeDuringForegroundBackup = false
}

/// Pure admission rule for the iOS idle-timer adapter. Keeping this in Core makes the three
/// required conditions independently testable without importing UIKit.
public enum BackupDisplayWakePolicy {
    public static func shouldKeepDisplayAwake(
        userOptedIn: Bool,
        applicationIsForegroundActive: Bool,
        backupIsActivelyProcessing: Bool
    ) -> Bool {
        userOptedIn && applicationIsForegroundActive && backupIsActivelyProcessing
    }
}

/// Optional backend capability: report how many photo rows the local metadata store (the SQLite
/// timeline cache) currently holds. Surfaced as "metadata rows" on the Developer/Cache page.
public protocol LibraryStatsProvider: Sendable {
    func metadataRowCount() async -> Int
}

/// Aggregated, displayable state of the on-disk offline cache. All fields are plain values so the view layer
/// and tests can use them without touching the cache actors.
public struct OfflineCacheStatus: Sendable, Equatable {
    public var offlineEnabled: Bool
    public var totalAssets: Int
    public var metadataRows: Int
    public var thumbnailsOnDisk: Int
    public var thumbnailsMissing: Int
    public var ramDecodedEstimate: Int
    public var prefetchQueueDepth: Int
    public var activePrefetchJobs: Int
    public var prefetchPausedReason: String
    public var failedThumbnailCount: Int
    public var cacheSizeBytes: Int64
    public var previewCacheSizeBytes: Int64
    /// On-disk size of the encrypted full-resolution originals cache (0 when the offline library is off / empty).
    public var originalsCacheSizeBytes: Int64
    public var lastError: String?

    public init(
        offlineEnabled: Bool = false,
        totalAssets: Int = 0,
        metadataRows: Int = 0,
        thumbnailsOnDisk: Int = 0,
        thumbnailsMissing: Int = 0,
        ramDecodedEstimate: Int = 0,
        prefetchQueueDepth: Int = 0,
        activePrefetchJobs: Int = 0,
        prefetchPausedReason: String = "none",
        failedThumbnailCount: Int = 0,
        cacheSizeBytes: Int64 = 0,
        previewCacheSizeBytes: Int64 = 0,
        originalsCacheSizeBytes: Int64 = 0,
        lastError: String? = nil
    ) {
        self.offlineEnabled = offlineEnabled
        self.totalAssets = totalAssets
        self.metadataRows = metadataRows
        self.thumbnailsOnDisk = thumbnailsOnDisk
        self.thumbnailsMissing = thumbnailsMissing
        self.ramDecodedEstimate = ramDecodedEstimate
        self.prefetchQueueDepth = prefetchQueueDepth
        self.activePrefetchJobs = activePrefetchJobs
        self.prefetchPausedReason = prefetchPausedReason
        self.failedThumbnailCount = failedThumbnailCount
        self.cacheSizeBytes = cacheSizeBytes
        self.previewCacheSizeBytes = previewCacheSizeBytes
        self.originalsCacheSizeBytes = originalsCacheSizeBytes
        self.lastError = lastError
    }

    /// Disk thumbnail coverage as a 0…1 fraction. An empty or hydrating library reports zero.
    public var thumbnailCoverage: Double {
        guard totalAssets > 0 else { return 0 }
        return min(1, Double(thumbnailsOnDisk) / Double(totalAssets))
    }

    public var totalCacheSizeBytes: Int64 { cacheSizeBytes + previewCacheSizeBytes + originalsCacheSizeBytes }
}
