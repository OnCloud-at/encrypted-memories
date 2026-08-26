import PhotosCore
import XCTest

@testable import PhotoViewerCore

final class BurstSelectionModelTests: XCTestCase {
    func testSeedsKnownTimelineGroupInPresentationOrder() {
        var selection = BurstSelectionModel()
        let items = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]

        selection.seedKnownGroup(for: items[1], knownItems: items)

        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertEqual(selection.items.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    func testKnownGroupUsesFullUIDWhenNodeIDsExistOnDifferentVolumes() {
        var selection = BurstSelectionModel()
        let activeVolumeItems = [
            item("a", volume: "active", members: ["a", "b", "c"]),
            item("b", volume: "active", members: ["a", "b", "c"]),
            item("c", volume: "active", members: ["a", "b", "c"]),
        ]
        let otherVolumeItems = [
            item("a", volume: "other"),
            item("b", volume: "other"),
            item("c", volume: "other"),
        ]

        let route = otherVolumeItems + activeVolumeItems
        let pageIndex = ViewerPageIndex(orderedUIDs: route.map(\.uid))
        selection.seedKnownGroup(
            for: activeVolumeItems[1],
            knownItems: pageIndex.items(withUIDs: activeVolumeItems[1].burstMemberUIDs, from: route)
        )

        XCTAssertEqual(selection.items.map(\.uid.volumeID), ["active", "active", "active"])
        XCTAssertEqual(selection.items.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(selection.current(fallback: activeVolumeItems[1]).uid, activeVolumeItems[1].uid)
    }

    func testEmptyProviderResultDoesNotClearSeededTimelineGroup() {
        var selection = BurstSelectionModel()
        let items = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]
        selection.seedKnownGroup(for: items[1], knownItems: items)
        XCTAssertFalse(selection.beginLoadingIfCandidate(items[1]))

        selection.applyLoadedGroup([], containing: items[1])

        XCTAssertFalse(selection.isLoading)
        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertEqual(selection.current(fallback: items[1]).uid.nodeID, "b")
    }

    func testPartialKnownTimelineGroupStillLoadsProvider() {
        var selection = BurstSelectionModel()
        let completeGroup = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]

        selection.seedKnownGroup(for: completeGroup[1], knownItems: Array(completeGroup.prefix(2)))

        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertTrue(selection.beginLoadingIfCandidate(completeGroup[1]))
        XCTAssertTrue(selection.isLoading)
    }

    func testProviderFailureDoesNotClearSeededTimelineGroup() {
        let items = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]
        var selection = BurstSelectionModel(items: items, selectedIndex: 1, isLoading: true)

        selection.failLoading()

        XCTAssertFalse(selection.isLoading)
        XCTAssertTrue(selection.loadFailed)
        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertEqual(selection.current(fallback: items[1]).uid.nodeID, "b")
    }

    func testFilmstripPolicyDoesNotReloadForSelectionOnly() {
        let items = [
            PhotoUID(volumeID: "v", nodeID: "a"),
            PhotoUID(volumeID: "v", nodeID: "b"),
        ]
        let update = BurstFilmstripUpdatePolicy.resolve(
            previousItems: items,
            currentItems: items,
            previousSelectedUID: items[0],
            currentSelectedUID: items[1],
            previousItemSide: 72,
            currentItemSide: 72,
            previousShowsScroller: false,
            currentShowsScroller: false
        )
        XCTAssertFalse(update.reloadData)
        XCTAssertFalse(update.updateLayout)
        XCTAssertTrue(update.selectCurrent)
    }

    func testSelectionNavigationStaysInsideSeriesUntilEdge() {
        var selection = BurstSelectionModel(
            items: [item("a"), item("b"), item("c")],
            selectedIndex: 1
        )

        XCTAssertEqual(selection.selectNext()?.uid.nodeID, "c")
        XCTAssertNil(selection.selectNext())
        XCTAssertEqual(selection.selectPrevious()?.uid.nodeID, "b")
        XCTAssertEqual(selection.selectPrevious()?.uid.nodeID, "a")
        XCTAssertNil(selection.selectPrevious())
    }

    func testExportAndReturnCandidatesPreferSeriesWhenActive() {
        let base = item("b")
        let selected = item("c")
        let group = [item("a"), base, selected]
        let selection = BurstSelectionModel(items: group, selectedIndex: 2)

        XCTAssertEqual(selection.exportItems(current: selected).map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(selection.gridReturnCandidates(current: selected, base: base).map(\.uid.nodeID), ["c", "b"])
    }

    private func item(_ id: String, volume: String = "v", members: [String] = []) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volume, nodeID: id),
            captureTime: Date(timeIntervalSince1970: Double(id.unicodeScalars.first?.value ?? 0)),
            mediaType: "image/jpeg",
            tags: members.isEmpty ? [] : [.bursts],
            burstMemberIDs: members
        )
    }
}
