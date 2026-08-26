import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineTemporalProjectionTests {
    @Test func yearsProjectionUsesCanonicalOrderAndNestedDrillDown() {
        let early = item("early", date: date(2025, 12, 31, 20, 0))
        let late = item("late", date: date(2026, 1, 2, 12, 0))
        let middle = item("middle", date: date(2026, 1, 1, 12, 0))
        let sections = [
            section("January", [late, middle]),
            section("December", [early]),
        ]

        let projection = TimelineTemporalProjection(
            mode: .years,
            sections: sections,
            calendar: Self.calendar
        )

        #expect(projection.status == .ready)
        #expect(projection.items.map(\.uid.nodeID) == ["early", "middle", "late"])
        #expect(projection.yearGroups.map(\.id) == ["year-2025", "year-2026"])
        #expect(projection.yearGroups[1].monthGroups.map(\.id) == ["month-2026-01"])
        #expect(
            projection.yearGroups[1].monthGroups[0].dayGroups.map(\.itemUIDs) == [
                [middle.uid], [late.uid],
            ])
        #expect(projection.yearGroups[1].itemUIDs == [middle.uid, late.uid])
        #expect(projection.item(for: middle.uid) == middle)
        #expect(projection.yearGroups[1].itemCount == 2)
        #expect(projection.yearGroups[1].representativeItemUID == late.uid)
        #expect(projection.yearGroups[1].dateInterval == interval(.year, date(2026, 1, 1)))
    }

    @Test func monthModeExposesDayEventPhotoNavigation() {
        let first = item("first", date: date(2026, 3, 4, 10, 0))
        let second = item("second", date: date(2026, 3, 4, 11, 0))
        let third = item("third", date: date(2026, 3, 5, 10, 0))
        let enrichment = TimelineTemporalEnrichment(
            placeLabelsByUID: [first.uid: "Vienna", second.uid: "Vienna", third.uid: "Graz"],
            eventLabelsByUID: [first.uid: "Museum", second.uid: "Museum"]
        )

        let projection = TimelineTemporalProjection(
            mode: .months,
            sections: [section("March", [third, second, first])],
            calendar: Self.calendar,
            enrichment: enrichment
        )

        let month = projection.monthGroups.single
        #expect(month.itemCount == 3)
        #expect(month.dayGroups.map(\.itemCount) == [2, 1])
        #expect(month.dayGroups[0].events.count == 1)
        #expect(month.dayGroups[0].events[0].eventLabel == "Museum")
        #expect(month.dayGroups[0].events[0].itemUIDs == [first.uid, second.uid])
        #expect(month.dayGroups[0].itemUIDs == [first.uid, second.uid])
        #expect(month.dayGroups[0].placeLabels == ["Vienna"])
        #expect(month.placeLabels == ["Vienna", "Graz"])
    }

    @Test func allPhotosModeHasExplicitReadyAndEmptyStates() {
        let photo = item("photo", date: date(2026, 4, 1))
        let ready = TimelineTemporalProjection(
            mode: .allPhotos,
            sections: [section("April", [photo])],
            calendar: Self.calendar
        )
        let empty = TimelineTemporalProjection(
            mode: .allPhotos,
            sections: [],
            calendar: Self.calendar
        )
        let loading = TimelineTemporalProjection.loading(mode: .allPhotos)

        #expect(ready.isReady)
        #expect(ready.allPhotos?.itemCount == 1)
        #expect(ready.groups.count == 1)
        #expect(empty.status == .empty)
        #expect(empty.groups.isEmpty)
        #expect(loading.status == .loading)
    }

    @Test func coverSelectionPrefersQualityThenLatestDeterministically() {
        let firstPlain = item("first-plain", date: date(2026, 5, 1, 10, 0))
        let video = item("video", date: date(2026, 5, 1, 11, 0), mediaType: "video/quicktime")
        let screenshot = item(
            "screenshot",
            date: date(2026, 5, 1, 12, 0),
            mediaType: "image/png",
            tags: [.screenshots]
        )
        let raw = item(
            "raw",
            date: date(2026, 5, 1, 13, 0),
            mediaType: "image/x-adobe-dng",
            tags: [.raw]
        )
        let latestPlain = item("latest-plain", date: date(2026, 5, 1, 14, 0))

        let projection = TimelineTemporalProjection(
            mode: .allPhotos,
            sections: [section("May", [firstPlain, video, screenshot, raw, latestPlain])],
            calendar: Self.calendar
        )

        #expect(projection.allPhotos?.representativeItemUID == latestPlain.uid)
        #expect(projection.allPhotos?.dayGroups.single.representativeItemUID == latestPlain.uid)
        #expect(projection.allPhotos?.dayGroups.single.events.single.representativeItemUID == latestPlain.uid)
    }

    @Test func monthEditorialSelectionUsesCoverDayAndSpansTheMonth() {
        let items = (1...8).map { day in
            item("day-\(day)", date: date(2026, 7, day))
        }
        let projection = TimelineTemporalProjection(
            mode: .months,
            sections: [section("July", items)],
            calendar: Self.calendar
        )

        let selection = projection.monthGroups.single.editorialSelection

        #expect(selection?.heroDay.itemUIDs == [items[7].uid])
        #expect(
            selection?.supportDays.map(\.itemUIDs) == [
                [items[0].uid], [items[3].uid], [items[6].uid],
            ])
    }

    @Test func temporalCoverResolutionUsesRealPixelsAndAspectFill() {
        let thumbnail = TimelineTemporalPixelSize(width: 512, height: 384)
        let preview = TimelineTemporalPixelSize(width: 1_920, height: 1_440)
        let retinaHero = TimelineTemporalPixelSize(width: 1_916, height: 1_438)

        #expect(
            !TimelineTemporalCoverResolutionPolicy.sourceFillsTargetWithoutUpscaling(
                source: thumbnail,
                target: retinaHero
            ))
        #expect(
            TimelineTemporalCoverResolutionPolicy.sourceFillsTargetWithoutUpscaling(
                source: preview,
                target: retinaHero
            ))

        let portrait = TimelineTemporalPixelSize(width: 3_000, height: 4_000)
        let squareCard = TimelineTemporalPixelSize(width: 1_000, height: 1_000)
        #expect(
            TimelineTemporalCoverResolutionPolicy.requiredDecodeLongestEdge(
                source: portrait,
                target: squareCard
            ) == 1_334)
    }

    @Test func cancellationIsObservedBeforeDetachedBuild() async {
        let task = Task { () throws -> TimelineTemporalProjection in
            try Task.checkCancellation()
            return try await TimelineTemporalProjection.build(
                mode: .years,
                sections: [section("June", [item("photo", date: date(2026, 6, 1))])],
                calendar: Self.calendar
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        return calendar
    }

    private func item(
        _ id: String,
        date: Date,
        mediaType: String = "image/jpeg",
        tags: Set<PhotoTag> = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: id),
            captureTime: date,
            mediaType: mediaType,
            tags: tags
        )
    }

    private func section(_ title: String, _ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(
            id: title,
            date: items.first?.captureTime ?? .distantPast,
            title: title,
            items: items
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)!
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func interval(_ component: Calendar.Component, _ date: Date) -> DateInterval {
        Self.calendar.dateInterval(of: component, for: date)!
    }
}

private extension Collection {
    var single: Element {
        precondition(count == 1)
        return first!
    }
}
