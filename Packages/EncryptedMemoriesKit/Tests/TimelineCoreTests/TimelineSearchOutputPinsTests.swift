import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineSearchOutputPinsTests {
    @Test func everyTermKindPreservesMatchingAndOrder() {
        let sections = fixture()
        let favorite = sections[0].items[1].uid
        let names = PhotoNameIndex(
            names: [sections[1].items[2].uid: "Selfie am Strand.jpg", sections[0].items[0].uid: "Film_Screenshot.jpg"],
            revision: 1)
        let context = TimelineSearchContext(favoriteUIDs: [favorite], photoNames: names)
        let cases: [(String, [String])] = [
            ("", ["still", "fav", "vid", "raw", "screen", "portrait"]),
            ("favorite", ["fav"]),
            ("video", ["vid"]),
            ("film", ["still", "vid"]),
            ("raw", ["raw"]),
            ("screenshots", ["still", "screen"]),
            ("selfies", ["portrait"]),
            ("CAFE", ["still", "fav", "vid"]),
            ("café FAVORITE", ["fav"]),
            ("selfie strand", ["portrait"]),
            ("2026 03", ["still", "fav", "vid", "raw", "screen", "portrait"]),
        ]
        for (query, expected) in cases {
            let result = TimelineSearch.filter(sections, query: query, context: context)
            #expect(result.flatMap(\.items).map(\.uid.nodeID) == expected, "query: \(query)")
        }
    }

    @Test func smartNamesAndActiveFiltersKeepTheirExistingSemantics() {
        let sections = fixture()
        let context = TimelineSearchContext(activeFilter: .tag(.raw))
        let result = TimelineSearch.filter(sections, query: "raw", context: context)
        #expect(result.map(\.id) == ["first", "second"])
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["still", "fav", "vid", "raw", "screen", "portrait"])
    }

    private func fixture() -> [TimelineSection] {
        let date = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03-01 UTC
        func photo(_ id: String, _ type: String) -> PhotoItem {
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: id), captureTime: date, mediaType: type)
        }
        return [
            TimelineSection(
                id: "first", date: date, title: "Café",
                items: [photo("still", "image/jpeg"), photo("fav", "image/jpeg"), photo("vid", "video/quicktime")]),
            TimelineSection(
                id: "second", date: date, title: "Beach",
                items: [
                    photo("raw", "image/x-adobe-dng"), photo("screen", "image/png"), photo("portrait", "image/jpeg"),
                ]),
        ]
    }
}
