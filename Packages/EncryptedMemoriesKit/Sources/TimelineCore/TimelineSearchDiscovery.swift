import Foundation
import PhotosCore

/// A bounded, most-recent-first list shared by every native search surface.
public struct TimelineSearchHistory: Codable, Equatable, Sendable {
    public static let defaultLimit = 12

    public private(set) var queries: [String]

    public init(queries: [String] = [], limit: Int = defaultLimit) {
        self.queries = Self.normalized(queries, limit: limit)
    }

    public mutating func record(_ rawQuery: String, limit: Int = defaultLimit) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        queries.removeAll { $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        queries.insert(query, at: 0)
        if queries.count > max(0, limit) {
            queries.removeLast(queries.count - max(0, limit))
        }
    }

    public mutating func clear() {
        queries.removeAll(keepingCapacity: false)
    }

    private static func normalized(_ input: [String], limit: Int) -> [String] {
        var result: [String] = []
        for rawQuery in input {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            guard
                !result.contains(where: {
                    $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })
            else { continue }
            result.append(query)
            if result.count == max(0, limit) { break }
        }
        return result
    }
}

/// A lexical suggestion that remains useful when optional on-device ML search is unavailable.
public struct TimelineSearchSuggestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let query: String
    public let title: String
    public let representativeUID: PhotoUID?

    public init(id: String, query: String, title: String, representativeUID: PhotoUID? = nil) {
        self.id = id
        self.query = query
        self.title = title
        self.representativeUID = representativeUID
    }
}

public enum TimelineSearchDiscovery {
    public static func recentDateSuggestions(
        sections: [TimelineSection],
        limit: Int = 6,
        locale: Locale = .current
    ) -> [TimelineSearchSuggestion] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return recentDateSuggestions(
            sections: sections,
            limit: limit,
            calendar: calendar,
            locale: locale
        )
    }

    /// Produces localized recent-day suggestions from timeline metadata only.
    /// The query uses an ISO day, which the lexical search understands in every app language.
    public static func recentDateSuggestions(
        sections: [TimelineSection],
        limit: Int = 6,
        calendar: Calendar,
        locale: Locale = .current
    ) -> [TimelineSearchSuggestion] {
        guard limit > 0 else { return [] }
        var firstItemByDay: [Date: PhotoItem] = [:]
        for section in sections {
            guard !Task.isCancelled else { return [] }
            for item in section.items {
                let day = calendar.startOfDay(for: item.captureTime)
                if let current = firstItemByDay[day] {
                    if item.captureTime > current.captureTime {
                        firstItemByDay[day] = item
                    }
                } else {
                    firstItemByDay[day] = item
                }
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none

        return firstItemByDay.keys.sorted(by: >).prefix(limit).compactMap { day in
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let dayOfMonth = components.day,
                let item = firstItemByDay[day]
            else { return nil }
            let query = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
            return TimelineSearchSuggestion(
                id: "date:\(query)",
                query: query,
                title: formatter.string(from: day),
                representativeUID: item.uid
            )
        }
    }
}
