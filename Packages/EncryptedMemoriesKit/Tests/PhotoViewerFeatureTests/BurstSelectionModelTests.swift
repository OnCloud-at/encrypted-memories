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

        XCTAssertEqual(
            selection.viewerExportDecision(current: selected, page: base, belongsToPage: true),
            .success(items: group, expandedSingleSeries: true))
        XCTAssertEqual(selection.gridReturnCandidates(current: selected, base: base).map(\.uid.nodeID), ["c", "b"])
    }

    /// For every state `BurstSelectionModel` can reach through its own mutations,
    /// `hasFilmstrip` and the `count > 1` rule agree, and the viewer decision follows its
    /// order: loading waits, a failed read fails, otherwise the series or the photo.
    func testViewerBurstEntryAgreesWithHasFilmstripInEveryModelState() {
        let current = item("b", members: ["a", "b", "c"])
        let complete = [
            item("a", members: ["a", "b", "c"]),
            current,
            item("c", members: ["a", "b", "c"]),
        ]

        func makeStates() -> [(String, BurstSelectionModel)] {
            var states: [(String, BurstSelectionModel)] = []

            var empty = BurstSelectionModel()
            states.append(("empty", empty))

            var seeded = BurstSelectionModel()
            seeded.seedKnownGroup(for: current, knownItems: complete)
            states.append(("seeded", seeded))

            var partialSeed = BurstSelectionModel()
            partialSeed.seedKnownGroup(for: current, knownItems: Array(complete.prefix(2)))
            states.append(("partially seeded", partialSeed))

            var loaded = BurstSelectionModel()
            _ = loaded.beginLoadingIfCandidate(current)
            loaded.applyLoadedGroup(complete, containing: current)
            states.append(("loaded", loaded))

            var singletonLoad = BurstSelectionModel()
            _ = singletonLoad.beginLoadingIfCandidate(current)
            singletonLoad.applyLoadedGroup([current], containing: current)
            states.append(("singleton load", singletonLoad))

            var emptyLoad = BurstSelectionModel()
            _ = emptyLoad.beginLoadingIfCandidate(current)
            emptyLoad.applyLoadedGroup([], containing: current)
            states.append(("empty provider result", emptyLoad))

            var failedSeeded = BurstSelectionModel()
            failedSeeded.seedKnownGroup(for: current, knownItems: complete)
            _ = failedSeeded.beginLoadingIfCandidate(current)
            failedSeeded.failLoading()
            states.append(("failed with seeded items", failedSeeded))

            var failedEmpty = BurstSelectionModel()
            _ = failedEmpty.beginLoadingIfCandidate(current)
            failedEmpty.failLoading()
            states.append(("failed without seeded items", failedEmpty))

            var loading = BurstSelectionModel()
            _ = loading.beginLoadingIfCandidate(current)
            states.append(("still loading", loading))

            return states
        }

        for (name, selection) in makeStates() {
            XCTAssertTrue(selection.hasFilmstrip == (selection.items.count > 1), name)

            let result = selection.viewerExportDecision(current: current, page: current, belongsToPage: true)

            if selection.isLoading {
                // While the read is in flight the decision must not guess from the
                // partly known state; the viewer waits instead.
                XCTAssertEqual(result, .burstLoading, "state: \(name)")
            } else if selection.loadFailed {
                XCTAssertEqual(result, .burstReadFailed(failedSources: [current]), "state: \(name)")
            } else if selection.hasFilmstrip {
                XCTAssertEqual(result, .success(items: selection.items, expandedSingleSeries: true), "state: \(name)")
            } else {
                XCTAssertEqual(result, .success(items: [current], expandedSingleSeries: false), "state: \(name)")
            }
        }
    }

    // MARK: - Viewer export and share decision

    func testFailedReadWithAPartialFilmstripIsNeverAPartialExport() {
        let page = item("a", members: ["a", "b", "c"])
        let shown = item("b", members: ["a", "b", "c"])
        var selection = BurstSelectionModel()
        selection.seedKnownGroup(for: page, knownItems: [page, shown])
        XCTAssertTrue(selection.beginLoadingIfCandidate(page))
        XCTAssertEqual(selection.selectIndex(1)?.uid.nodeID, "b")
        selection.failLoading()

        // The page photo, not the shown filmstrip member, goes back to the export: only the
        // page photo carries the burst, so the export reads the whole group again from it.
        XCTAssertEqual(
            selection.viewerExportDecision(current: shown, page: page, belongsToPage: true),
            .burstReadFailed(failedSources: [page]))
    }

    func testFailedReadWithoutAFilmstripFailsInsteadOfASinglePhoto() {
        let page = item("a", members: ["a", "b", "c"])
        var selection = BurstSelectionModel()
        XCTAssertTrue(selection.beginLoadingIfCandidate(page))
        selection.failLoading()

        XCTAssertEqual(
            selection.viewerExportDecision(current: page, page: page, belongsToPage: true),
            .burstReadFailed(failedSources: [page]))
    }

    func testPartialFilmstripWaitsWhileTheReadIsInFlight() {
        let page = item("a", members: ["a", "b", "c"])
        var selection = BurstSelectionModel()
        selection.seedKnownGroup(for: page, knownItems: [page, item("b", members: ["a", "b", "c"])])
        XCTAssertTrue(selection.beginLoadingIfCandidate(page))

        XCTAssertEqual(
            selection.viewerExportDecision(current: page, page: page, belongsToPage: true), .burstLoading)
    }

    func testBurstPageRightAfterASwipeWaitsWhileTheModelHoldsThePreviousPage() {
        // The model still holds the previous page's loaded series; the swiped-to burst page
        // has not started its own read.
        let previous = item("p", members: ["p", "q"])
        var selection = BurstSelectionModel()
        _ = selection.beginLoadingIfCandidate(previous)
        selection.applyLoadedGroup([previous, item("q", members: ["p", "q"])], containing: previous)
        let swipedTo = item("x", members: ["x", "y", "z"])

        XCTAssertEqual(
            selection.viewerExportDecision(current: swipedTo, page: swipedTo, belongsToPage: false), .burstLoading)
    }

    func testPlainPageRightAfterASwipeSharesItsPhoto() {
        let previous = item("p", members: ["p", "q"])
        var selection = BurstSelectionModel()
        _ = selection.beginLoadingIfCandidate(previous)
        selection.failLoading()
        let plain = item("plain")

        XCTAssertEqual(
            selection.viewerExportDecision(current: plain, page: plain, belongsToPage: false),
            .success(items: [plain], expandedSingleSeries: false))
    }

    func testPlainPhotoIsExportedAsItself() {
        let plain = item("plain")
        let selection = BurstSelectionModel()

        XCTAssertEqual(
            selection.viewerExportDecision(current: plain, page: plain, belongsToPage: true),
            .success(items: [plain], expandedSingleSeries: false))
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
