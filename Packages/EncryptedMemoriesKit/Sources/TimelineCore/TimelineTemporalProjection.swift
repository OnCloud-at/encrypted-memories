import Foundation
import PhotosCore

/// The temporal library presentation selected by a platform adapter.
public enum TimelineTemporalMode: String, CaseIterable, Codable, Sendable {
    case years
    case months
    case allPhotos
}

/// The lifecycle state of a temporal projection snapshot.
public enum TimelineTemporalProjectionStatus: Equatable, Sendable {
    case loading
    case ready
    case empty
}

/// Optional labels supplied by a platform or a local metadata store.
///
/// Core does not resolve places or contact a network service. Labels apply only to matching photo UIDs.
public struct TimelineTemporalEnrichment: Equatable, Sendable {
    public let placeLabelsByUID: [PhotoUID: String]
    public let eventLabelsByUID: [PhotoUID: String]

    public init(
        placeLabelsByUID: [PhotoUID: String] = [:],
        eventLabelsByUID: [PhotoUID: String] = [:]
    ) {
        self.placeLabelsByUID = placeLabelsByUID
        self.eventLabelsByUID = eventLabelsByUID
    }

    public func placeLabel(for uid: PhotoUID) -> String? {
        placeLabelsByUID[uid]
    }

    public func eventLabel(for uid: PhotoUID) -> String? {
        eventLabelsByUID[uid]
    }
}

/// One event bucket inside a calendar day.
public struct TimelineTemporalEventGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let eventLabel: String?
    public let dateInterval: DateInterval
    public let itemCount: Int
    public let representativeItemUID: PhotoUID
    public let itemUIDs: [PhotoUID]
    public let placeLabels: [String]

    public var photoUIDs: [PhotoUID] { itemUIDs }
    public var placeLabel: String? { placeLabels.count == 1 ? placeLabels[0] : nil }
}

/// One calendar day with direct photo navigation and optional event buckets.
public struct TimelineTemporalDayGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dateInterval: DateInterval
    public let itemCount: Int
    public let representativeItemUID: PhotoUID
    public let itemUIDs: [PhotoUID]
    public let events: [TimelineTemporalEventGroup]
    public let placeLabels: [String]

    public var photoUIDs: [PhotoUID] { itemUIDs }
    public var eventGroups: [TimelineTemporalEventGroup] { events }
    public var placeLabel: String? { placeLabels.count == 1 ? placeLabels[0] : nil }
}

/// One calendar month with day and event drill-down data.
public struct TimelineTemporalMonthGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dateInterval: DateInterval
    public let itemCount: Int
    public let representativeItemUID: PhotoUID
    public let dayGroups: [TimelineTemporalDayGroup]
    public let placeLabels: [String]

    public var days: [TimelineTemporalDayGroup] { dayGroups }
    public var itemUIDs: [PhotoUID] { dayGroups.flatMap(\.itemUIDs) }
    public var photoUIDs: [PhotoUID] { itemUIDs }
    public var placeLabel: String? { placeLabels.count == 1 ? placeLabels[0] : nil }

    /// A stable editorial subset for the Apple-style month overview.
    ///
    /// The representative day becomes the hero. Up to three supporting days span the remaining
    /// month, so a dense month does not collapse into several adjacent dates.
    public var editorialSelection: TimelineTemporalMonthEditorialSelection? {
        guard
            let heroDay = dayGroups.first(where: { day in
                day.itemUIDs.contains(representativeItemUID)
            }) ?? dayGroups.last
        else {
            return nil
        }

        let candidates = dayGroups.filter { $0.id != heroDay.id }
        let supportDays: [TimelineTemporalDayGroup]
        if candidates.count <= 3 {
            supportDays = candidates
        } else {
            let lastIndex = candidates.count - 1
            let indexes = [0, lastIndex / 2, lastIndex]
            supportDays = indexes.map { candidates[$0] }
        }

        return TimelineTemporalMonthEditorialSelection(
            heroDay: heroDay,
            supportDays: supportDays
        )
    }
}

/// The curated month composition shared by platform presentations.
public struct TimelineTemporalMonthEditorialSelection: Equatable, Sendable {
    public let heroDay: TimelineTemporalDayGroup
    public let supportDays: [TimelineTemporalDayGroup]

    public init(
        heroDay: TimelineTemporalDayGroup,
        supportDays: [TimelineTemporalDayGroup]
    ) {
        self.heroDay = heroDay
        self.supportDays = supportDays
    }
}

/// One calendar year with month, day, and event drill-down data.
public struct TimelineTemporalYearGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dateInterval: DateInterval
    public let itemCount: Int
    public let representativeItemUID: PhotoUID
    public let monthGroups: [TimelineTemporalMonthGroup]
    public let placeLabels: [String]

    public var months: [TimelineTemporalMonthGroup] { monthGroups }
    public var itemUIDs: [PhotoUID] { monthGroups.flatMap(\.itemUIDs) }
    public var photoUIDs: [PhotoUID] { itemUIDs }
    public var placeLabel: String? { placeLabels.count == 1 ? placeLabels[0] : nil }
}

/// The top-level group used by the all-photos mode.
public struct TimelineTemporalAllPhotosGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dateInterval: DateInterval
    public let itemCount: Int
    public let representativeItemUID: PhotoUID
    public let dayGroups: [TimelineTemporalDayGroup]
    public let placeLabels: [String]

    public var days: [TimelineTemporalDayGroup] { dayGroups }
    public var itemUIDs: [PhotoUID] { dayGroups.flatMap(\.itemUIDs) }
    public var photoUIDs: [PhotoUID] { itemUIDs }
    public var placeLabel: String? { placeLabels.count == 1 ? placeLabels[0] : nil }
}

/// A mode-independent view of a top-level temporal group.
public enum TimelineTemporalGroup: Equatable, Sendable {
    case year(TimelineTemporalYearGroup)
    case month(TimelineTemporalMonthGroup)
    case allPhotos(TimelineTemporalAllPhotosGroup)
}

/// A deterministic temporal projection over the canonical timeline.
///
/// The projection keeps photo UIDs in canonical order. Group arrays use first-seen canonical order.
/// Use `build` when the work must run off an actor and observe cancellation.
public struct TimelineTemporalProjection: Equatable, Sendable {
    public let mode: TimelineTemporalMode
    public let status: TimelineTemporalProjectionStatus
    public let itemCount: Int
    public let items: [PhotoItem]
    public let yearGroups: [TimelineTemporalYearGroup]
    public let monthGroups: [TimelineTemporalMonthGroup]
    public let allPhotos: TimelineTemporalAllPhotosGroup?

    private let snapshot: TimelineSnapshot

    public var isLoading: Bool { status == .loading }
    public var isReady: Bool { status == .ready }
    public var isEmpty: Bool { status == .empty }

    /// The top-level groups for the selected mode.
    public var groups: [TimelineTemporalGroup] {
        switch mode {
        case .years:
            return yearGroups.map(TimelineTemporalGroup.year)
        case .months:
            return monthGroups.map(TimelineTemporalGroup.month)
        case .allPhotos:
            return allPhotos.map { [.allPhotos($0)] } ?? []
        }
    }

    /// Creates a ready or empty projection from a stable calendar and time-zone configuration.
    ///
    /// The caller must not pass an auto-updating calendar when it needs stable persisted group IDs.
    public init(
        mode: TimelineTemporalMode,
        sections: [TimelineSection],
        calendar: Calendar,
        enrichment: TimelineTemporalEnrichment = TimelineTemporalEnrichment()
    ) {
        self = try! Self.make(
            mode: mode,
            sections: sections,
            calendar: calendar,
            enrichment: enrichment,
            checkCancellation: false
        )
    }

    /// Creates an explicit loading snapshot with no content groups.
    public static func loading(mode: TimelineTemporalMode) -> TimelineTemporalProjection {
        TimelineTemporalProjection(
            mode: mode,
            status: .loading,
            itemCount: 0,
            items: [],
            yearGroups: [],
            monthGroups: [],
            allPhotos: nil,
            snapshot: TimelineSnapshot()
        )
    }

    /// Builds the projection on a detached task and checks cancellation during the scan.
    public static func build(
        mode: TimelineTemporalMode,
        sections: [TimelineSection],
        calendar: Calendar,
        enrichment: TimelineTemporalEnrichment = TimelineTemporalEnrichment()
    ) async throws -> TimelineTemporalProjection {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try TimelineTemporalProjection.make(
                mode: mode,
                sections: sections,
                calendar: calendar,
                enrichment: enrichment,
                checkCancellation: true
            )
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Returns a canonical item for a navigation UID.
    public func item(for uid: PhotoUID) -> PhotoItem? {
        snapshot.item(for: uid)
    }

    private init(
        mode: TimelineTemporalMode,
        status: TimelineTemporalProjectionStatus,
        itemCount: Int,
        items: [PhotoItem],
        yearGroups: [TimelineTemporalYearGroup],
        monthGroups: [TimelineTemporalMonthGroup],
        allPhotos: TimelineTemporalAllPhotosGroup?,
        snapshot: TimelineSnapshot
    ) {
        self.mode = mode
        self.status = status
        self.itemCount = itemCount
        self.items = items
        self.yearGroups = yearGroups
        self.monthGroups = monthGroups
        self.allPhotos = allPhotos
        self.snapshot = snapshot
    }

    private static func make(
        mode: TimelineTemporalMode,
        sections: [TimelineSection],
        calendar: Calendar,
        enrichment: TimelineTemporalEnrichment,
        checkCancellation: Bool
    ) throws -> TimelineTemporalProjection {
        if checkCancellation { try Task.checkCancellation() }

        let snapshot = try TimelineSnapshot(
            canonicalizing: sections,
            checkCancellation: checkCancellation
        )
        let items = snapshot.items

        guard !items.isEmpty else {
            return TimelineTemporalProjection(
                mode: mode,
                status: .empty,
                itemCount: 0,
                items: [],
                yearGroups: [],
                monthGroups: [],
                allPhotos: nil,
                snapshot: snapshot
            )
        }

        var yearBuilders: [YearKey: MutableYear] = [:]
        var yearOrder: [YearKey] = []
        var monthBuilders: [MonthKey: MutableMonth] = [:]
        var monthOrder: [MonthKey] = []
        var dayBuilders: [DayKey: MutableDay] = [:]
        var dayOrder: [DayKey] = []

        var allCover = items[0]
        var allPlaces = OrderedLabels()

        for (index, item) in items.enumerated() {
            if checkCancellation && index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            let parts = parts(for: item.captureTime, calendar: calendar)
            let yearKey = YearKey(era: parts.era, year: parts.year)
            let monthKey = MonthKey(era: parts.era, year: parts.year, month: parts.month)
            let dayKey = DayKey(era: parts.era, year: parts.year, month: parts.month, day: parts.day)
            let yearInterval = interval(.year, for: item.captureTime, calendar: calendar)
            let monthInterval = interval(.month, for: item.captureTime, calendar: calendar)
            let dayInterval = interval(.day, for: item.captureTime, calendar: calendar)
            let dayTitle = Self.dayTitle(for: dayKey)
            let placeLabel = cleanedLabel(enrichment.placeLabel(for: item.uid))
            let eventLabel = cleanedLabel(enrichment.eventLabel(for: item.uid))
            let eventKey: EventBucketKey = eventLabel.map(EventBucketKey.labeled) ?? .unlabeled

            if isPreferredCover(item, over: allCover) {
                allCover = item
            }
            allPlaces.append(placeLabel)

            let isNewYear = yearBuilders[yearKey] == nil
            let isNewMonth = monthBuilders[monthKey] == nil
            let isNewDay = dayBuilders[dayKey] == nil

            if isNewYear {
                yearOrder.append(yearKey)
                yearBuilders[yearKey] = MutableYear(
                    key: yearKey,
                    interval: yearInterval,
                    item: item,
                    placeLabel: placeLabel
                )
            } else {
                var year = yearBuilders[yearKey]!
                year.append(item, placeLabel: placeLabel)
                yearBuilders[yearKey] = year
            }

            if isNewMonth {
                monthOrder.append(monthKey)
                monthBuilders[monthKey] = MutableMonth(
                    key: monthKey,
                    interval: monthInterval,
                    item: item,
                    placeLabel: placeLabel
                )
            } else {
                var month = monthBuilders[monthKey]!
                month.append(item, placeLabel: placeLabel)
                monthBuilders[monthKey] = month
            }

            if isNewDay {
                dayOrder.append(dayKey)
                dayBuilders[dayKey] = MutableDay(
                    key: dayKey,
                    interval: dayInterval,
                    title: dayTitle,
                    item: item,
                    eventKey: eventKey,
                    eventLabel: eventLabel,
                    placeLabel: placeLabel
                )
            } else {
                var day = dayBuilders[dayKey]!
                day.append(
                    item,
                    title: dayTitle,
                    eventKey: eventKey,
                    eventLabel: eventLabel,
                    placeLabel: placeLabel
                )
                dayBuilders[dayKey] = day
            }

            if isNewMonth {
                var year = yearBuilders[yearKey]!
                year.monthKeys.append(monthKey)
                yearBuilders[yearKey] = year
            }
            if isNewDay {
                var month = monthBuilders[monthKey]!
                month.dayKeys.append(dayKey)
                monthBuilders[monthKey] = month
            }
        }

        if checkCancellation { try Task.checkCancellation() }

        let dayGroupsByKey = makeDayGroups(dayOrder: dayOrder, builders: dayBuilders)
        let dayGroups = dayOrder.compactMap { dayGroupsByKey[$0] }

        switch mode {
        case .years:
            let monthGroupsByKey = makeMonthGroups(
                monthOrder: monthOrder,
                builders: monthBuilders,
                dayGroupsByKey: dayGroupsByKey
            )
            let yearGroups = yearOrder.compactMap { key -> TimelineTemporalYearGroup? in
                guard let builder = yearBuilders[key] else { return nil }
                let months = builder.monthKeys.compactMap { monthGroupsByKey[$0] }
                return makeYearGroup(builder: builder, monthGroups: months)
            }
            return TimelineTemporalProjection(
                mode: mode,
                status: .ready,
                itemCount: items.count,
                items: items,
                yearGroups: yearGroups,
                monthGroups: [],
                allPhotos: nil,
                snapshot: snapshot
            )

        case .months:
            let monthGroupsByKey = makeMonthGroups(
                monthOrder: monthOrder,
                builders: monthBuilders,
                dayGroupsByKey: dayGroupsByKey
            )
            let monthGroups = monthOrder.compactMap { monthGroupsByKey[$0] }
            return TimelineTemporalProjection(
                mode: mode,
                status: .ready,
                itemCount: items.count,
                items: items,
                yearGroups: [],
                monthGroups: monthGroups,
                allPhotos: nil,
                snapshot: snapshot
            )

        case .allPhotos:
            let allGroup = TimelineTemporalAllPhotosGroup(
                id: "all-photos",
                title: L10n.string("library.view_all_photos"),
                dateInterval: span(for: items, calendar: calendar),
                itemCount: items.count,
                representativeItemUID: allCover.uid,
                dayGroups: dayGroups,
                placeLabels: allPlaces.values
            )
            return TimelineTemporalProjection(
                mode: mode,
                status: .ready,
                itemCount: items.count,
                items: items,
                yearGroups: [],
                monthGroups: [],
                allPhotos: allGroup,
                snapshot: snapshot
            )
        }
    }

    private static func makeDayGroups(
        dayOrder: [DayKey],
        builders: [DayKey: MutableDay]
    ) -> [DayKey: TimelineTemporalDayGroup] {
        var result: [DayKey: TimelineTemporalDayGroup] = [:]
        result.reserveCapacity(dayOrder.count)
        for key in dayOrder {
            guard let builder = builders[key] else { continue }
            let events = builder.eventOrder.compactMap { builder.events[$0] }.map(makeEventGroup)
            let itemUIDs = events.flatMap(\.itemUIDs)
            result[key] = TimelineTemporalDayGroup(
                id: builder.id,
                title: builder.title,
                dateInterval: builder.interval,
                itemCount: builder.itemCount,
                representativeItemUID: builder.cover.uid,
                itemUIDs: itemUIDs,
                events: events,
                placeLabels: builder.places.values
            )
        }
        return result
    }

    private static func makeMonthGroups(
        monthOrder: [MonthKey],
        builders: [MonthKey: MutableMonth],
        dayGroupsByKey: [DayKey: TimelineTemporalDayGroup]
    ) -> [MonthKey: TimelineTemporalMonthGroup] {
        var result: [MonthKey: TimelineTemporalMonthGroup] = [:]
        result.reserveCapacity(monthOrder.count)
        for key in monthOrder {
            guard let builder = builders[key] else { continue }
            let days = builder.dayKeys.compactMap { dayGroupsByKey[$0] }
            result[key] = TimelineTemporalMonthGroup(
                id: builder.id,
                title: builder.title,
                dateInterval: builder.interval,
                itemCount: builder.itemCount,
                representativeItemUID: builder.cover.uid,
                dayGroups: days,
                placeLabels: builder.places.values
            )
        }
        return result
    }

    private static func makeYearGroup(
        builder: MutableYear,
        monthGroups: [TimelineTemporalMonthGroup]
    ) -> TimelineTemporalYearGroup {
        TimelineTemporalYearGroup(
            id: builder.id,
            title: builder.title,
            dateInterval: builder.interval,
            itemCount: builder.itemCount,
            representativeItemUID: builder.cover.uid,
            monthGroups: monthGroups,
            placeLabels: builder.places.values
        )
    }

    private static func makeEventGroup(_ builder: MutableEvent) -> TimelineTemporalEventGroup {
        TimelineTemporalEventGroup(
            id: builder.id,
            title: builder.title,
            eventLabel: builder.eventLabel,
            dateInterval: builder.interval,
            itemCount: builder.itemUIDs.count,
            representativeItemUID: builder.cover.uid,
            itemUIDs: builder.itemUIDs,
            placeLabels: builder.places.values
        )
    }

    private static func parts(for date: Date, calendar: Calendar) -> TemporalDateParts {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return TemporalDateParts(
            era: components.era ?? 1,
            year: components.year ?? 0,
            month: max(1, components.month ?? 1),
            day: max(1, components.day ?? 1)
        )
    }

    private static func interval(
        _ component: Calendar.Component,
        for date: Date,
        calendar: Calendar
    ) -> DateInterval {
        calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    private static func span(for items: [PhotoItem], calendar: Calendar) -> DateInterval {
        let first = interval(.day, for: items[0].captureTime, calendar: calendar)
        let last = interval(.day, for: items[items.count - 1].captureTime, calendar: calendar)
        return DateInterval(start: first.start, duration: max(0, last.end.timeIntervalSince(first.start)))
    }

    fileprivate static func dayTitle(for key: DayKey) -> String {
        "\(key.year)-\(twoDigits(key.month))-\(twoDigits(key.day))"
    }

    fileprivate static func yearTitle(for key: YearKey) -> String {
        key.era == 1 ? "\(key.year)" : "\(key.era)-\(key.year)"
    }

    fileprivate static func monthTitle(for key: MonthKey) -> String {
        "\(key.year)-\(twoDigits(key.month))"
    }

    fileprivate static func yearID(for key: YearKey) -> String {
        "year-\(yearComponent(era: key.era, year: key.year))"
    }

    fileprivate static func monthID(for key: MonthKey) -> String {
        "month-\(yearComponent(era: key.era, year: key.year))-\(twoDigits(key.month))"
    }

    fileprivate static func dayID(for key: DayKey) -> String {
        "day-\(yearComponent(era: key.era, year: key.year))-\(twoDigits(key.month))-\(twoDigits(key.day))"
    }

    private static func yearComponent(era: Int, year: Int) -> String {
        era == 1 ? "\(year)" : "\(era)-\(year)"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func cleanedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    fileprivate static func isPreferredCover(_ candidate: PhotoItem, over current: PhotoItem) -> Bool {
        let candidateScore = coverScore(candidate)
        let currentScore = coverScore(current)
        if candidateScore != currentScore { return candidateScore > currentScore }
        if candidate.captureTime != current.captureTime {
            return candidate.captureTime > current.captureTime
        }

        let candidateHash = stableUIDHash(candidate.uid)
        let currentHash = stableUIDHash(current.uid)
        if candidateHash != currentHash { return candidateHash > currentHash }
        return compareUID(candidate.uid, current.uid) > 0
    }

    private static func coverScore(_ item: PhotoItem) -> Int {
        var score = item.isVideo ? 0 : 1_000
        score += isScreenshot(item) ? 0 : 100
        score += isRaw(item) ? 0 : 50
        if item.tags.contains(.favorites) { score += 10 }
        if item.tags.contains(.portraits) { score += 4 }
        if item.tags.contains(.panoramas) { score += 2 }
        if item.isLivePhoto { score += 1 }
        return score
    }

    private static func isScreenshot(_ item: PhotoItem) -> Bool {
        item.tags.contains(.screenshots) || item.mediaType.lowercased() == "image/png"
    }

    private static func isRaw(_ item: PhotoItem) -> Bool {
        if item.tags.contains(.raw) { return true }
        let mediaType = item.mediaType.lowercased()
        return mediaType.contains("raw")
            || mediaType.contains("dng")
            || mediaType.contains("x-canon-cr2")
            || mediaType.contains("x-canon-cr3")
            || mediaType.contains("x-nikon-nef")
            || mediaType.contains("x-sony-arw")
            || mediaType.contains("x-panasonic-rw2")
            || mediaType.contains("x-fuji-raf")
    }

    private static func stableUIDHash(_ uid: PhotoUID) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in uid.volumeID.utf8 + [0] + uid.nodeID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func compareUID(_ lhs: PhotoUID, _ rhs: PhotoUID) -> Int {
        if lhs.volumeID.utf8.lexicographicallyPrecedes(rhs.volumeID.utf8) { return -1 }
        if rhs.volumeID.utf8.lexicographicallyPrecedes(lhs.volumeID.utf8) { return 1 }
        if lhs.nodeID.utf8.lexicographicallyPrecedes(rhs.nodeID.utf8) { return -1 }
        if rhs.nodeID.utf8.lexicographicallyPrecedes(lhs.nodeID.utf8) { return 1 }
        return 0
    }
}

private struct TemporalDateParts: Sendable {
    let era: Int
    let year: Int
    let month: Int
    let day: Int
}

private struct YearKey: Hashable, Sendable {
    let era: Int
    let year: Int
}

private struct MonthKey: Hashable, Sendable {
    let era: Int
    let year: Int
    let month: Int
}

private struct DayKey: Hashable, Sendable {
    let era: Int
    let year: Int
    let month: Int
    let day: Int
}

private enum EventBucketKey: Hashable, Sendable {
    case unlabeled
    case labeled(String)
}

private struct OrderedLabels: Sendable {
    private(set) var values: [String] = []
    private var seen: Set<String> = []

    mutating func append(_ label: String?) {
        guard let label else { return }
        guard seen.insert(label).inserted else { return }
        values.append(label)
    }
}

private struct MutableEvent {
    let id: String
    let title: String
    let eventLabel: String?
    let interval: DateInterval
    var itemUIDs: [PhotoUID]
    var cover: PhotoItem
    var places: OrderedLabels

    init(
        id: String,
        title: String,
        eventLabel: String?,
        interval: DateInterval,
        item: PhotoItem,
        placeLabel: String?
    ) {
        self.id = id
        self.title = title
        self.eventLabel = eventLabel
        self.interval = interval
        itemUIDs = [item.uid]
        cover = item
        places = OrderedLabels()
        places.append(placeLabel)
    }

    mutating func append(_ item: PhotoItem, placeLabel: String?) {
        itemUIDs.append(item.uid)
        if TimelineTemporalProjection.isPreferredCover(item, over: cover) {
            cover = item
        }
        places.append(placeLabel)
    }
}

private struct MutableDay {
    let key: DayKey
    let id: String
    let interval: DateInterval
    let fallbackTitle: String
    var title: String
    var itemCount: Int
    var cover: PhotoItem
    var places: OrderedLabels
    var eventOrder: [EventBucketKey]
    var events: [EventBucketKey: MutableEvent]

    init(
        key: DayKey,
        interval: DateInterval,
        title: String,
        item: PhotoItem,
        eventKey: EventBucketKey,
        eventLabel: String?,
        placeLabel: String?
    ) {
        self.key = key
        id = TimelineTemporalProjection.dayID(for: key)
        self.interval = interval
        fallbackTitle = TimelineTemporalProjection.dayTitle(for: key)
        self.title = title
        itemCount = 1
        cover = item
        places = OrderedLabels()
        places.append(placeLabel)
        eventOrder = [eventKey]
        events = [
            eventKey: MutableDay.makeEvent(
                key: eventKey,
                dayID: id,
                dayTitle: title,
                interval: interval,
                item: item,
                eventLabel: eventLabel,
                placeLabel: placeLabel
            )
        ]
    }

    mutating func append(
        _ item: PhotoItem,
        title: String,
        eventKey: EventBucketKey,
        eventLabel: String?,
        placeLabel: String?
    ) {
        itemCount += 1
        if self.title == fallbackTitle, title != fallbackTitle {
            self.title = title
        }
        if TimelineTemporalProjection.isPreferredCover(item, over: cover) {
            cover = item
        }
        places.append(placeLabel)

        if var event = events[eventKey] {
            event.append(item, placeLabel: placeLabel)
            events[eventKey] = event
        } else {
            eventOrder.append(eventKey)
            events[eventKey] = Self.makeEvent(
                key: eventKey,
                dayID: id,
                dayTitle: self.title,
                interval: interval,
                item: item,
                eventLabel: eventLabel,
                placeLabel: placeLabel
            )
        }
    }

    private static func makeEvent(
        key: EventBucketKey,
        dayID: String,
        dayTitle: String,
        interval: DateInterval,
        item: PhotoItem,
        eventLabel: String?,
        placeLabel: String?
    ) -> MutableEvent {
        let title = eventLabel ?? dayTitle
        return MutableEvent(
            id: TimelineTemporalProjection.eventID(dayID: dayID, key: key),
            title: title,
            eventLabel: eventLabel,
            interval: interval,
            item: item,
            placeLabel: placeLabel
        )
    }
}

private struct MutableMonth {
    let key: MonthKey
    let id: String
    let title: String
    let interval: DateInterval
    var itemCount: Int
    var cover: PhotoItem
    var places: OrderedLabels
    var dayKeys: [DayKey]

    init(key: MonthKey, interval: DateInterval, item: PhotoItem, placeLabel: String?) {
        self.key = key
        id = TimelineTemporalProjection.monthID(for: key)
        title = TimelineTemporalProjection.monthTitle(for: key)
        self.interval = interval
        itemCount = 1
        cover = item
        places = OrderedLabels()
        places.append(placeLabel)
        dayKeys = []
    }

    mutating func append(_ item: PhotoItem, placeLabel: String?) {
        itemCount += 1
        if TimelineTemporalProjection.isPreferredCover(item, over: cover) {
            cover = item
        }
        places.append(placeLabel)
    }
}

private struct MutableYear {
    let key: YearKey
    let id: String
    let title: String
    let interval: DateInterval
    var itemCount: Int
    var cover: PhotoItem
    var places: OrderedLabels
    var monthKeys: [MonthKey]

    init(key: YearKey, interval: DateInterval, item: PhotoItem, placeLabel: String?) {
        self.key = key
        id = TimelineTemporalProjection.yearID(for: key)
        title = TimelineTemporalProjection.yearTitle(for: key)
        self.interval = interval
        itemCount = 1
        cover = item
        places = OrderedLabels()
        places.append(placeLabel)
        monthKeys = []
    }

    mutating func append(_ item: PhotoItem, placeLabel: String?) {
        itemCount += 1
        if TimelineTemporalProjection.isPreferredCover(item, over: cover) {
            cover = item
        }
        places.append(placeLabel)
    }
}

fileprivate extension TimelineTemporalProjection {
    static func eventID(dayID: String, key: EventBucketKey) -> String {
        switch key {
        case .unlabeled:
            return "\(dayID)-event-unlabeled"
        case .labeled(let label):
            return "\(dayID)-event-\(hexIdentifier(label))"
        }
    }

    static func hexIdentifier(_ value: String) -> String {
        let digits = Array("0123456789abcdef")
        return value.utf8.reduce(into: "") { result, byte in
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
    }
}
