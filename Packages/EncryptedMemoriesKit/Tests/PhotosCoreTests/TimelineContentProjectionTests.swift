import XCTest

@testable import PhotosCore

final class TimelineContentProjectionTests: XCTestCase {
    private func item(_ id: String, time: TimeInterval) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: time),
            mediaType: "image/jpeg"
        )
    }

    private func section(_ id: String, _ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: id, date: items.first?.captureTime ?? .distantPast, title: id, items: items)
    }

    func testSectionsAndSnapshotShareTheSameUniqueIdentities() {
        let duplicate = item("duplicate", time: 2)
        let projection = TimelineContentProjection(sections: [
            section("one", [item("a", time: 1), duplicate]),
            section("two", [duplicate, item("c", time: 3)]),
        ])

        let sectionUIDs = projection.sections.flatMap { $0.items.map(\.uid) }
        XCTAssertEqual(sectionUIDs, projection.snapshot.items.map(\.uid))
        XCTAssertEqual(sectionUIDs.map(\.nodeID), ["a", "duplicate", "c"])
    }

    func testRemovalUpdatesSectionsAndIndexedSnapshotTogether() {
        let a = item("a", time: 1)
        let b = item("b", time: 2)
        let c = item("c", time: 3)
        let projection = TimelineContentProjection(sections: [
            section("one", [a, b]),
            section("two", [c]),
        ]).removing([b.uid, c.uid])

        XCTAssertEqual(projection.sections.count, 1)
        XCTAssertEqual(projection.sections[0].items.map(\.uid), [a.uid])
        XCTAssertEqual(projection.snapshot.items.map(\.uid), [a.uid])
        XCTAssertNil(projection.snapshot.item(for: b.uid))
    }

    func testInsertionRestoresMissingItemsInCanonicalOrderWithoutDuplicates() {
        let a = item("a", time: 1)
        let b = item("b", time: 2)
        let c = item("c", time: 3)
        let projection = TimelineContentProjection(sections: [section("library", [a, c])])
            .inserting([b, a])

        XCTAssertEqual(projection.snapshot.items.map(\.uid), [a.uid, b.uid, c.uid])
        XCTAssertEqual(projection.sections.flatMap { $0.items.map(\.uid) }, [a.uid, b.uid, c.uid])
    }
}
