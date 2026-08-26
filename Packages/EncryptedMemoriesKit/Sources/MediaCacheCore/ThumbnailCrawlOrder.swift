import Foundation
import PhotosCore

/// The order in which the background thumbnail crawl walks the library.
///
/// The timeline store delivers photos oldest-first (`TimelineMetadataStore.load()` is
/// `ORDER BY t, vol, node`), and the grid bottom-pins to the newest photo - so the array the UI holds is
/// oldest to newest. Apple Photos (and this app) open scrolled to the bottom, so the crawl should fetch
/// newest to oldest: the photos the user is most likely to view first are
/// cached first.
///
/// This helper makes that ordering explicit and testable rather than relying on a caller remembering to
/// `.reversed()`. It sorts by capture time descending (newest first) using a stable sort, so items that
/// share a capture time keep their original relative order (deterministic crawl + resumable checkpoint).
public enum ThumbnailCrawlOrder {
    /// Newest-to-oldest UID order for the background crawl. Robust to the input order (sorts by
    /// `captureTime` descending) so it does not silently break if an upstream query stops being `ASC`.
    public static func newestToOldest(_ items: [PhotoItem]) -> [PhotoUID] {
        stableSortedNewestFirst(items).map(\.uid)
    }

    /// Linear fast path for the canonical timeline projection (`captureTime` ascending). Equal-time runs keep
    /// their existing deterministic order while the runs themselves are walked newest to oldest. If a caller
    /// ever violates the documented order, this fails safely to the robust stable sort above.
    public static func newestToOldestFromChronological(_ items: [PhotoItem]) -> [PhotoUID] {
        guard items.count > 1 else { return items.map(\.uid) }
        for index in 1..<items.count where items[index - 1].captureTime > items[index].captureTime {
            return newestToOldest(items)
        }

        var result: [PhotoUID] = []
        result.reserveCapacity(items.count)
        var groupEnd = items.count
        while groupEnd > 0 {
            let captureTime = items[groupEnd - 1].captureTime
            var groupStart = groupEnd - 1
            while groupStart > 0, items[groupStart - 1].captureTime == captureTime {
                groupStart -= 1
            }
            for index in groupStart..<groupEnd {
                result.append(items[index].uid)
            }
            groupEnd = groupStart
        }
        return result
    }

    /// Same ordering, returning the full items (for callers/tests that need capture times).
    public static func newestToOldest(items: [PhotoItem]) -> [PhotoItem] {
        stableSortedNewestFirst(items)
    }

    /// Swift's `sorted(by:)` is not guaranteed stable, so we decorate with the original index and break
    /// ties on it - giving a deterministic newest-first order even when many photos share a timestamp.
    private static func stableSortedNewestFirst(_ items: [PhotoItem]) -> [PhotoItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.captureTime != rhs.element.captureTime {
                    return lhs.element.captureTime > rhs.element.captureTime  // newest first
                }
                return lhs.offset < rhs.offset  // stable tie-break
            }
            .map(\.element)
    }
}
