import Foundation
import PhotosCore

/// One date boundary in an ordered photo list: the flat index of the first photo of a day, month or year, with
/// its localized text.
public struct TimelineDateMarker: Equatable, Sendable {
    public enum Granularity: Equatable, Sendable {
        case day
        case month
        case year
    }

    /// How the marker text names the month.
    public enum MonthStyle: Equatable, Sendable {
        /// "Jan 2026": the compact Mac date navigation.
        case abbreviated
        /// "January 2026" ("Jänner 2026" in German for Austria): the transient scroll date label.
        case wide
    }

    public let index: Int
    public let date: Date
    public let text: String
    public let granularity: Granularity

    public init(index: Int, date: Date, text: String, granularity: Granularity) {
        self.index = index
        self.date = date
        self.text = text
        self.granularity = granularity
    }
}

/// Builds date markers over ordered photos. Shared by every platform, so the Mac date navigation and the scroll
/// date label read the same boundaries.
public enum TimelineDateMarkers {
    public static func markers(
        sections: [TimelineSection], granularity: TimelineDateMarker.Granularity,
        monthStyle: TimelineDateMarker.MonthStyle = .abbreviated,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDateMarker] {
        markers(
            items: sections.flatMap { $0.items }, granularity: granularity, monthStyle: monthStyle,
            calendar: calendar, locale: locale)
    }

    /// Builds date markers in one pass over ordered items. Calendar work runs only when the current bucket changes,
    /// and one formatter serves every boundary. A photo whose date has no calendar interval (an unusable date)
    /// starts no marker and stays in the bucket of the photo before it, so it never removes the other boundaries.
    /// Returns an empty list when the calling task is cancelled.
    public static func markers(
        items: [PhotoItem], granularity: TimelineDateMarker.Granularity,
        monthStyle: TimelineDateMarker.MonthStyle = .abbreviated,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDateMarker] {
        guard !items.isEmpty else { return [] }
        let component = calendarComponent(for: granularity)
        let formatter = makeFormatter(
            granularity: granularity, monthStyle: monthStyle, calendar: calendar, locale: locale)
        var markers: [TimelineDateMarker] = []
        var bucketStart: Date?
        var bucketEnd: Date?
        for (i, item) in items.enumerated() {
            if i.isMultiple(of: 256), Task.isCancelled { return [] }
            let time = item.captureTime
            if let start = bucketStart, let end = bucketEnd, time >= start, time < end {
                continue  // The current marker already covers this bucket.
            }
            guard time.timeIntervalSinceReferenceDate.isFinite,
                let interval = calendar.dateInterval(of: component, for: time)
            else { continue }  // An unusable date joins the current bucket.
            bucketStart = interval.start
            bucketEnd = interval.end
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

    /// One configured formatter per call, reused for every boundary: DateFormatter construction is expensive.
    private static func makeFormatter(
        granularity: TimelineDateMarker.Granularity, monthStyle: TimelineDateMarker.MonthStyle,
        calendar: Calendar, locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let month = monthStyle == .wide ? "MMMM" : "MMM"
        switch granularity {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("d \(month) yyyy")
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("\(month) yyyy")
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        return formatter
    }
}
