import XCTest

@testable import PhotosCore

/// Locks the shared timeline flatten/sort/index snapshot: ordering matches `TimelineOrder` exactly (so
/// moving it off the main actor is behavior-preserving), counts are correct, and the prebuilt index answers
/// open/share/trash lookups without rescanning.
final class TimelineSnapshotTests: XCTestCase {
    private func uid(_ vol: String, _ node: String) -> PhotoUID { PhotoUID(volumeID: vol, nodeID: node) }

    private func item(
        _ vol: String,
        _ node: String,
        t: TimeInterval,
        mediaType: String = "image/jpeg"
    ) -> PhotoItem {
        PhotoItem(uid: uid(vol, node), captureTime: Date(timeIntervalSince1970: t), mediaType: mediaType)
    }

    private func section(_ id: String, _ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: id, date: Date(timeIntervalSince1970: 0), title: id, items: items)
    }

    func testFlattenSortMatchesTimelineOrderExactly() {
        // Deliberately out of order across sections and within a section, plus a capture-time tie.
        let a = item("v", "a", t: 300)
        let b = item("v", "b", t: 100)
        let c = item("v", "c", t: 200)
        let tieLow = item("v", "aaa", t: 200)  // Same time as c; node ID breaks the tie.
        let sections = [section("s1", [a, c]), section("s2", [b, tieLow])]

        let snapshot = TimelineSnapshot(sections: sections)
        let expected = (sections.flatMap(\.items)).sorted(by: TimelineOrder.areInIncreasingOrder)

        XCTAssertEqual(snapshot.items, expected)
        XCTAssertEqual(snapshot.items.map(\.uid.nodeID), ["b", "aaa", "c", "a"])
        XCTAssertEqual(snapshot.count, 4)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testEmptyInputs() {
        XCTAssertTrue(TimelineSnapshot().isEmpty)
        XCTAssertTrue(TimelineSnapshot(sections: []).isEmpty)
        XCTAssertEqual(TimelineSnapshot().count, 0)
        XCTAssertNil(TimelineSnapshot().index(of: uid("v", "x")))
    }

    func testIndexAndItemLookupsMatchArrayPositions() {
        let items = (0..<50).map { item("v", "n\($0)", t: TimeInterval(50 - $0)) }  // reverse-time
        let snapshot = TimelineSnapshot(sections: [section("s", items)])

        for (position, item) in snapshot.items.enumerated() {
            XCTAssertEqual(snapshot.index(of: item.uid), position)
            XCTAssertEqual(snapshot.item(for: item.uid), item)
        }
        XCTAssertNil(snapshot.index(of: uid("v", "missing")))
        XCTAssertNil(snapshot.item(for: uid("v", "missing")))
    }

    func testDuplicateUIDWithinSectionKeepsFirstOccurrence() {
        let first = item("v", "duplicate", t: 20, mediaType: "image/jpeg")
        let duplicate = item("v", "duplicate", t: 20, mediaType: "image/png")
        let snapshot = TimelineSnapshot(sections: [
            section("s", [item("v", "a", t: 10), first, duplicate, item("v", "c", t: 30)])
        ])

        XCTAssertEqual(snapshot.items.map(\.uid.nodeID), ["a", "duplicate", "c"])
        XCTAssertEqual(snapshot.item(for: first.uid), first)
        XCTAssertEqual(snapshot.count, 3)
    }

    func testDuplicateUIDAcrossSectionsKeepsFirstCanonicalOccurrence() {
        let first = item("v", "shared", t: 20, mediaType: "image/jpeg")
        let duplicate = item("v", "shared", t: 20, mediaType: "image/png")
        let snapshot = TimelineSnapshot(sections: [
            section("s1", [item("v", "a", t: 10), first]),
            section("s2", [duplicate, item("v", "c", t: 30)]),
        ])

        XCTAssertEqual(snapshot.items.map(\.uid.nodeID), ["a", "shared", "c"])
        XCTAssertEqual(snapshot.item(for: first.uid), first)
    }

    func testUnorderedSectionsSortOnlyRetainedFirstOccurrences() {
        let first = item("v", "shared", t: 20, mediaType: "image/jpeg")
        let duplicate = item("v", "shared", t: 20, mediaType: "image/png")
        let snapshot = TimelineSnapshot(sections: [
            section("s1", [item("v", "c", t: 30), first]),
            section("s2", [item("v", "a", t: 10), duplicate]),
        ])

        XCTAssertEqual(snapshot.items.map(\.uid.nodeID), ["a", "shared", "c"])
        XCTAssertEqual(snapshot.item(for: first.uid), first)
    }

    func testAlreadyOrderedItemsInitializerPreservesOrderAndDeduplicates() {
        let first = item("v", "b", t: 20, mediaType: "image/jpeg")
        let duplicate = item("v", "b", t: 20, mediaType: "image/png")
        let snapshot = TimelineSnapshot(orderedItems: [
            item("v", "a", t: 10), first, duplicate, item("v", "c", t: 30),
        ])

        XCTAssertEqual(snapshot.items.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(snapshot.item(for: first.uid), first)
        for (position, item) in snapshot.items.enumerated() {
            XCTAssertEqual(snapshot.index(of: item.uid), position)
        }
    }

    func testItemsWithUIDsReturnsTimelineOrderedSelection() {
        let items = (0..<20).map { item("v", "n\($0)", t: TimeInterval($0)) }
        let snapshot = TimelineSnapshot(sections: [section("s", items)])
        let chosen: Set<PhotoUID> = [uid("v", "n5"), uid("v", "n1"), uid("v", "n9"), uid("v", "absent")]

        let result = snapshot.items(withUIDs: chosen)
        // Ordered by timeline position (== capture time here), not by Set iteration order; absent uid dropped.
        XCTAssertEqual(result.map(\.uid.nodeID), ["n1", "n5", "n9"])
    }

    func testOrderedUIDsRetainsSelectionMissingFromAConcurrentSnapshot() {
        let snapshot = TimelineSnapshot(sections: [
            section(
                "s",
                [
                    item("v", "n1", t: 1), item("v", "n5", t: 5), item("v", "n9", t: 9),
                ])
        ])
        let chosen: Set<PhotoUID> = [
            uid("v", "n9"), uid("v", "n1"), uid("v", "stale-b"), uid("v", "stale-a"),
        ]

        XCTAssertEqual(
            snapshot.orderedUIDs(including: chosen).map(\.nodeID),
            ["n1", "n9", "stale-a", "stale-b"]
        )
    }

    func testRemovingItemsPreservesOrderAndReindexes() {
        let items = (0..<10).map { item("v", "n\($0)", t: TimeInterval($0)) }
        let snapshot = TimelineSnapshot(sections: [section("s", items)])

        let trimmed = snapshot.removingItems(withUIDs: [uid("v", "n2"), uid("v", "n7")])
        XCTAssertEqual(trimmed.count, 8)
        XCTAssertEqual(trimmed.items.map(\.uid.nodeID), ["n0", "n1", "n3", "n4", "n5", "n6", "n8", "n9"])
        XCTAssertNil(trimmed.index(of: uid("v", "n2")))
        // Index is rebuilt: every surviving item maps to its new position.
        for (position, item) in trimmed.items.enumerated() {
            XCTAssertEqual(trimmed.index(of: item.uid), position)
        }
        // Removing nothing returns an equal snapshot.
        XCTAssertEqual(snapshot.removingItems(withUIDs: []), snapshot)
    }

    func testDeterministicAcrossRepeatedBuilds() {
        let items = (0..<200).map { item("v\($0 % 3)", "n\($0)", t: TimeInterval($0 % 40)) }
        let sections = [section("s", items)]
        XCTAssertEqual(TimelineSnapshot(sections: sections).items, TimelineSnapshot(sections: sections).items)
    }
}
