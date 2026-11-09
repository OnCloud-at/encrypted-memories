import Foundation
import PhotosCore

/// Month markers of one ordered photo list, prepared for the scroll date label. Hosts build it once per content
/// revision, away from the main actor. A scroll frame then only looks up a flat index: a binary search over the
/// month starts, with no allocation, no formatter and no scan of the library.
public struct TimelineScrollDateIndex: Equatable, Sendable {
    /// The build generation of the markers, counted by `TimelineScrollDateIndexScheduler`. Two builds of different
    /// lists never compare equal, so installing a rebuilt index always republishes the month.
    public let revision: UInt64
    /// Flat index of the first photo of each month, in list order.
    let starts: [Int]
    /// Localized month and year of each marker, formatted once by the system formatter.
    let texts: [String]
    /// Number of photos in the list.
    let itemCount: Int

    init(revision: UInt64, markers: [TimelineDateMarker], itemCount: Int) {
        self.revision = revision
        starts = markers.map(\.index)
        texts = markers.map(\.text)
        self.itemCount = itemCount
    }

    /// Builds the index in one pass over `items`. Returns nil for an empty list, for a list without a usable date,
    /// and when the calling task is cancelled.
    public static func build(
        items: [PhotoItem], revision: UInt64,
        calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> TimelineScrollDateIndex? {
        let markers = TimelineDateMarkers.markers(
            items: items, granularity: .month, monthStyle: .wide, calendar: calendar, locale: locale)
        guard !markers.isEmpty, !Task.isCancelled else { return nil }
        return TimelineScrollDateIndex(revision: revision, markers: markers, itemCount: items.count)
    }

    /// One month of the list: the flat index range it covers and its text.
    public struct Month: Equatable, Sendable {
        public let range: Range<Int>
        public let text: String
    }

    /// The month that contains the photo at `flatIndex`. A photo before the first usable date belongs to the first
    /// month. Returns nil for an index outside the list.
    public func month(containing flatIndex: Int) -> Month? {
        guard flatIndex >= 0, flatIndex < itemCount, !starts.isEmpty else { return nil }
        // The last start that is <= flatIndex.
        var lo = 0
        var hi = starts.count - 1
        var found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= flatIndex {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let lower = found == 0 ? 0 : starts[found]
        let upper = found + 1 < starts.count ? starts[found + 1] : itemCount
        return Month(range: lower..<upper, text: texts[found])
    }
}

/// Which timeline surfaces may show the scroll date label. One rule for every platform.
public enum TimelineScrollDateLabelEligibility {
    /// The label describes only a list in date order that is on screen now: never a loading surface, a surface whose
    /// last load failed (even when it keeps showing cached photos), a projection that is still resolving (the grid
    /// keeps the previous list meanwhile), or results led by file-name matches.
    public static func showsLabel(
        isLoading: Bool, hasFailure: Bool, hasProjectionCriteria: Bool, resolvedProjection: TimelineSearchProjection?
    ) -> Bool {
        guard !isLoading, !hasFailure else { return false }
        guard hasProjectionCriteria else { return true }
        return resolvedProjection?.isDateOrdered ?? false
    }
}
