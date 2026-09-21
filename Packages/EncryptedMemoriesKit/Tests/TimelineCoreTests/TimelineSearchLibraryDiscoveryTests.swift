import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineSearchLibraryDiscoveryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    // MARK: Structured result sets

    @Test func requiredUIDsNarrowAnEmptyQueryAndAndCombineWithText() {
        let a = item("a", date(2024, 5, 1), mediaType: "video/quicktime")
        let b = item("b", date(2024, 5, 2))
        let c = item("c", date(2024, 5, 3), mediaType: "video/mp4")
        let sections = [TimelineSection(id: "s", date: a.captureTime, title: "", items: [a, b, c])]

        let onlySet = TimelineSearch.filter(sections, query: "", requiredUIDs: [a.uid, b.uid])
        #expect(onlySet.flatMap(\.items).map(\.uid) == [a.uid, b.uid])

        let setAndText = TimelineSearch.filter(sections, query: "video", requiredUIDs: [a.uid, b.uid])
        #expect(setAndText.flatMap(\.items).map(\.uid) == [a.uid])

        let unfiltered = TimelineSearch.filter(sections, query: "")
        #expect(unfiltered.flatMap(\.items).count == 3)
    }

    @Test func suggestionProjectionKeepsSearchOrderInsteadOfTheRefinementReversal() {
        let older = item("older", date(2024, 5, 1))
        let newer = item("newer", date(2024, 5, 2))
        let sections = [TimelineSection(id: "s", date: older.captureTime, title: "", items: [older, newer])]
        let key = TimelineSearchProjectionKey(
            sourceRevision: 1,
            query: "",
            context: TimelineSearchContext(),
            semanticMatches: nil,
            refinement: TimelineRefinement(favoritesOnly: false, mediaKinds: [.photo]),
            requiredUIDs: [older.uid, newer.uid]
        )

        let projection = TimelineSearchProjection(key: key, sections: sections)

        #expect(projection.presentationItems.map(\.uid) == projection.snapshot.items.map(\.uid))
        #expect(projection.snapshot.items.count == 2)
    }

    @Test func aSuggestionOwnsOnlyItsUnchangedTitle() {
        let suggestion = TimelineSearchSuggestion(
            id: "place:Klosterneuburg",
            query: "Klosterneuburg",
            title: "Klosterneuburg",
            subtitle: nil,
            systemImage: "mappin",
            kind: .place,
            matchingUIDs: [],
            representativeUIDs: []
        )

        #expect(suggestion.owns(searchText: " klosterneuburg "))
        #expect(!suggestion.owns(searchText: "Klosterneuburg Kirche"))
        #expect(!suggestion.owns(searchText: ""))
    }

    // MARK: Metadata families

    @Test func onThisDayUsesPlusMinusThreeDaysInEarlierYearsAndNeedsThreeItems() {
        let now = date(2026, 9, 21)
        let inWindow = (0..<4).map { item("y1-\($0)", date(2025, 9, 19 + $0)) }
        let outsideWindow = item("y1-out", date(2025, 9, 10))
        let tooFewTwoYearsAgo = (0..<2).map { item("y2-\($0)", date(2024, 9, 21)) }

        let result = TimelineSearchDiscovery.onThisDaySuggestions(
            items: sorted(inWindow + [outsideWindow] + tooFewTwoYearsAgo),
            context: context(now: now)
        )

        #expect(result.map(\.id) == ["on-this-day:1"])
        #expect(result.first?.matchingUIDs == Set(inWindow.map(\.uid)))
        #expect(result.first?.representativeUIDs.count == 2)
        #expect(result.first?.kind == .onThisDay)
    }

    @Test func denseConsecutiveDaysMergeIntoOneTrip() {
        let quiet = (1...20).map { item("quiet-\($0)", date(2024, 3, $0)) }
        let dayOne = (0..<20).map { item("d1-\($0)", date(2024, 8, 3, hour: $0 % 24)) }
        let dayTwo = (0..<18).map { item("d2-\($0)", date(2024, 8, 4, hour: $0 % 24)) }

        let result = TimelineSearchDiscovery.tripSuggestions(
            items: sorted(quiet + dayOne + dayTwo),
            context: context(now: date(2026, 1, 1))
        )

        #expect(result.count == 1)
        #expect(result.first?.matchingUIDs == Set((dayOne + dayTwo).map(\.uid)))
        #expect(result.first?.kind == .trip)
    }

    @Test func seasonsSkipTheCurrentSeasonAndCountDecemberAsNextWinter() {
        let winter =
            (0..<10).map { item("dec-\($0)", date(2024, 12, 20)) }
            + (0..<10).map { item("jan-\($0)", date(2025, 1, 10)) }
        let currentSummer = (0..<30).map { item("now-\($0)", date(2026, 7, 1)) }

        let result = TimelineSearchDiscovery.seasonSuggestions(
            items: sorted(winter + currentSummer),
            context: context(now: date(2026, 7, 15))
        )

        #expect(result.map(\.id) == ["season:\(TimelineSearchSeason.winter.rawValue):2025"])
        #expect(result.first?.matchingUIDs == Set(winter.map(\.uid)))
        #expect(result.first?.title.hasSuffix("2024/25") == true)
    }

    @Test func mediaTypeChipsAppearOnlyWhenTheTypeDoesNotDominateTheLibrary() {
        let videos = (0..<3).map { item("v\($0)", date(2024, 1, 1 + $0), mediaType: "video/mp4") }
        let photos = (0..<7).map { item("p\($0)", date(2024, 2, 1 + $0)) }
        let mixed = [TimelineSection(id: "s", date: videos[0].captureTime, title: "", items: videos + photos)]

        let chips = TimelineSearchDiscovery.mediaTypeSuggestions(
            items: videos + photos, sections: mixed, context: context(now: date(2026, 1, 1)))
        #expect(chips.first { $0.id == "media:\(PhotoTag.videos.rawValue)" }?.matchingUIDs == Set(videos.map(\.uid)))

        let onlyVideos = [TimelineSection(id: "s", date: videos[0].captureTime, title: "", items: videos)]
        let dominated = TimelineSearchDiscovery.mediaTypeSuggestions(
            items: videos, sections: onlyVideos, context: context(now: date(2026, 1, 1)))
        #expect(!dominated.contains { $0.id == "media:\(PhotoTag.videos.rawValue)" })
    }

    // MARK: Places

    @Test func placeCandidatesMarkTheDominantCellAsHomeAndDropSparseCells() {
        let home = (0..<20).map { coordinate("h\($0)", 48.2082, 16.3738, date(2024, 1, 1 + $0 % 28)) }
        let trip = (0..<8).map { coordinate("t\($0)", 48.3064, 16.3259, date(2024, 4, 10 + $0 % 3)) }
        let sparse = (0..<2).map { coordinate("s\($0)", 41.3851, 2.1734, date(2023, 6, 1)) }
        let nullIsland = (0..<10).map { coordinate("z\($0)", 0, 0, date(2023, 6, 1)) }

        let candidates = TimelineSearchDiscovery.placeCandidates(coordinates: home + trip + sparse + nullIsland)

        #expect(candidates.count == 2)
        #expect(candidates.first?.isHome == false)
        #expect(candidates.first.map { Set($0.uids) } == Set(trip.map(\.uid)))
        #expect(candidates.last?.isHome == true)
    }

    @Test func placeSuggestionsMergeCellsWithTheSameNameAndAddTheDominantSeason() {
        let springItems = (0..<6).map { item("k\($0)", date(2024, 4, 10 + $0)) }
        let autumnItem = item("k-autumn", date(2023, 10, 1))
        let first = TimelineSearchPlaceCandidate(
            id: "a", latitude: 48.3, longitude: 16.3,
            uids: springItems.prefix(3).map(\.uid), dates: [], isHome: false)
        let second = TimelineSearchPlaceCandidate(
            id: "b", latitude: 48.31, longitude: 16.33,
            uids: springItems.suffix(3).map(\.uid) + [autumnItem.uid], dates: [], isHome: false)
        let itemsByUID = Dictionary(uniqueKeysWithValues: (springItems + [autumnItem]).map { ($0.uid, $0) })

        let result = TimelineSearchDiscovery.placeSuggestions(
            candidates: [first, second],
            names: ["a": "Klosterneuburg", "b": "Klosterneuburg"],
            itemsByUID: itemsByUID,
            context: context(now: date(2026, 9, 21))
        )

        let place = result.first { $0.kind == .place }
        let placeSeason = result.first { $0.kind == .placeSeason }
        #expect(place?.title == "Klosterneuburg")
        #expect(place?.matchingUIDs?.count == 7)
        #expect(placeSeason?.matchingUIDs == Set(springItems.map(\.uid)))
        #expect(placeSeason?.title.contains("Klosterneuburg") == true)
    }

    // MARK: Ranking and previews

    @Test func representativesPreferAFavoriteSkipExcludedItemsAndSpreadInTime() {
        let items = (1...10).map { item("r\($0)", date(2024, 1, $0)) }
        let favorite = items[2]
        let excluded = items[9]
        let context = TimelineSearchDiscoveryContext(
            now: date(2026, 1, 1), calendar: calendar,
            favoriteUIDs: [favorite.uid], excludedRepresentativeUIDs: [excluded.uid])

        let picked = TimelineSearchDiscovery.representatives(for: items, context: context)

        #expect(picked.first == favorite.uid)
        #expect(!picked.contains(excluded.uid))
        #expect(picked.last == items[8].uid)
    }

    @Test func rankingInterleavesFamiliesCapsEachKindAndDropsDuplicateResults() {
        func suggestion(
            _ id: String, _ kind: TimelineSearchSuggestionKind, _ uids: Set<PhotoUID>
        ) -> TimelineSearchSuggestion {
            TimelineSearchSuggestion(
                id: id, query: id, title: id, subtitle: nil, systemImage: "photo",
                kind: kind, matchingUIDs: uids, representativeUIDs: [])
        }
        let shared: Set<PhotoUID> = [uid("x")]
        let concepts = [
            suggestion("c1", .concept, [uid("1")]),
            suggestion("c2", .concept, [uid("2")]),
            suggestion("c3", .concept, [uid("3")]),
        ]
        let places = [suggestion("p1", .place, shared), suggestion("p2", .placeSeason, shared)]

        let ranked = TimelineSearchDiscovery.rankForYou([concepts, places], limit: 10, perKind: 2)

        #expect(ranked.map(\.id) == ["c1", "p1", "c2"])
    }

    // MARK: Fixtures

    private func context(now: Date) -> TimelineSearchDiscoveryContext {
        TimelineSearchDiscoveryContext(now: now, calendar: calendar, locale: Locale(identifier: "de_AT"))
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: id) }

    private func item(_ id: String, _ date: Date, mediaType: String = "image/jpeg") -> PhotoItem {
        PhotoItem(uid: uid(id), captureTime: date, mediaType: mediaType)
    }

    private func coordinate(_ id: String, _ latitude: Double, _ longitude: Double, _ date: Date) -> PhotoCoordinate {
        PhotoCoordinate(uid: uid(id), latitude: latitude, longitude: longitude, date: date)
    }

    private func sorted(_ items: [PhotoItem]) -> [PhotoItem] {
        items.sorted { $0.captureTime < $1.captureTime }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
