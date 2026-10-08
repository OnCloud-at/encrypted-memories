import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

@MainActor
final class ExactDuplicatesModelTests: XCTestCase {
    private let a1 = PhotoUID(volumeID: "v", nodeID: "a1")
    private let a2 = PhotoUID(volumeID: "v", nodeID: "a2")
    private let a3 = PhotoUID(volumeID: "v", nodeID: "a3")
    private let b1 = PhotoUID(volumeID: "v", nodeID: "b1")
    private let b2 = PhotoUID(volumeID: "v", nodeID: "b2")

    private var groupA: ExactDuplicateGroup {
        ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a2, a3])
    }
    private var groupB: ExactDuplicateGroup {
        ExactDuplicateGroup(contentHash: "B", hashKeyEpoch: "e", members: [b1, b2])
    }

    private func makeModel(_ finder: FakeDuplicateFinder) -> (ExactDuplicatesModel, TrashLog) {
        let log = TrashLog()
        let model = ExactDuplicatesModel(finder: finder) { log.calls.append($0) }
        return (model, log)
    }

    // MARK: - States

    func testLoadingUntilTheFirstScanFinishes() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        XCTAssertEqual(model.content, .loading)
        XCTAssertNil(model.knownDuplicateCount)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.knownDuplicateCount, 2)
    }

    func testAnEmptyCompleteScanHasNoDuplicates() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)]))
        await model.load()
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertNil(model.stillCheckingNote)
        XCTAssertFalse(model.canMerge)
    }

    func testAFinishedCheckNeverWaitsAndNamesThePhotosItCouldNotRead() async {
        let (incomplete, _) = makeModel(
            FakeDuplicateFinder(scans: [.init(groups: [], coverage: .incomplete(unresolvedCount: 3))]))
        await incomplete.load()
        XCTAssertEqual(incomplete.content, .noDuplicates, "a finished check shows its result")
        XCTAssertEqual(incomplete.emptyStateCopy.title, L10n.string("duplicates.none_title"))
        XCTAssertEqual(incomplete.emptyStateCopy.description, L10n.string("duplicates.unchecked \(3)"))
        XCTAssertNil(incomplete.checkFailedNote, "a retry cannot read those photos")

        let (unbuilt, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)]))
        await unbuilt.load()
        guard case .failed = unbuilt.content else {
            return XCTFail("a build that left no index offers a retry, got \(unbuilt.content)")
        }

        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)]))
        await complete.load()
        XCTAssertEqual(complete.emptyStateCopy, PhotoFilter.duplicates.emptyStateCopy)
        XCTAssertNil(complete.uncheckedNote)
    }

    func testAFailedScanShowsAShortReasonAndKeepsShownGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        let (model, _) = makeModel(finder)
        finder.scanError = URLError(.notConnectedToInternet)
        await model.load()
        guard case .failed(let reason) = model.content else {
            return XCTFail("expected a failure, got \(model.content)")
        }
        XCTAssertFalse(reason.isEmpty)

        finder.scanError = nil
        await model.load()
        finder.scanError = URLError(.notConnectedToInternet)
        await model.load()
        XCTAssertEqual(model.content, .groups, "a failed refresh must not hide the groups already shown")
    }

    func testAFailedRankingKeepsTheFallbackOrderAndShowsTheGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.rankError = URLError(.timedOut)
        finder.fallback = ["A": [a2, a1, a3]]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.first?.members, [a2, a1, a3])
        XCTAssertEqual(model.groups.first?.kept, a2)
        XCTAssertEqual(model.groups.first?.isRanked, false)
    }

    func testTheGroupsShowBeforeTheRankingAndTheRankingRunsWithoutAProgressRow() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")

        XCTAssertEqual(model.content, .groups, "the list never waits for the ranking")
        XCTAssertEqual(model.groups.first?.kept, a2, "the fallback order chooses the photo to keep until then")
        XCTAssertEqual(model.copyCountText, L10n.string("duplicates.copy_count \(5)"), "every copy, kept ones too")
        XCTAssertNil(model.rankingLine, "the ranking of the shown groups runs silently")
        XCTAssertTrue(model.canMerge)

        finder.rankGate.open()
        await load.value
        XCTAssertEqual(model.groups.first?.members, [a3, a1, a2])
        XCTAssertEqual(model.groups.first?.kept, a3, "a checkmark that nobody chose moves once to the ranked photo")
        XCTAssertNil(model.rankingLine)
    }

    func testScrollingRanksTheShownGroupsWithoutAProgressRow() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        finder.rankGate.close()
        model.groupAppeared(groups[80].id)
        await waitUntil({ finder.rankGate.hasWaiters }, "scrolling ranks")

        XCTAssertNil(model.rankingLine, "the ranking of the groups on screen shows no progress row")

        finder.rankGate.open()
        await waitUntil({ model.groups.first { $0.id == groups[80].id }?.isRanked == true }, "the facts arrive")
        XCTAssertNil(model.rankingLine)
    }

    func testAChosenCheckmarkStaysWhenTheFactsArrive() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fallback = ["A": [a1, a2, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")
        model.keep(a2, inGroup: "A")

        finder.rankGate.open()
        await load.value

        XCTAssertEqual(model.groups.first?.members, [a3, a1, a2], "the ranked order arrives")
        XCTAssertEqual(model.groups.first?.kept, a2, "the photo that the person chose stays checked")
    }

    func testAGroupWhoseFactsCannotBeReadKeepsItsFallbackOrderAndTheOthersAreRanked() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3], "B": [b2, b1]]
        finder.ranked = ["A": [a3, a1, a2], "B": [b1, b2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.kept), [a2, b1])
        XCTAssertEqual(model.groups.map(\.isRanked), [false, true])
    }

    func testMergeAllReadsTheFactsOfAnUnrankedGroupAndKeepsTheFirstRankedOrTheChosenPhoto() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3], "B": [b2, b1]]
        finder.ranked = ["A": [a3, a1, a2], "B": [b1, b2]]
        finder.unreadableGroups = ["A", "B"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        model.keep(b2, inGroup: "B")

        await model.mergeAll()

        XCTAssertEqual(
            finder.rankedGroups.last, ["A", "B"],
            "Merge All reads the facts and the metadata of every unranked group first, a chosen one too")
        XCTAssertEqual(
            finder.merges, [.init(group: "A", kept: a3), .init(group: "B", kept: b2)],
            "the merge keeps the copy that ranks first, as every device does, unless the person chose another")
        XCTAssertEqual(finder.choices, ["A": false, "B": true], "the ranked copy stays a preselection")
    }

    func testMergeAllKeepsASharedMemberInsteadOfTheShownPhotoAndShowsIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        finder.shared = ["A": [a3]]
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        finder.rankGate.open()
        await waitUntil({ !finder.merges.isEmpty }, "the merge runs")
        XCTAssertEqual(finder.merges, [.init(group: "A", kept: a3)], "a trash would end the sharing of a3")
        await merge.value
    }

    func testMergingOneUnrankedGroupKeepsTheCopyThatTheRuleRanksFirst() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fallback = ["A": [a2, a1, a3]]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        let ranksBefore = finder.rankCalls
        XCTAssertEqual(model.groups.first?.kept, a2)

        await model.merge(groupID: "A")

        XCTAssertEqual(
            finder.merges, [.init(group: "A", kept: a3)],
            "the person saw no ranking, so the copy that every device ranks first stays")
        XCTAssertEqual(finder.choices, ["A": false], "the ranked copy stays a preselection")
        XCTAssertEqual(finder.rankCalls, ranksBefore + 1, "the merge reads the metadata of the copies first")
        XCTAssertEqual(model.notice, nil)
    }

    func testTheScanShowsATitledCountedProgress() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.scanProgress = [.init(completed: 150, total: 3_180)]
        finder.scanGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.scanGate.hasWaiters }, "the load scans")

        XCTAssertEqual(model.content, .loading)
        XCTAssertEqual(model.loadingLine.title, L10n.string("duplicates.loading"))
        XCTAssertEqual(
            model.loadingLine.detail,
            L10n.string("duplicates.checking_progress \(150.formatted()) \(3_180.formatted())"))
        XCTAssertEqual(model.loadingLine.fraction ?? 0, 150.0 / 3_180.0, accuracy: 0.0001)
        finder.scanGate.open()
        await load.value
        XCTAssertNil(model.scanProgress)
    }

    func testARebuildOfACompleteIndexShowsItsProgressAboveTheGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.buildProgress = [.init(phase: .indexing, completed: 10_000, total: 51_220)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.checkLine?.title, L10n.string("duplicates.checking_title"))
        XCTAssertEqual(model.checkLine?.detail, model.checkProgressText)
        XCTAssertNil(model.stillCheckingNote, "a complete index finds every group already")
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkLine)
    }

    func testAnIncompleteOrIndexingScanShowsTheStillCheckingNoteWithItsGroupsWhileTheCheckRuns() async {
        for coverage in [ExactDuplicateCoverage.indexing, .incomplete(unresolvedCount: 3)] {
            let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: coverage)])
            finder.buildGate.close()
            let (model, _) = makeModel(finder)
            let load = Task { await model.load() }
            await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
            XCTAssertEqual(model.content, .groups, "\(coverage)")
            XCTAssertNotNil(model.stillCheckingNote, "\(coverage)")
            finder.buildGate.open()
            await load.value
            XCTAssertNil(model.stillCheckingNote, "no waiting text after the check: \(coverage)")
            if case .incomplete = coverage {
                XCTAssertEqual(model.uncheckedNote, L10n.string("duplicates.unchecked \(3)"))
                XCTAssertNil(model.checkFailedNote)
            } else {
                XCTAssertEqual(model.checkFailedNote, L10n.string("duplicates.check_failed"))
                XCTAssertNil(model.uncheckedNote)
            }
        }
        let (complete, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await complete.load()
        XCTAssertNil(complete.stillCheckingNote)
    }

    // MARK: - The library check

    /// Waits until `condition` holds, for at most two seconds.
    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), message)
    }

    func testAnEmptyIndexThatIsStillBuildingSaysThatDuplicatesAppearWhenTheCheckIsDone() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.content, .stillChecking)
        XCTAssertEqual(model.emptyStateCopy.title, L10n.string("duplicates.checking_title"))
        XCTAssertEqual(model.emptyStateCopy.description, L10n.string("duplicates.checking_wait"))
        XCTAssertNotEqual(
            model.emptyStateCopy.description, L10n.string("duplicates.still_checking"),
            "more duplicates can only appear when some are shown")
        XCTAssertEqual(model.checkProgress, .indeterminate)
        finder.buildGate.open()
        await load.value
    }

    func testTheCheckShowsTheProgressOfTheBuild() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildProgress = [.init(phase: .loading), .init(phase: .indexing, completed: 1_234, total: 15_000)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")

        XCTAssertEqual(model.checkProgress, .counted(completed: 1_234, total: 15_000))
        XCTAssertEqual(
            model.checkProgressText,
            L10n.string("duplicates.checking_progress \(1_234.formatted()) \(15_000.formatted())"))
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkProgress, "no progress once the build finished")
        XCTAssertNil(model.checkProgressText)
    }

    func testAFinishedBuildLoadsTheGroupsWithoutARefresh() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [], coverage: .indexing), .init(groups: [groupA], coverage: .complete),
        ])
        finder.buildChanged = true
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(finder.buildCalls, 1)
        XCTAssertEqual(model.content, .groups)
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertNil(model.stillCheckingNote)
    }

    func testABuildThatChangedNothingScansOnceAndACompleteEmptyIndexHasNoDuplicates() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(finder.buildCalls, 1, "a complete index is brought up to date")
        XCTAssertEqual(finder.scanCalls, 1)
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertEqual(model.emptyStateCopy.title, L10n.string("duplicates.none_title"))
    }

    func testALoadWhileTheIndexBuildsWaitsForThatBuildInsteadOfStartingASecondOne() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let first = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        let second = Task { await model.load() }
        await waitUntil({ finder.scanCalls == 2 }, "the second load scans")
        finder.buildGate.open()
        await first.value
        await second.value
        XCTAssertEqual(finder.buildCalls, 1)
    }

    func testAFailedBuildWithoutGroupsOffersARetryAndKeepsACompleteIndex() async {
        let building = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .indexing)])
        building.buildError = URLError(.notConnectedToInternet)
        let (model, _) = makeModel(building)
        await model.load()
        guard case .failed = model.content else { return XCTFail("expected a failure, got \(model.content)") }

        let complete = FakeDuplicateFinder(scans: [.init(groups: [], coverage: .complete)])
        complete.buildError = URLError(.notConnectedToInternet)
        let (completeModel, _) = makeModel(complete)
        await completeModel.load()
        XCTAssertEqual(completeModel.content, .noDuplicates, "the complete index still answers")
    }

    // MARK: - Freed space

    func testEachGroupAndTheTotalShowTheFreedSpaceInTheSystemByteFormat() async {
        let finder = FakeDuplicateFinder(
            scans: [.init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 1_000_000])])
        let (model, _) = makeModel(finder)
        await model.load()
        let a = model.groups.first { $0.id == "A" }
        XCTAssertEqual(a?.freedBytes, 2_000_000, "one size for each of the two duplicates")
        XCTAssertEqual(
            a?.freedText,
            L10n.string("duplicates.group_frees \(Int64(2_000_000).formatted(.byteCount(style: .file)))"))
        XCTAssertNil(model.groups.first { $0.id == "B" }?.freedText, "an unknown size shows nothing")
        XCTAssertEqual(model.totalFreedBytes, 2_000_000)
        XCTAssertEqual(
            model.totalFreedText,
            L10n.string("duplicates.total_frees \(Int64(2_000_000).formatted(.byteCount(style: .file)))"))
    }

    func testTheTotalGrowsWhileTheCheckFindsGroupsAndSizes() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .indexing, byteSizes: ["A": 100]),
            .init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 100]),
        ])
        finder.buildChanged = true
        finder.rankSizes = ["B": 50]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        XCTAssertEqual(model.totalFreedBytes, 200)
        finder.buildGate.open()
        await load.value
        XCTAssertEqual(model.totalFreedBytes, 250, "the new group and the size from the ranking add up")
        XCTAssertEqual(model.groups.first { $0.id == "B" }?.freedBytes, 50)
    }

    func testNoGroupHasASizeWhenNothingKnowsIt() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await model.load()
        XCTAssertNil(model.groups.first?.byteSize)
        XCTAssertEqual(model.totalFreedBytes, 0)
        XCTAssertNil(model.totalFreedText)
    }

    // MARK: - One change for each page

    func testARankedPagePublishesOneChangeForAllItsGroups() async {
        let groupC = ExactDuplicateGroup(contentHash: "C", hashKeyEpoch: "e", members: [b1, a1])
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB, groupC], coverage: .complete)])
        finder.ranked = ["A": [a3, a1, a2], "B": [b2, b1], "C": [a1, b1]]
        finder.rankSizes = ["A": 10, "B": 20, "C": 30]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")
        let before = model.groupChanges

        finder.rankGate.open()
        await load.value

        XCTAssertEqual(model.groups.filter(\.isRanked).count, 3, "the page ranked every group")
        XCTAssertEqual(model.groupChanges - before, 1, "the screen sees one change for the whole page")
    }

    func testARankedPageLeavesTheOtherGroupsUnchanged() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.unreadableGroups = ["B"]
        finder.ranked = ["A": [a3, a1, a2]]
        finder.facts = ["A": [a3: facts(favorite: true)]]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")
        let unchanged = model.groups.first { $0.id == "B" }

        finder.rankGate.open()
        await load.value

        XCTAssertEqual(model.groups.first { $0.id == "A" }?.kept, a3, "the page ranked group A")
        XCTAssertEqual(model.groups.first { $0.id == "B" }, unchanged, "the row of group B has nothing to redraw")
    }

    func testKeepingAnotherCopyPublishesOneChange() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await model.load()
        let before = model.groupChanges
        model.keep(a2, inGroup: "A")
        XCTAssertEqual(model.groupChanges - before, 1)
        XCTAssertEqual(model.groups[0].kept, a2)
    }

    // MARK: - The viewer of a group

    func testARankingThatLandsDuringAMergeKeepsTheCheckmarkThatTheMergeKeeps() async {
        let groups = manyGroups(60)
        let late = groups[50]
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let shownKept = model.groups.first { $0.id == late.id }?.kept
        // A scroll ranking of the late group starts first and lands only after Merge All read the same group.
        finder.ranked = [late.id: Array(late.members.reversed())]
        finder.heldGroups = [late.id]
        finder.holdGate.close()
        model.groupAppeared(late.id)
        await waitUntil({ finder.holdGate.hasWaiters }, "the scroll ranking reads the late group")
        finder.heldGroups = []
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        // The person saw no ranking of the late group, so Merge All keeps the copy that its own ranking puts first.
        let mergeKept = late.members.last
        XCTAssertNotEqual(mergeKept, shownKept)
        XCTAssertEqual(model.groups.first { $0.id == late.id }?.kept, mergeKept, "Merge All keeps the first copy")

        // The held scroll ranking lands with another order.
        finder.ranked = [late.id: late.members]
        finder.holdGate.open()
        await waitUntil({ finder.activeRankings == 0 }, "the scroll ranking lands")

        XCTAssertEqual(
            model.groups.first { $0.id == late.id }?.kept, mergeKept, "the screen shows what the merge keeps")
        finder.mergeGate.open()
        await merge.value
        XCTAssertEqual(finder.merges.first { $0.group == late.id }?.kept, mergeKept)
    }

    func testAPhotoTrashedElsewhereLeavesItsGroupAndASingleCopyLeavesTheList() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        model.keep(a2, inGroup: "A")

        model.didTrashElsewhere([a2, b1])

        XCTAssertEqual(model.groups.map(\.id), ["A"], "group B has one copy left")
        XCTAssertEqual(model.groups[0].members, [a1, a3])
        XCTAssertEqual(model.groups[0].kept, a1, "the next copy takes the checkmark of the trashed one")
        XCTAssertFalse(model.groups[0].isKeptChosen)
        XCTAssertTrue(log.calls.isEmpty, "the library already removed the photos")
        XCTAssertTrue(finder.merges.isEmpty)
    }

    func testTheViewerActionsFollowTheGroup() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await model.load()
        XCTAssertFalse(model.canKeep(a1), "the kept copy is kept already")
        XCTAssertEqual(model.keepSymbol(for: a1), "checkmark.circle.fill")
        XCTAssertTrue(model.canKeep(a2))
        XCTAssertEqual(model.keepSymbol(for: a2), "checkmark.circle")
        XCTAssertFalse(model.canKeep(b1), "only a member can be kept")
        XCTAssertTrue(model.canMerge(containing: a2))
        XCTAssertFalse(model.canMerge(containing: b1), "a photo in no group")
        XCTAssertEqual(model.mergeTitle, L10n.string("duplicates.merge"))
    }

    func testTheViewerOpensTheMembersThatTheLibraryShowsAndWaitsForTheTappedOne() async {
        let (model, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await model.load()
        let shown = [a1, a3].map { PhotoItem(uid: $0, captureTime: date(0), mediaType: "image/jpeg") }
        let item = { (uid: PhotoUID) in shown.first { $0.uid == uid } }

        let opened = model.viewerItems(opening: a3, inGroup: "A", item: item)
        XCTAssertEqual(opened?.items.map(\.uid), [a1, a3], "a copy that the library does not show yet stays out")
        XCTAssertEqual(opened?.index, 1)
        XCTAssertNil(model.viewerItems(opening: a2, inGroup: "A", item: item), "the tapped copy is not ready")
        XCTAssertNil(model.viewerItems(opening: b1, inGroup: "A", item: item))
    }

    // MARK: - Facts of each copy

    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    private func facts(
        shared: Bool = false, album: Bool = false, favorite: Bool = false, backedUp: Bool = false, date: Date? = nil
    ) -> ExactDuplicateKeepFacts {
        ExactDuplicateKeepFacts(
            isInOwnAlbum: album, isFavorite: favorite, isNamedByManifest: backedUp, captureDate: date, isShared: shared)
    }

    /// A ranked group of `a1` and `a2` that keeps `a1`.
    private func rankedPair(
        _ first: ExactDuplicateKeepFacts, _ second: ExactDuplicateKeepFacts
    ) -> ExactDuplicatesModel.Group {
        let pair = ExactDuplicateGroup(contentHash: "P", hashKeyEpoch: "e", members: [a1, a2])
        var group = ExactDuplicatesModel.Group(scanGroup: pair, members: [a1, a2], kept: a1)
        group.rank([a1, a2], shared: [], facts: [a1: first, a2: second])
        return group
    }

    func testTheRankingGivesEachCopyItsBadgesInRankingOrderAndNoBadgeBefore() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.ranked = ["A": [a3, a1, a2]]
        finder.facts = ["A": [a3: facts(shared: true, album: true, favorite: true, backedUp: true), a1: facts()]]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks the groups")
        XCTAssertEqual(model.groups.first?.badges(of: a3), [], "no badge before the ranking read the facts")
        XCTAssertNil(model.groups.first?.stayReason)

        finder.rankGate.open()
        await load.value
        let group = model.groups.first
        XCTAssertEqual(group?.badges(of: a3), [.shared, .album, .favorite, .backedUpHere])
        XCTAssertEqual(group?.badges(of: a1), [], "no badge means only in the library")
        XCTAssertEqual(group?.badges(of: a2), [], "a member without facts has no badge")
    }

    func testTheKeptCopyStaysForTheFirstFactThatSetsItApartThenForItsAge() {
        let early = date(0)
        let late = date(60 * 60 * 24)
        let cases: [(ExactDuplicateKeepFacts, ExactDuplicateKeepFacts, ExactDuplicateStayReason)] = [
            (facts(shared: true, album: true), facts(album: true), .badge(.shared)),
            (facts(album: true, favorite: true), facts(favorite: true), .badge(.album)),
            (facts(favorite: true, backedUp: true), facts(backedUp: true), .badge(.favorite)),
            (facts(backedUp: true, date: early), facts(date: late), .oldest),
            (facts(favorite: true, date: early), facts(favorite: true, date: late), .oldest),
            (facts(album: true, date: early), facts(album: true, date: early), .identical),
            (facts(date: early), facts(), .identical),
        ]
        for (index, (first, second, reason)) in cases.enumerated() {
            XCTAssertEqual(rankedPair(first, second).stayReason, reason, "case \(index)")
        }
    }

    func testTheStayReasonNeverNamesTheBackupOfThisDevice() {
        let early = date(0)
        let late = date(60)
        for kept in [facts(backedUp: true), facts(backedUp: true, date: early), facts(backedUp: true, date: late)] {
            for other in [facts(), facts(date: early), facts(date: late), facts(backedUp: true)] {
                let reason = rankedPair(kept, other).stayReason
                XCTAssertNotEqual(reason, .badge(.backedUpHere), "\(kept) against \(other)")
                XCTAssertNotEqual(reason?.text, "Stays: backed up from this device")
            }
        }
        XCTAssertEqual(rankedPair(facts(backedUp: true), facts()).stayReason, .identical)
        let badges = rankedPair(facts(backedUp: true), facts()).badges(of: a1)
        XCTAssertEqual(badges, [.backedUpHere], "the badge stays as information")
    }

    func testAChosenCopyWithoutAnAdvantageStaysBecauseTheCopiesAreIdentical() {
        var group = rankedPair(facts(favorite: true), facts())
        group.kept = a2
        XCTAssertEqual(group.stayReason, .identical, "the merge carries the favorite over, so any copy can stay")
        XCTAssertEqual(group.stayReason?.text, L10n.string("duplicates.stays_any"))
    }

    func testTheFooterJoinsTheReasonAndTheFreedSpaceAndAnUnrankedGroupShowsOnlyTheFreedSpace() async {
        let finder = FakeDuplicateFinder(
            scans: [.init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 1_000_000, "B": 10])])
        finder.unreadableGroups = ["B"]
        finder.facts = ["A": [a1: facts(album: true), a2: facts(), a3: facts()]]
        let (model, _) = makeModel(finder)
        await model.load()
        let frees = L10n.string("duplicates.group_frees \(ExactDuplicatesModel.byteText(2_000_000))")
        XCTAssertEqual(
            model.groups.first { $0.id == "A" }?.footerText,
            "\(L10n.string("duplicates.stays_album")) · \(frees)")
        XCTAssertEqual(
            model.groups.first { $0.id == "B" }?.footerText,
            L10n.string("duplicates.group_frees \(ExactDuplicatesModel.byteText(10))"),
            "before the ranking, only the freed space")
        XCTAssertEqual(
            model.totalFreedText,
            L10n.string("duplicates.total_frees \(ExactDuplicatesModel.byteText(2_000_010))"))
    }

    func testTheHeaderShowsTheCaptureDayOrTheFirstAndTheLastDayAndTheCopiesWithoutADate() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let day = Calendar.current.startOfDay(for: date(0))
        let later = Calendar.current.date(byAdding: .day, value: 5, to: day) ?? day
        finder.dates = [
            a1: day.addingTimeInterval(3_600), a2: day.addingTimeInterval(7_200), a3: day.addingTimeInterval(60),
            b1: later.addingTimeInterval(60), b2: day.addingTimeInterval(60),
        ]
        let (model, _) = makeModel(finder)
        await model.load()
        let text = { (date: Date) in date.formatted(date: .numeric, time: .omitted) }
        XCTAssertEqual(model.groups[0].title, text(day), "copies of one day show that day once")
        XCTAssertEqual(
            model.groups[1].title, L10n.string("duplicates.dates \(text(day)) \(text(later))"),
            "the first day and the last day, joined")

        let (undated, _) = makeModel(FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)]))
        await undated.load()
        XCTAssertNil(undated.groups[0].dateText)
        XCTAssertEqual(undated.groups[0].title, L10n.string("duplicates.group_title \(3)"))
    }

    func testEachCopyHasItsOwnSizeAndTheMergeFreesTheSizesOfTheOtherCopies() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete, byteSizes: ["A": 100])])
        finder.memberSizes = ["A": [a1: 100, a2: 200, a3: 300]]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.groups[0].byteSize(of: a2), 200)
        XCTAssertEqual(model.groups[0].freedBytes, 500, "a1 stays, so a2 and a3 are freed")
        model.keep(a3, inGroup: "A")
        XCTAssertEqual(model.groups[0].freedBytes, 300, "a3 stays, so a1 and a2 are freed")
    }

    func testEachCopyIsSpokenWithItsPositionItsStateItsBadgesAndItsSize() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete, byteSizes: ["A": 2_048])])
        finder.facts = ["A": [a1: facts(favorite: true), a2: facts(), a3: facts()]]
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.byteText(2_048)
        XCTAssertEqual(
            model.groups[0].accessibilityLabel(of: a1),
            [
                L10n.string("duplicates.member_label \(1) \(3)"), L10n.string("duplicates.member_kept"),
                ExactDuplicateBadge.favorite.title, size,
            ].joined(separator: ", "))
        XCTAssertEqual(
            model.groups[0].accessibilityLabel(of: a2),
            [L10n.string("duplicates.member_label \(2) \(3)"), size].joined(separator: ", "))
    }

    func testTheScreenCountsEveryCopyAndOffersToKeepAnyOther() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.copyCount, 5)
        XCTAssertEqual(model.mergeAllTitle, L10n.string("duplicates.merge_all_title \(5)"))
        XCTAssertEqual(model.mergeAllConfirmTitle, L10n.string("duplicates.merge_all_confirm \(5)"))
        XCTAssertEqual(model.mergeAllMessage, L10n.string("duplicates.merge_all_message \(3)"))
        XCTAssertEqual(model.keepTitle(for: a1), L10n.string("duplicates.kept"))
        XCTAssertEqual(model.keepTitle(for: a2), L10n.string("duplicates.keep_this_copy"))
        model.keep(a2, inGroup: "A")
        XCTAssertEqual(model.keepTitle(for: a2), L10n.string("duplicates.kept"))
        let group = model.groups[0]
        XCTAssertEqual(group.keepTitle(for: a2), L10n.string("duplicates.kept"), "a row reads its title from its group")
        XCTAssertEqual(group.keepTitle(for: a1), L10n.string("duplicates.keep_this_copy"))
    }

    // MARK: - Ranking only what the screen shows

    private func manyGroups(_ count: Int) -> [ExactDuplicateGroup] {
        (0..<count).map { index in
            ExactDuplicateGroup(
                contentHash: String(format: "G%04d", index), hashKeyEpoch: "e",
                members: [
                    PhotoUID(volumeID: "v", nodeID: "g\(index)-1"), PhotoUID(volumeID: "v", nodeID: "g\(index)-2"),
                ])
        }
    }

    func testOpeningRanksTwoPagesAndScrollingRanksTheShownPageAndTheNext() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(groups.prefix(2 * size).map(\.id)))
        XCTAssertEqual(model.groups.filter(\.isRanked).count, 2 * size)

        model.groupAppeared(groups[5 * size + 3].id)
        await waitUntil({ model.groups.filter(\.isRanked).count == 4 * size }, "the shown pages rank")
        let expected = groups.prefix(2 * size).map(\.id) + groups[(5 * size)..<(7 * size)].map(\.id)
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(expected))
        XCTAssertEqual(finder.rankedGroups.joined().count, 4 * size, "no group is read twice")
    }

    func testABurstOfAllSectionsRanksOnlyAroundTheLastOneWithOneRanking() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize

        // The macOS list shows every section in one update.
        for group in groups { model.groupAppeared(group.id) }
        let lastPage = (groups.count - 1) / size * size
        let expected = groups.prefix(2 * size).map(\.id) + groups[lastPage...].map(\.id)
        await waitUntil({ model.groups.filter(\.isRanked).count == expected.count }, "the last shown page ranks")
        try? await Task.sleep(for: ExactDuplicatesModel.appearancePause * 3)
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(expected))
        XCTAssertEqual(finder.rankedGroups.joined().count, expected.count, "no group is read twice")
        XCTAssertEqual(finder.maximumConcurrentRankings, 1, "one ranking at a time")
        XCTAssertNil(model.rankingLine, "the ranking finished")
    }

    func testAScrollThatStopsAcrossTwoPagesRanksAroundTheFirstAndTheLastShownGroup() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize

        // The scroll stops with the end of page 2 and the start of page 3 visible.
        for index in (3 * size - 3)...(3 * size) { model.groupAppeared(groups[index].id) }
        await waitUntil({ model.groups.filter(\.isRanked).count == 5 * size }, "pages 2, 3, and 4 rank")
        XCTAssertEqual(Set(finder.rankedGroups.joined()), Set(groups.prefix(5 * size).map(\.id)))
        XCTAssertTrue(model.groups[3 * size - 3].isRanked, "the first shown group ranks")
    }

    func testAClosedScreenStopsTheRankingAndRanksNoGroupItShowedBefore() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        finder.rankGate.close()
        model.groupAppeared(groups[10 * size].id)
        await waitUntil({ finder.rankGate.hasWaiters }, "page 10 ranks")
        model.groupAppeared(groups[20 * size].id)

        model.screenDisappeared()
        finder.rankGate.open()
        try? await Task.sleep(for: ExactDuplicatesModel.appearancePause * 3)
        await waitUntil({ model.rankingLine == nil }, "the ranking stops")
        let requested = Set(finder.rankedGroups.joined())
        XCTAssertFalse(requested.contains(groups[11 * size].id), "the running ranking reads no further page")
        XCTAssertFalse(requested.contains(groups[20 * size].id), "a group shown before the close does not rank")
    }

    func testTheRankingQueueKeepsTheNewestPagesAndAnOlderPageRanksWhenShownAgain() async {
        let groups = manyGroups(1_500)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        // The scroll ranking shows no progress row, so the test reads the queue that the model keeps for it.
        func progress(_ total: Int) -> ExactDuplicateScanProgress {
            ExactDuplicateScanProgress(completed: 0, total: total)
        }
        finder.rankGate.close()
        model.groupAppeared(groups[10 * size].id)
        await waitUntil({ finder.rankGate.hasWaiters }, "page 10 ranks")
        model.groupAppeared(groups[20 * size].id)
        await waitUntil({ model.rankingProgress == progress(4 * size) }, "pages 20 and 21 wait")
        model.groupAppeared(groups[30 * size].id)
        // Pages 11, 20, 21, 30, and 31 exceed the queue; page 11 gives way.
        await waitUntil({ model.rankingProgress == progress(5 * size) }, "pages 30 and 31 wait")
        finder.rankGate.open()
        await waitUntil({ model.rankingProgress == nil }, "the ranking finishes")
        let ranked = Set(model.groups.filter(\.isRanked).map(\.id))
        for page in [0, 1, 10, 20, 21, 30, 31] {
            XCTAssertTrue(
                groups[(page * size)..<((page + 1) * size)].allSatisfy { ranked.contains($0.id) }, "page \(page)")
        }
        XCTAssertFalse(ranked.contains(groups[11 * size].id), "the oldest queued page gave way")

        model.groupAppeared(groups[11 * size].id)
        await waitUntil({ model.groups[11 * size].isRanked }, "page 11 ranks when shown again")
    }

    func testScrollingStillRanksAfterAMergeRanAlongsideTheScrollRanking() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        finder.rankGate.close()
        model.groupAppeared(groups[50].id)
        await waitUntil({ finder.rankGate.hasWaiters }, "scrolling ranks")
        let merge = Task { await model.merge(groupID: groups[90].id) }
        for _ in 0..<2_000 where finder.rankedGroups.count < 3 { try? await Task.sleep(for: .milliseconds(1)) }
        finder.rankGate.open()
        await merge.value
        await waitUntil(
            { model.groups.first { $0.id == groups[50].id }?.isRanked == true }, "the scroll ranking finishes")

        model.groupAppeared(groups[98].id)
        await waitUntil(
            { model.groups.first { $0.id == groups[98].id }?.isRanked == true }, "scrolling ranks after the merge")
    }

    func testScrollingDuringMergeAllKeepsTheProgressOfTheMerge() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let unranked = 100 - 2 * ExactDuplicatesModel.rankingPageSize
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        model.groupAppeared(groups[60].id)
        await waitUntil({ finder.rankedGroups.count >= 3 }, "scrolling ranks beside the merge")
        XCTAssertEqual(
            model.rankingLine?.detail,
            L10n.string("duplicates.ranking_progress \(0.formatted()) \(unranked.formatted())"),
            "the merge keeps its progress row")
        finder.rankGate.open()
        await merge.value
    }

    func testABuildThatFinishesDuringAMergeReadsTheGroupsAfterTheMerge() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .indexing), .init(groups: [groupA, groupB], coverage: .complete),
        ])
        finder.buildChanged = true
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        finder.mergeGate.close()
        let merge = Task { await model.merge(groupID: "A") }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        finder.buildGate.open()
        await load.value
        XCTAssertEqual(finder.scanCalls, 1, "a merge holds the list")

        finder.mergeGate.open()
        await merge.value
        XCTAssertEqual(model.groups.map(\.id).contains("B"), true, "the groups of the new index show after the merge")
    }

    func testAServiceStopOfTheCheckDuringAMergeRestartsTheCheckAfterTheMerge() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .indexing)])
        finder.buildError = CancellationError()
        finder.buildProgress = [.init(phase: .indexing, completed: 10, total: 100)]
        finder.buildGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.buildGate.hasWaiters }, "the load builds the index")
        finder.mergeGate.close()
        let merge = Task { await model.merge(groupID: "A") }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        finder.buildGate.open()
        await load.value
        XCTAssertNil(model.checkLine)
        XCTAssertNil(model.checkFailedNote, "a stopped check did not fail")

        finder.buildError = nil
        finder.buildGate.close()
        finder.mergeGate.open()
        await merge.value
        await waitUntil({ finder.buildCalls == 2 }, "the check starts again after the merge")
        await waitUntil({ model.checkLine != nil }, "the screen shows the check again")
        XCTAssertEqual(model.checkLine?.title, L10n.string("duplicates.checking_title"))
        finder.buildGate.open()
    }

    func testAScreenThatOpensAgainReadsNothingForUnchangedGroups() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let reads = finder.rankCalls
        await model.load()
        XCTAssertEqual(finder.rankCalls, reads, "the ranked facts stay for the session")
    }

    func testMergeAllReadsTheGroupsThatNobodyScrolledToWithProgress() async {
        let groups = manyGroups(60)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        let size = ExactDuplicatesModel.rankingPageSize
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All reads the remaining groups")
        XCTAssertEqual(finder.rankedGroups.last?.count, 60 - 2 * size)
        XCTAssertEqual(
            model.rankingLine?.detail,
            L10n.string("duplicates.ranking_progress \(0.formatted()) \((60 - 2 * size).formatted())"))
        finder.rankGate.open()
        await merge.value
        XCTAssertEqual(finder.batches.flatMap { $0 }.count, 60)
    }

    func testTheEntryCountScansWithoutRanking() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.loadCountIfNeeded()
        XCTAssertEqual(model.knownDuplicateCount, 3)
        XCTAssertEqual(finder.rankCalls, 0)
        await model.loadCountIfNeeded()
        XCTAssertEqual(finder.scanCalls, 1, "the entry counts once")
    }

    // MARK: - The photo to keep

    func testTheRankedFirstMemberIsKeptByDefault() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.ranked = ["A": [a3, a1, a2]]
        let (model, _) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.groups.first?.members, [a3, a1, a2])
        XCTAssertEqual(model.groups.first?.kept, a3)
    }

    func testTappingAnotherMemberKeepsItAndTheMergeUsesIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a2, inGroup: "A")
        model.keep(b1, inGroup: "A")
        XCTAssertEqual(model.groups.first?.kept, a2, "a photo of another group is never kept")
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.merges.map(\.kept), [a2])
    }

    func testAChoiceSurvivesAReloadWhileItsPhotoIsStillAMember() async {
        let shrunk = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a3])
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .complete), .init(groups: [groupA], coverage: .complete),
            .init(groups: [shrunk], coverage: .complete),
        ])
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a2, inGroup: "A")
        await model.load()
        XCTAssertEqual(model.groups.first?.kept, a2)
        await model.load()
        XCTAssertEqual(model.groups.first?.kept, a1, "a choice that left the group falls back to the ranking")
    }

    // MARK: - Merge

    func testMergingOneGroupRemovesOnlyThatGroupAndHidesTheTrashedPhotos() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "B")
        XCTAssertEqual(finder.merges.map(\.group), ["B"])
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(log.calls, [[b2]])
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.knownDuplicateCount, 2)
        XCTAssertFalse(model.isMerging)
    }

    func testMergeAllMergesEveryGroupAndReportsTheTrashOnce() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        XCTAssertEqual(model.duplicateCount, 3, "Merge All asks for the photos that move to Recently Deleted")
        await model.mergeAll()
        XCTAssertEqual(Set(finder.merges.map(\.group)), ["A", "B"])
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(Set(log.calls.first ?? []), [a2, a3, b2])
    }

    func testEveryMergeTellsTheFinderWhetherThePersonChoseThePhotoToKeep() async {
        let groupC = ExactDuplicateGroup(
            contentHash: "C", hashKeyEpoch: "e",
            members: [PhotoUID(volumeID: "v", nodeID: "c1"), PhotoUID(volumeID: "v", nodeID: "c2")])
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB, groupC], coverage: .complete)])
        finder.outcomes = ["A": .skipped(.keptLeftLibrary), "B": .skipped(.keptLeftLibrary)]
        let (model, _) = makeModel(finder)
        await model.load()

        await model.merge(groupID: "A")
        XCTAssertEqual(finder.choices, ["A": false], "the screen preselected the photo")
        XCTAssertEqual(model.group(withID: "A")?.isKeptChosen, false, "a merge makes no choice of the person")

        model.keep(a2, inGroup: "A")
        await model.merge(containing: a2)
        XCTAssertEqual(finder.choices, ["A": true], "the viewer merges the photo that the person chose")

        model.keep(b2, inGroup: "B")
        await model.mergeAll()
        XCTAssertEqual(finder.choices, ["A": true, "B": true, "C": false])
    }

    func testMergeAllHandsEveryGroupToTheFinderInOneBatch() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        let (model, _) = makeModel(finder)
        await model.load()
        await model.mergeAll()
        XCTAssertEqual(finder.batches, [["A", "B"]], "the finder reads the facts that the groups share once")
    }

    // MARK: - Merge All in batches

    /// A loaded model with `count` groups. Merge All ranks the groups after the first two pages itself.
    private func loadedModel(groups count: Int) async -> (ExactDuplicatesModel, FakeDuplicateFinder, TrashLog) {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(count), coverage: .complete)])
        let (model, log) = makeModel(finder)
        await model.load()
        return (model, finder, log)
    }

    private func mergeAllLineDetail(_ completed: Int, of total: Int) -> String {
        L10n.string("duplicates.ranking_progress \(completed.formatted()) \(total.formatted())")
    }

    func testMergeAllHandsTheGroupsToTheFinderInBatchesInTheirOrder() async {
        let (model, finder, log) = await loadedModel(groups: 60)
        let ids = model.groups.map(\.id)
        await model.mergeAll()
        let size = ExactDuplicatesModel.mergeBatchSize
        XCTAssertEqual(size, 25)
        XCTAssertEqual(finder.batches, [Array(ids[0..<25]), Array(ids[25..<50]), Array(ids[50..<60])])
        XCTAssertEqual(log.calls.count, 3, "the library stops showing the photos of each batch")
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.mergeAllLine)
        XCTAssertFalse(model.isMergingAll)
    }

    func testMergeAllShowsItsProgressAndTheOutcomeOfEachBatchBeforeTheNext() async {
        let (model, finder, log) = await loadedModel(groups: 60)
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
        XCTAssertEqual(model.mergeAllLine?.title, L10n.string("duplicates.merging_title"))
        XCTAssertEqual(model.mergeAllLine?.detail, mergeAllLineDetail(0, of: 60))
        XCTAssertEqual(model.mergeAllLine?.fraction, 0)
        XCTAssertTrue(model.canStopMergeAll)

        finder.mergeGate.open()
        finder.mergeGate.close()
        await waitUntil({ finder.batches.count == 2 && finder.mergeGate.hasWaiters }, "the second batch runs")
        XCTAssertEqual(model.mergeAllLine?.detail, mergeAllLineDetail(25, of: 60))
        XCTAssertEqual(model.mergeAllLine?.fraction ?? 0, 25.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(model.groups.count, 35, "the first batch left the list before the second started")
        XCTAssertEqual(log.calls.count, 1)

        finder.mergeGate.open()
        await merge.value
        XCTAssertNil(model.mergeAllLine)
        XCTAssertFalse(model.canStopMergeAll)
    }

    func testStopLetsTheRunningBatchFinishAndKeepsTheOtherGroups() async {
        let (model, finder, log) = await loadedModel(groups: 60)
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
        model.stopMergeAll()
        XCTAssertFalse(model.canStopMergeAll, "Stop works once")
        XCTAssertTrue(model.isMerging, "the running batch finishes")

        finder.mergeGate.open()
        await merge.value
        XCTAssertEqual(finder.batches.count, 1)
        XCTAssertEqual(model.groups.count, 35)
        XCTAssertEqual(log.calls.count, 1, "the running batch merged")
        XCTAssertEqual(model.notice, .stopped(merged: 25, total: 60))
        XCTAssertFalse(model.isMerging)
        XCTAssertTrue(model.canMerge, "Merge All can start again")
    }

    func testStopWhileMergeAllRanksMergesNothing() async {
        let (model, finder, log) = await loadedModel(groups: 100)
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        XCTAssertNotNil(model.rankingLine)
        XCTAssertTrue(model.canStopMergeAll, "Stop is offered while Merge All ranks")
        model.stopMergeAll()
        finder.rankGate.open()
        await merge.value
        XCTAssertEqual(finder.cancelledRankings, 1, "Stop ends the ranking")
        XCTAssertTrue(finder.batches.isEmpty)
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(model.groups.count, 100)
        XCTAssertEqual(model.notice, .stopped(merged: 0, total: 100))
        XCTAssertNil(model.rankingLine)
    }

    func testStopBeforeTheRankingReportsAPageEndsAsStopped() async {
        let groups = manyGroups(100)
        let finder = FakeDuplicateFinder(scans: [.init(groups: groups, coverage: .complete)])
        // No group is ranked yet when Merge All starts.
        finder.unreadableGroups = Set(groups.map(\.id))
        let (model, log) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        finder.reportsNothingWhenCancelled = true
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")
        model.stopMergeAll()
        finder.rankGate.open()
        await merge.value
        XCTAssertTrue(finder.batches.isEmpty)
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(model.notice, .stopped(merged: 0, total: 100), "a stop is no failure")
    }

    func testABatchInWhichNoGroupMergedStopsMergeAll() async {
        let (model, finder, log) = await loadedModel(groups: 75)
        let ids = model.groups.map(\.id)
        for id in ids[25..<50] { finder.mergeErrors[id] = URLError(.notConnectedToInternet) }
        await model.mergeAll()
        XCTAssertEqual(finder.batches.count, 2, "no batch follows a batch that failed completely")
        XCTAssertEqual(model.groups.count, 50)
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(model.notice, .stopped(merged: 25, total: 75))
    }

    func testOneFailedGroupDoesNotStopMergeAll() async {
        let (model, finder, _) = await loadedModel(groups: 60)
        finder.mergeErrors[model.groups[3].id] = URLError(.notConnectedToInternet)
        await model.mergeAll()
        XCTAssertEqual(finder.batches.count, 3)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.notice, .failed)
    }

    func testTheStoppedNoticeCountsTheMergedGroupsOfAllGroups() {
        let notice = ExactDuplicateMergeNotice.stopped(merged: 320, total: 1_404)
        XCTAssertEqual(
            notice.title, L10n.string("duplicates.merge_stopped \(320.formatted()) \(1_404.formatted())"))
        XCTAssertEqual(notice.message, "", "the title says everything")
    }

    func testAPauseWaitsForTheRunningBatchAndMergeAllContinuesAfterIt() async {
        let (model, finder, _) = await loadedModel(groups: 60)
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
        let paused = TrashLog()
        model.pauseMerging()
        let pause = Task {
            await model.runningMergeWorkEnded()
            paused.calls.append([])
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(paused.calls.isEmpty, "the pause waits for the running batch")

        finder.mergeGate.open()
        await pause.value
        XCTAssertEqual(paused.calls.count, 1)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(finder.batches.count, 1, "no batch starts during the pause")
        XCTAssertEqual(model.mergeAllLine?.detail, mergeAllLineDetail(25, of: 60))

        model.resumeMerging()
        await merge.value
        XCTAssertEqual(finder.batches.count, 3)
        XCTAssertNil(model.notice)
    }

    func testCancellingAPausedMergeAllEndsTheRunAndReleasesTheModel() async {
        let finished = expectation(description: "The cancelled merge finishes")
        var loaded: (ExactDuplicatesModel, FakeDuplicateFinder, TrashLog)? = await loadedModel(groups: 60)
        weak var released = loaded?.0
        let finder = loaded!.1
        var model: ExactDuplicatesModel? = loaded?.0
        loaded = nil
        finder.mergeGate.close()
        let merge = Task { [model] in
            await model?.mergeAll()
            finished.fulfill()
        }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
        model?.pauseMerging()
        finder.mergeGate.open()
        await model?.runningMergeWorkEnded()
        // The run is paused between batches; cancelling it must finish its waiter without a resume action.
        merge.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(model?.isMerging ?? true)
        XCTAssertEqual(finder.batches.count, 1, "cancellation must not start another batch")
        // Also clean up the deliberately broken implementation during the negative control.
        model?.stopMergeAll()
        await merge.value
        model?.screenDisappeared()
        model = nil
        XCTAssertNil(released)
    }

    func testCancellingMergeAllAlsoCancelsItsRunningRanking() async {
        let (model, finder, log) = await loadedModel(groups: 100)
        finder.rankGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.rankGate.hasWaiters }, "Merge All ranks")

        merge.cancel()
        finder.rankGate.open()
        await merge.value

        XCTAssertEqual(finder.cancelledRankings, 1, "the merge must cancel its ranking before joining it")
        XCTAssertTrue(finder.batches.isEmpty, "a cancelled merge must not start a batch")
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(model.groups.count, 100)
        XCTAssertFalse(model.isMerging)
        XCTAssertEqual(model.notice, .stopped(merged: 0, total: 100))
    }

    func testCancellationResumeAndStopRetireEachPauseWaiterOnce() async {
        for order in 0..<4 {
            let (model, finder, _) = await loadedModel(groups: 60)
            finder.mergeGate.close()
            let merge = Task { await model.mergeAll() }
            await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
            model.pauseMerging()
            if order == 3 { merge.cancel() }
            finder.mergeGate.open()
            await model.runningMergeWorkEnded()

            switch order {
            case 0:
                merge.cancel()
                model.resumeMerging()
                model.stopMergeAll()
            case 1:
                model.resumeMerging()
                merge.cancel()
                model.stopMergeAll()
            case 2:
                model.stopMergeAll()
                merge.cancel()
                model.resumeMerging()
            default:
                model.resumeMerging()
                model.stopMergeAll()
            }
            merge.cancel()
            await merge.value
            XCTAssertFalse(model.isMerging)
            XCTAssertEqual(finder.batches.count, 1, "no batch starts after cancellation")
            XCTAssertEqual(model.notice, .stopped(merged: 25, total: 60))
        }
    }

    func testAccountReplacementStopsTheOldMergeAndReleasesTheModel() async {
        for paused in [false, true] {
            for replacing in [false, true] {
                let finished = expectation(description: "The old account's merge finishes")
                let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
                let lifetime = ExactDuplicatesAccountLifetime()
                var model = lifetime.replace(with: finder)
                weak var released = model
                await model?.load()
                finder.mergeGate.close()
                let merge = Task { [model] in
                    await model?.mergeAll()
                    finished.fulfill()
                }
                await waitUntil({ finder.mergeGate.hasWaiters }, "the old account's first batch runs")
                if paused {
                    model?.pauseMerging()
                    finder.mergeGate.open()
                    await model?.runningMergeWorkEnded()
                }
                if replacing {
                    _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
                } else {
                    lifetime.retire()
                }
                if !paused {
                    XCTAssertTrue(model?.isMerging ?? false, "Stop must join the running batch")
                    finder.mergeGate.open()
                }
                model?.screenDisappeared()
                model = nil
                await fulfillment(of: [finished], timeout: 2)
                XCTAssertEqual(finder.batches.count, 1, "Account replacement starts no further batch")
                XCTAssertNil(released, "The completed old run must release its model")
                // Also retire the deliberately broken implementation during the negative control.
                released?.stopMergeAll()
                await merge.value
            }
        }
    }

    func testAccountRetirementDiscardsARescanPendingAfterAMerge() async {
        await assertRetirementStartsNoMergeFollowup(buildChanged: true)
    }

    func testAccountRetirementDoesNotReloadAfterAStaleMergeResult() async {
        await assertRetirementStartsNoMergeFollowup(stale: true)
    }

    func testAccountRetirementDoesNotRestartAnInterruptedCheckAfterAMerge() async {
        await assertRetirementStartsNoMergeFollowup(interrupted: true)
    }

    func testAccountRetirementDiscardsAnIndexCompletionAfterTheBatch() async {
        for interrupted in [false, true] {
            await assertRetirementStartsNoMergeFollowup(
                buildChanged: true, interrupted: interrupted, finishesBeforeRetirement: false)
        }
    }

    private func assertRetirementStartsNoMergeFollowup(
        buildChanged: Bool = false, stale: Bool = false, interrupted: Bool = false,
        finishesBeforeRetirement: Bool = true
    ) async {
        for replacing in [false, true] {
            for all in [false, true] {
                let finder = FakeDuplicateFinder(scans: [
                    .init(groups: [groupA], coverage: .indexing),
                    .init(groups: [groupB], coverage: .complete),
                ])
                finder.buildChanged = buildChanged
                finder.buildError = interrupted ? CancellationError() : nil
                if stale { finder.outcomes["A"] = .skipped(.keyChanged) }
                finder.buildGate.close()
                let lifetime = ExactDuplicatesAccountLifetime()
                var model = lifetime.replace(with: finder)
                weak var released = model
                let load = Task { [model] in await model?.load() }
                await waitUntil({ finder.buildGate.hasWaiters }, "The old account builds its index")
                await waitUntil({ model?.groups.first?.isRanked == true }, "The merge's group is ranked")
                finder.mergeGate.close()
                let merge = Task { [model] in
                    if all { await model?.mergeAll() } else { await model?.merge(groupID: "A") }
                }
                await waitUntil({ finder.mergeGate.hasWaiters }, "The old account's batch runs")
                if finishesBeforeRetirement {
                    finder.buildGate.open()
                    await load.value
                }
                XCTAssertEqual(finder.scanCalls, 1, "The running merge holds the rescan")
                let rankings = finder.rankCalls
                // Hold any incorrect restart so weak-nil also detects its retained model.
                if interrupted { finder.buildGate.close() }
                if replacing {
                    _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
                } else {
                    lifetime.retire()
                }
                XCTAssertTrue(model?.isMerging ?? false, "Retirement still joins the running batch")
                model?.screenDisappeared()
                model = nil
                XCTAssertNotNil(released, "The running batch still owns the old model")
                finder.mergeGate.open()
                await merge.value
                if !finishesBeforeRetirement {
                    XCTAssertNotNil(released, "Retirement also joins the index build already in progress")
                    finder.buildGate.open()
                    await load.value
                }
                await waitUntil({ released == nil }, "The joined work releases its retired model")
                XCTAssertEqual(finder.batches.count, 1, "Retirement admits no further backend batch")
                XCTAssertEqual(finder.scanCalls, 1, "Retirement starts no scan or reload")
                XCTAssertEqual(finder.rankCalls, rankings, "Retirement starts no ranking")
                XCTAssertEqual(finder.buildCalls, 1, "Retirement starts no index build")
                finder.buildGate.open()
                await waitUntil({ released == nil }, "Cleanup releases an incorrect index restart")
            }
        }
    }

    func testAccountRetirementWhileASingleMergeRanksStartsNoBatch() async throws {
        for replacing in [false, true] {
            let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(100), coverage: .complete)])
            let lifetime = ExactDuplicatesAccountLifetime()
            var model = lifetime.replace(with: finder)
            weak var released = model
            await model?.load()
            let group = try XCTUnwrap(model?.groups.first { !$0.isRanked })
            finder.rankGate.close()
            let merge = Task { [model] in await model?.merge(groupID: group.id) }
            await waitUntil({ finder.rankGate.hasWaiters }, "The single merge ranks before its batch")
            XCTAssertTrue(model?.isMerging ?? false)
            XCTAssertFalse(model?.isMergingAll ?? true)

            if replacing {
                _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
            } else {
                lifetime.retire()
            }
            finder.rankGate.open()
            await merge.value

            XCTAssertEqual(finder.cancelledRankings, 1, "Account retirement cancels single-merge ranking")
            XCTAssertTrue(
                finder.batches.isEmpty, "No old-account batch starts after retirement, even with a late ranking page")
            XCTAssertEqual(model?.groups.count, 100)
            XCTAssertFalse(model?.isMerging ?? true)
            XCTAssertFalse(model?.canMerge ?? true)
            model?.screenDisappeared()
            model = nil
            XCTAssertNil(released, "The completed single merge releases its retired model")
        }
    }

    func testRetiredBatchCannotPublishWithAReplacementAccountToken() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
        let lifetime = ExactDuplicatesAccountLifetime()
        var published = 0
        let model = lifetime.replace(with: finder) { _, _ in published += 1 }!
        await model.load()
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")

        _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
        finder.mergeGate.open()
        await merge.value

        XCTAssertEqual(published, 0, "A retired batch cannot enter its publication callback")
        XCTAssertEqual(finder.batches.count, 1)
    }

    func testAccountReplacementInvalidatesAnAlreadySuspendedCallback() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
        let lifetime = ExactDuplicatesAccountLifetime()
        let callback = BuildGate()
        callback.close()
        var published = 0
        let model = lifetime.replace(with: finder) { _, token in
            XCTAssertTrue(lifetime.isCurrent(token))
            await callback.pass()
            if lifetime.isCurrent(token) { published += 1 }
        }!
        await model.load()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ callback.hasWaiters }, "the callback suspended before publishing")

        _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
        callback.open()
        await merge.value

        XCTAssertEqual(published, 0, "Every publication after suspension must reject the retired token")
        XCTAssertEqual(finder.batches.count, 1)
    }

    func testAQueuedMergeCannotStartAfterAccountRetirement() async throws {
        for all in [false, true] {
            for replacing in [false, true] {
                let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(1), coverage: .complete)])
                let lifetime = ExactDuplicatesAccountLifetime()
                let model = try XCTUnwrap(lifetime.replace(with: finder))
                await model.load()
                let group = try XCTUnwrap(model.groups.first)
                XCTAssertTrue(model.canMerge)
                // This task cannot start until the synchronous retirement below yields the main actor.
                let merge = Task {
                    if all {
                        await model.mergeAll()
                    } else {
                        await model.merge(groupID: group.id)
                    }
                }
                if replacing {
                    _ = lifetime.replace(with: FakeDuplicateFinder(scans: []))
                } else {
                    lifetime.retire()
                }
                XCTAssertFalse(model.canMerge, "A retired account cannot admit another merge")
                await merge.value
                XCTAssertTrue(finder.batches.isEmpty, "A queued UI task cannot merge the retired account")
                XCTAssertEqual(model.groups.count, 1)
            }
        }
    }

    func testCurrentAccountReceivesEveryCompletedMergeBatch() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: manyGroups(60), coverage: .complete)])
        let lifetime = ExactDuplicatesAccountLifetime()
        var published = 0
        let model = lifetime.replace(with: finder) { _, token in
            XCTAssertTrue(lifetime.isCurrent(token))
            published += 1
        }!
        await model.load()
        await model.mergeAll()
        XCTAssertEqual(published, 3)
    }

    func testAResumeRightAfterThePauseKeepsMergeAllRunning() async {
        let (model, finder, _) = await loadedModel(groups: 60)
        finder.mergeGate.close()
        let merge = Task { await model.mergeAll() }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the first batch runs")
        // The app goes to the background and is active again before the running batch ends.
        model.pauseMerging()
        let wait = Task { await model.runningMergeWorkEnded() }
        model.resumeMerging()
        finder.mergeGate.open()
        await wait.value
        await merge.value
        XCTAssertEqual(finder.batches.count, 3, "the merge continues after a quick return")
        XCTAssertNil(model.notice)
    }

    func testMergingOneGroupShowsNoMergeAllProgressAndCannotStop() async {
        let (model, finder, _) = await loadedModel(groups: 60)
        let id = model.groups[0].id
        finder.mergeGate.close()
        let merge = Task { await model.merge(groupID: id) }
        await waitUntil({ finder.mergeGate.hasWaiters }, "the merge runs")
        XCTAssertNil(model.mergeAllLine)
        XCTAssertFalse(model.canStopMergeAll)
        model.stopMergeAll()
        finder.mergeGate.open()
        await merge.value
        XCTAssertEqual(finder.batches, [[id]])
        XCTAssertEqual(model.groups.count, 59)
        XCTAssertNil(model.notice)
    }

    func testAKeptDuplicateGivesOneShortReasonAndTheGroupStaysWithIt() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.outcomes["A"] = .merged(
            kept: a1, trashed: [], keptDuplicates: [a2: .unreadable, a3: .neededByLocalSource])
        finder.outcomes["B"] = .merged(kept: b1, trashed: [], keptDuplicates: [b2: .relatedFileWithoutTwin])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(model.notice, .keptDuplicates(count: 2, reason: .neededByLocalSource))
        XCTAssertEqual(model.groups.map(\.id), ["A", "B"])
        XCTAssertEqual(model.groups.first?.keptReason, .neededByLocalSource)
        XCTAssertEqual(model.groups.first?.keptReasonMessage, model.notice?.message)
        XCTAssertTrue(log.calls.isEmpty, "nothing moved to Recently Deleted")
        model.dismissNotice()
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.groups.first?.keptReason, .neededByLocalSource, "the reason stays with its group")

        await model.mergeAll()
        XCTAssertEqual(model.notice, .keptDuplicates(count: 3, reason: .relatedFileWithoutTwin))
        XCTAssertEqual(model.groups.last?.keptReason, .relatedFileWithoutTwin)
    }

    func testAMergeRemovesOnlyTheTrashedMembersAndThePersonCanKeepAnotherPhoto() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.outcomes["A"] = .merged(kept: a1, trashed: [a2], keptDuplicates: [a3: .pendingEditReplacement])
        let (model, log) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(log.calls, [[a2]])
        XCTAssertEqual(model.groups.first?.members, [a1, a3])
        XCTAssertEqual(model.groups.first?.scanGroup.members, [a1, a3])
        XCTAssertEqual(model.groups.first?.kept, a1)
        XCTAssertEqual(model.groups.first?.keptReason, .pendingEditReplacement)
        XCTAssertEqual(model.knownDuplicateCount, 1)

        finder.outcomes["A"] = nil
        model.keep(a3, inGroup: "A")
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.merges.last, .init(group: "A", kept: a3))
        XCTAssertEqual(log.calls, [[a2], [a1]])
        XCTAssertEqual(model.content, .noDuplicates)
    }

    func testEveryKeptReasonHasItsOwnMessage() {
        let reasons: [ExactDuplicateKeepReason] = [
            .relatedFileWithoutTwin, .pendingEditReplacement, .neededByLocalSource, .unreadable,
        ]
        let messages = Set(reasons.map { ExactDuplicateMergeNotice.keptDuplicates(count: 1, reason: $0).message })
        XCTAssertEqual(messages.count, reasons.count)
    }

    func testAFailedMergeKeepsTheGroupAndSaysSo() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.mergeErrors["A"] = URLError(.notConnectedToInternet)
        let (model, log) = makeModel(finder)
        await model.load()
        await model.mergeAll()
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.notice, .failed)
        XCTAssertEqual(log.calls, [[b2]], "the merged group still leaves the library")
    }

    func testAnUnreadablePhotoToKeepLeavesTheGroupForAnotherChoice() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.outcomes["A"] = .skipped(.keptUnreadable)
        let (model, _) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(model.groups.map(\.id), ["A"])
        XCTAssertEqual(model.notice, .keptPhotoUnreadable)
        XCTAssertEqual(finder.scanCalls, 1)
    }

    func testAGroupThatChangedSinceTheScanIsScannedAgain() async {
        let finder = FakeDuplicateFinder(scans: [
            .init(groups: [groupA], coverage: .complete), .init(groups: [], coverage: .complete),
        ])
        finder.outcomes["A"] = .skipped(.noDuplicateLeft)
        let (model, _) = makeModel(finder)
        await model.load()
        await model.merge(groupID: "A")
        XCTAssertEqual(finder.scanCalls, 2)
        XCTAssertEqual(model.content, .noDuplicates)
        XCTAssertNil(model.notice)
    }

    // MARK: - Only copies with equal metadata

    private let described = ExactDuplicateFingerprint(
        captureTime: Date(timeIntervalSince1970: 1_700_000_000), latitude: 10.5, longitude: -20.25,
        device: "Test Camera", pixelWidth: 4000, pixelHeight: 3000, mimeType: "image/heic")
    private let other = ExactDuplicateFingerprint(
        captureTime: Date(timeIntervalSince1970: 1_700_000_001), mimeType: "image/heic")

    func testARankedPageSplitsAGroupByMetadataAndTheCountsFollowInOneChange() async {
        let finder = FakeDuplicateFinder(
            scans: [.init(groups: [groupA, groupB], coverage: .complete, byteSizes: ["A": 100, "B": 10])])
        // The copy that the fallback order checks has no metadata, as an upload without them.
        finder.fingerprints = [a1: ExactDuplicateFingerprint(), a2: described, a3: described]
        finder.rankGate.close()
        let (model, _) = makeModel(finder)
        let load = Task { await model.load() }
        await waitUntil({ finder.rankGate.hasWaiters }, "the load ranks")
        XCTAssertEqual(model.copyCount, 5)
        XCTAssertEqual(model.totalFreedBytes, 210)
        XCTAssertEqual(model.groups.first?.kept, a1)
        let before = model.groupChanges

        finder.rankGate.open()
        await load.value

        XCTAssertEqual(model.groupChanges - before, 1, "the split is part of the one change of the page")
        XCTAssertEqual(model.groups.map(\.id), ["A", "B"], "the part keeps the place and the ID of its group")
        XCTAssertEqual(model.groups.first.map { Set($0.members) }, [a2, a3], "the copy without metadata leaves")
        XCTAssertEqual(model.groups.first?.kept, a2)
        XCTAssertEqual(model.groups.first?.scanGroup.fingerprint, described)
        XCTAssertEqual(model.copyCount, 4)
        XCTAssertEqual(model.duplicateCount, 2)
        XCTAssertEqual(model.totalFreedBytes, 110)
    }

    func testASplitKeepsThePersonsChoiceAndAGroupWithoutTwoEqualCopiesLeaves() async {
        let a4 = PhotoUID(volumeID: "v", nodeID: "a4")
        let four = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a2, a3, a4])
        let finder = FakeDuplicateFinder(scans: [.init(groups: [four, groupB], coverage: .complete)])
        finder.unreadableGroups = ["A", "B"]
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a3, inGroup: "A")
        finder.unreadableGroups = []
        finder.fingerprints = [a1: described, a2: described, a3: other, a4: other, b1: described, b2: other]
        finder.ranked = ["A": [a1, a2, a4, a3]]

        await model.load()

        XCTAssertEqual(model.groups.map(\.scanGroup.contentHash), ["A", "A"], "group B left: its copies differ")
        let chosen = model.groups.first
        XCTAssertEqual(chosen?.id, "A", "the part with the chosen copy keeps the ID and the place of the group")
        XCTAssertEqual(chosen.map { Set($0.members) }, [a3, a4])
        XCTAssertEqual(chosen?.kept, a3, "the checkmark of the person stays")
        XCTAssertEqual(chosen?.isKeptChosen, true)
        let rest = model.groups.last
        XCTAssertNotEqual(rest?.id, "A")
        XCTAssertEqual(rest?.members, [a1, a2])
        XCTAssertEqual(rest?.kept, a1)
        XCTAssertEqual(rest?.isKeptChosen, false)
        XCTAssertEqual(rest?.isRanked, true)
    }

    func testMergeAllNeverMergesAGroupWhoseMetadataCouldNotBeRead() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()

        await model.mergeAll()

        XCTAssertEqual(finder.merges.map(\.group), ["B"])
        XCTAssertEqual(model.groups.map(\.id), ["A"], "the group stays for a later try")
        XCTAssertEqual(model.notice, .failed)
    }

    func testMergingOneGroupThatSplitsWhileItsMetadataArriveMergesNothing() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.unreadableGroups = []
        finder.fingerprints = [a1: ExactDuplicateFingerprint(), a2: described, a3: described]

        await model.merge(groupID: "A")

        XCTAssertEqual(finder.merges, [], "the person sees the new group before a merge")
        XCTAssertEqual(model.groups.map { Set($0.members) }, [[a2, a3]])
        XCTAssertNil(model.notice)
    }

    func testAMergeThatFindsOtherMetadataReportsThemAndReadsTheGroupAgain() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fingerprints = [a1: described, a2: described, a3: described]
        let (model, _) = makeModel(finder)
        await model.load()
        // The metadata of a3 changed after the ranking, so the merge leaves it.
        finder.fingerprints[a3] = other
        finder.outcomes = ["A": .merged(kept: a1, trashed: [], keptDuplicates: [a3: .differentDetails])]
        let scans = finder.scanCalls

        await model.merge(groupID: "A")

        XCTAssertEqual(model.notice, .keptDuplicates(count: 1, reason: .differentDetails))
        XCTAssertEqual(finder.scanCalls, scans + 1, "the screen reads the groups again")
        XCTAssertEqual(model.groups.map { Set($0.members) }, [[a1, a2]], "and the new metadata, not the earlier")
    }

    func testAMergeWhoseKeptPhotoChangedItsMetadataReadsTheGroupAgain() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA], coverage: .complete)])
        finder.fingerprints = [a1: described, a2: described, a3: described]
        let (model, _) = makeModel(finder)
        await model.load()
        finder.fingerprints[a1] = other
        finder.outcomes = ["A": .skipped(.keptDetailsChanged)]

        await model.merge(groupID: "A")

        XCTAssertEqual(model.groups.map { Set($0.members) }, [[a2, a3]])
        XCTAssertNil(model.notice)
    }

    func testAScreenThatOpensAgainSplitsAtOnceAndReadsNothingAgain() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.fingerprints = [a1: ExactDuplicateFingerprint(), a2: described, a3: described]
        let (model, _) = makeModel(finder)
        await model.load()
        model.keep(a3, inGroup: "A")
        let ranks = finder.rankCalls
        finder.scanGate.close()
        let reload = Task { await model.load() }
        await waitUntil({ finder.scanGate.hasWaiters }, "the screen scans again")
        let before = model.groupChanges

        finder.scanGate.open()
        await reload.value

        XCTAssertEqual(model.groupChanges - before, 1, "the scan shows the parts at once")
        XCTAssertEqual(finder.rankCalls, ranks, "the metadata that the screen read already split the group")
        XCTAssertEqual(model.groups.map { Set($0.members) }, [[a2, a3], [b1, b2]])
        XCTAssertEqual(model.groups.first?.kept, a3)
    }

    func testTheViewerActsOnTheGroupOfThePhotoOnScreenAfterTheGroupSplit() async throws {
        let a4 = PhotoUID(volumeID: "v", nodeID: "a4")
        let four = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a2, a3, a4])
        let finder = FakeDuplicateFinder(scans: [.init(groups: [four, groupB], coverage: .complete)])
        finder.unreadableGroups = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()
        // The viewer opened group A on a3; the metadata arrive while it is open.
        XCTAssertEqual(model.group(containing: a3)?.id, "A")
        finder.unreadableGroups = []
        finder.fingerprints = [a1: described, a2: described, a3: other, a4: other]
        await model.load()
        let part = try XCTUnwrap(model.group(containing: a3))
        XCTAssertNotEqual(part.id, "A", "group A kept its ID for the part with its checked copy a1")
        XCTAssertEqual(Set(part.members), [a3, a4])

        XCTAssertEqual(model.keepSymbol(for: a3), "checkmark.circle.fill", "a3 is the kept copy of its part")
        XCTAssertTrue(model.canKeep(a4))
        XCTAssertTrue(model.canMerge(containing: a3))
        await model.merge(containing: a3)

        XCTAssertEqual(finder.merges, [.init(group: part.id, kept: a3)], "the merge takes the group of the photo shown")
    }

    func testAPageWithoutTheMetadataOfAGroupLeavesItWholeAndUnranked() async {
        let finder = FakeDuplicateFinder(scans: [.init(groups: [groupA, groupB], coverage: .complete)])
        finder.withoutFingerprints = ["A"]
        let (model, _) = makeModel(finder)
        await model.load()

        XCTAssertEqual(model.group(withID: "A")?.members.count, 3, "no copy leaves without its metadata")
        XCTAssertEqual(model.group(withID: "A")?.isRanked, false)
        XCTAssertEqual(model.group(withID: "B")?.isRanked, true)
        await model.mergeAll()
        XCTAssertEqual(finder.merges.map(\.group), ["B"], "no merge takes a group whose metadata are unknown")
    }

    func testAReloadAfterTheFirstPartMergedKeepsTheChoiceAndTheRankingOfTheOtherPart() async throws {
        let a4 = PhotoUID(volumeID: "v", nodeID: "a4")
        let four = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a2, a3, a4])
        let afterMerge = ExactDuplicateGroup(contentHash: "A", hashKeyEpoch: "e", members: [a1, a3, a4])
        let finder = FakeDuplicateFinder(
            scans: [.init(groups: [four], coverage: .complete), .init(groups: [afterMerge], coverage: .complete)])
        finder.fingerprints = [a1: described, a2: described, a3: other, a4: other]
        let (model, _) = makeModel(finder)
        await model.load()
        let part = try XCTUnwrap(model.group(containing: a3))
        model.keep(a4, inGroup: part.id)
        await model.merge(groupID: "A")
        XCTAssertNil(model.group(withID: "A"), "the first part merged")
        let ranks = finder.rankCalls

        await model.load()

        XCTAssertEqual(model.groups.count, 1)
        let kept = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(kept.id, part.id, "the part keeps its ID")
        XCTAssertEqual(kept.kept, a4, "the checkmark of the person stays")
        XCTAssertTrue(kept.isKeptChosen)
        XCTAssertTrue(kept.isRanked)
        XCTAssertEqual(finder.rankCalls, ranks, "the screen reads nothing again")
    }
}

@MainActor
private final class TrashLog {
    var calls: [[PhotoUID]] = []
}

/// Answers from memory. Without a configured outcome, a merge trashes every member except the kept one.
private final class FakeDuplicateFinder: ExactDuplicateMerging, @unchecked Sendable {
    struct Merge: Equatable {
        let group: String
        let kept: PhotoUID
    }

    private let lock = NSLock()
    private var scans: [ExactDuplicateScan]
    private var _scanCalls = 0
    private var _rankCalls = 0
    private var _merges: [Merge] = []
    private var _choices: [String: Bool] = [:]
    private var _batches: [[String]] = []
    private var _buildCalls = 0
    private var _rankedGroups: [[String]] = []
    private var _activeRankings = 0
    private var _maximumConcurrentRankings = 0
    private var _cancelledRankings = 0
    /// A cancelled ranking reports no page, as the finder does.
    var reportsNothingWhenCancelled = false
    var scanProgress: [ExactDuplicateScanProgress] = []
    var fallback: [String: [PhotoUID]] = [:]
    /// Groups whose facts cannot be read.
    var unreadableGroups: Set<String> = []
    /// A ranking that reads one of these groups waits at `holdGate` before it reports its page.
    var heldGroups: Set<String> = []
    let holdGate = BuildGate()
    /// Shared members that the ranking reports.
    var shared: [String: Set<PhotoUID>] = [:]
    /// Sizes that the node reads of the ranking report.
    var rankSizes: [String: Int64] = [:]
    /// The facts of each member that the ranking reports.
    var facts: [String: [PhotoUID: ExactDuplicateKeepFacts]] = [:]
    /// The size of each member that the ranking reports.
    var memberSizes: [String: [PhotoUID: Int64]] = [:]
    /// The metadata of members that the ranking reports. Every other member has a fingerprint without values.
    var fingerprints: [PhotoUID: ExactDuplicateFingerprint] = [:]
    /// Groups whose page carries an order but no metadata.
    var withoutFingerprints: Set<String> = []
    /// The capture dates that the device knows.
    var dates: [PhotoUID: Date] = [:]
    /// Holds the scan while it is closed.
    let scanGate = BuildGate()
    /// Holds the ranking while it is closed.
    let rankGate = BuildGate()
    var buildProgress: [UploadRemoteIndexPreparationProgress] = []
    var buildChanged = false
    var buildError: Error?
    /// Holds the build while it is closed.
    let buildGate = BuildGate()
    /// Holds the merge while it is closed.
    let mergeGate = BuildGate()
    var ranked: [String: [PhotoUID]] = [:]
    var outcomes: [String: ExactDuplicateMergeOutcome] = [:]
    var mergeErrors: [String: Error] = [:]
    var scanError: Error?
    var rankError: Error?

    init(scans: [ExactDuplicateScan]) { self.scans = scans }

    var scanCalls: Int { lock.withLock { _scanCalls } }
    var rankCalls: Int { lock.withLock { _rankCalls } }
    var merges: [Merge] { lock.withLock { _merges } }
    /// Whether the person chose the photo to keep, by group, as the last merge of the group told.
    var choices: [String: Bool] { lock.withLock { _choices } }
    var batches: [[String]] { lock.withLock { _batches } }
    var buildCalls: Int { lock.withLock { _buildCalls } }
    var rankedGroups: [[String]] { lock.withLock { _rankedGroups } }
    var maximumConcurrentRankings: Int { lock.withLock { _maximumConcurrentRankings } }
    var activeRankings: Int { lock.withLock { _activeRankings } }
    /// The rankings that were cancelled while they waited at `rankGate`.
    var cancelledRankings: Int { lock.withLock { _cancelledRankings } }

    func duplicateGroups(
        progress: @escaping @Sendable (ExactDuplicateScanProgress) async -> Void
    ) async throws -> ExactDuplicateScan {
        let steps = lock.withLock { scanProgress }
        for step in steps { await progress(step) }
        await scanGate.pass()
        return try lock.withLock {
            _scanCalls += 1
            if let scanError { throw scanError }
            return scans.count > 1 ? scans.removeFirst() : scans[0]
        }
    }

    func captureDates(of members: [PhotoUID]) async -> [PhotoUID: Date] {
        lock.withLock { dates.filter { members.contains($0.key) } }
    }

    func fallbackMembers(of groups: [ExactDuplicateGroup]) async -> [String: [PhotoUID]] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: groups.map { ($0.id, fallback[$0.id] ?? $0.members) })
        }
    }

    func prepareIndex(
        progress: @escaping @Sendable (UploadRemoteIndexPreparationProgress) async -> Void
    ) async throws -> Bool {
        let (steps, error, changed) = lock.withLock {
            _buildCalls += 1
            return (buildProgress, buildError, buildChanged)
        }
        for step in steps { await progress(step) }
        await buildGate.pass()
        if let error { throw error }
        return changed
    }

    func rankMembers(
        of groups: [ExactDuplicateGroup], ranked report: @escaping @Sendable (ExactDuplicateRankingPage) async -> Void
    ) async {
        lock.withLock {
            _rankCalls += 1
            _rankedGroups.append(groups.map(\.id))
            _activeRankings += 1
            _maximumConcurrentRankings = max(_maximumConcurrentRankings, _activeRankings)
        }
        defer { lock.withLock { _activeRankings -= 1 } }
        let held = lock.withLock { !heldGroups.isDisjoint(with: groups.map(\.id)) }
        await rankGate.pass()
        if Task.isCancelled {
            let reportsNothing = lock.withLock {
                _cancelledRankings += 1
                return reportsNothingWhenCancelled
            }
            // The finder ends a cancelled ranking before its next page.
            if reportsNothing { return }
        }
        if held { await holdGate.pass() }
        let page = lock.withLock { () -> ExactDuplicateRankingPage in
            guard rankError == nil else { return ExactDuplicateRankingPage(members: [:], groupCount: groups.count) }
            var members: [String: [PhotoUID]] = [:]
            for group in groups where !unreadableGroups.contains(group.id) {
                members[group.id] = ranked[group.id] ?? group.members
            }
            let sizes = rankSizes.filter { size in groups.contains { $0.id == size.key } }
            let sharedMembers = shared.filter { entry in groups.contains { $0.id == entry.key } }
            let pageFacts = facts.filter { entry in members[entry.key] != nil }
            let pageSizes = memberSizes.filter { entry in members[entry.key] != nil }
            let pageFingerprints = Dictionary(
                uniqueKeysWithValues: groups.filter { members[$0.id] != nil && !withoutFingerprints.contains($0.id) }
                    .map {
                        group in
                        (
                            group.id,
                            Dictionary(
                                uniqueKeysWithValues: group.members.map {
                                    ($0, fingerprints[$0] ?? ExactDuplicateFingerprint())
                                })
                        )
                    })
            return ExactDuplicateRankingPage(
                members: members, groupCount: groups.count, byteSizes: sizes, shared: sharedMembers,
                facts: pageFacts, memberByteSizes: pageSizes, fingerprints: pageFingerprints)
        }
        await report(page)
    }

    func merge(_ group: ExactDuplicateGroup, keeping kept: PhotoUID) async throws -> ExactDuplicateMergeOutcome {
        try lock.withLock {
            _merges.append(Merge(group: group.id, kept: kept))
            if let error = mergeErrors[group.id] { throw error }
            return outcomes[group.id]
                ?? .merged(kept: kept, trashed: group.members.filter { $0 != kept }, keptDuplicates: [:])
        }
    }

    func merge(_ requests: [ExactDuplicateMergeRequest]) async -> [Result<ExactDuplicateMergeOutcome, any Error>] {
        lock.withLock {
            _batches.append(requests.map(\.group.id))
            for request in requests { _choices[request.group.id] = request.isKeptChosen }
        }
        await mergeGate.pass()
        var results: [Result<ExactDuplicateMergeOutcome, any Error>] = []
        for request in requests {
            do {
                results.append(.success(try await merge(request.group, keeping: request.kept)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }
}

/// Lets callers pass while open and holds them while closed.
private final class BuildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool { lock.withLock { !waiters.isEmpty } }

    func close() { lock.withLock { isOpen = false } }

    func open() {
        let held = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        held.forEach { $0.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if passes { continuation.resume() }
        }
    }
}
