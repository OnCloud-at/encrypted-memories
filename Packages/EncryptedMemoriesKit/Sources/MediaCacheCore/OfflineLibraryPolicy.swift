import Foundation

/// Keeps thumbnail crawling independent of the Offline Photo Library setting.
/// Thumbnails crawl while the user is signed in and timeline metadata is available.
public enum OfflineLibraryPolicy {
    /// Thumbnail crawling is enabled while the user is signed in, regardless of the offline setting.
    public static func shouldCrawlThumbnails(offlineEnabled: Bool) -> Bool { true }

    /// Whether the Offline Photo Library setting enables derivative caching.
    public static func shouldCacheOfflineDerivatives(offlineEnabled: Bool) -> Bool { offlineEnabled }
}
