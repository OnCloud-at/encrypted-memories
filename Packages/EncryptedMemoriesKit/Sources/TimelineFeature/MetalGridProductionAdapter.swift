import Foundation
import MediaCache
import PhotosCore

struct TimelineDateMarker: Equatable, Sendable {
    enum Granularity: Equatable, Sendable {
        case day
        case month
        case year
    }

    let index: Int
    let date: Date
    let text: String
    let granularity: Granularity
}

/// Bridges the production timeline (`TimelineSection`/`PhotoItem` + the shared `ThumbnailFeed`) to the
/// Metal grid's `MetalGridDataSource`, and derives the month/year header markers. The production
/// timeline is delivered as a single ordered section, so a flat scan over its items is exact.
enum MetalGridProductionAdapter {
    @MainActor static func makeDataSource(
        sections: [TimelineSection],
        feed: ThumbnailFeed,
        metadataProvider: (any PhotoMetadataProvider)? = nil
    ) -> MetalGridDataSource {
        RealMetalGridDataSource(
            sections: sections,
            feed: feed,
            metadataProvider: metadataProvider
        )
    }

    /// Date markers over the single flattened production timeline. This is the pure foundation for Apple-like
    /// day/month/year navigation; the current grid UI renders only month markers on L4/L5.
    static func dateMarkers(
        sections: [TimelineSection], granularity: TimelineDateMarker.Granularity,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDateMarker] {
        dateMarkers(items: sections.flatMap { $0.items }, granularity: granularity, calendar: calendar, locale: locale)
    }

    /// Builds date markers in one pass over ordered items. Calendar work runs only when the current bucket changes.
    static func dateMarkers(
        items: [PhotoItem], granularity: TimelineDateMarker.Granularity,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDateMarker] {
        guard !items.isEmpty else { return [] }
        let component = calendarComponent(for: granularity)
        let formatter = makeFormatter(granularity: granularity, locale: locale)  // Reused for each boundary.
        var markers: [TimelineDateMarker] = []
        var bucketStart: Date?
        var bucketEnd: Date?
        for (i, item) in items.enumerated() {
            if i.isMultiple(of: 256), Task.isCancelled { return [] }
            let time = item.captureTime
            if let start = bucketStart, let end = bucketEnd, time >= start, time < end {
                continue  // The current marker already covers this bucket.
            }
            if let interval = calendar.dateInterval(of: component, for: time) {
                bucketStart = interval.start
                bucketEnd = interval.end
            } else {
                bucketStart = nil  // Emit each item when the calendar has no interval.
                bucketEnd = nil
            }
            markers.append(
                TimelineDateMarker(
                    index: i,
                    date: time,
                    text: formatter.string(from: time),
                    granularity: granularity))
        }
        return markers
    }

    private static func calendarComponent(for granularity: TimelineDateMarker.Granularity) -> Calendar.Component {
        switch granularity {
        case .day: .day
        case .month: .month
        case .year: .year
        }
    }

    /// Returns one localized marker for each month boundary.
    static func monthMarkers(sections: [TimelineSection]) -> [(index: Int, text: String)] {
        dateMarkers(sections: sections, granularity: .month).map { ($0.index, $0.text) }
    }

    /// One configured formatter per (granularity, locale), built once per `dateMarkers` call and reused for every
    /// boundary - DateFormatter construction is expensive, so do not allocate one per marker.
    private static func makeFormatter(granularity: TimelineDateMarker.Granularity, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch granularity {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        return formatter
    }
}
