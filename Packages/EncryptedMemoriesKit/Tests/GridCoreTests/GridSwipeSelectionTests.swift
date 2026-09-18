import CoreGraphics
import GridCore
import Testing

@Suite struct GridSwipeSelectionTests {
    private let ids = Array(0..<20)

    @Test func forwardRangeFillsWholeRowsInReadingOrder() throws {
        var range = try #require(GridSwipeSelection(anchorIndex: 2, orderedIDs: ids, selected: []))
        #expect(range.selects)
        #expect(range.selection == [2])
        let extended = range.extend(to: 9)
        #expect(extended)
        #expect(range.selection == Set(2...9))
        let repeated = range.extend(to: 9)
        #expect(!repeated)
    }

    @Test func backwardRangeSelectsFromFingerToAnchor() throws {
        var range = try #require(GridSwipeSelection(anchorIndex: 12, orderedIDs: ids, selected: [0]))
        range.extend(to: 5)
        #expect(range.selection == Set([0] + Array(5...12)))
        range.extend(to: 15)
        #expect(range.selection == Set([0] + Array(12...15)))
    }

    @Test func selectedAnchorDeselectsTheRange() throws {
        var range = try #require(GridSwipeSelection(anchorIndex: 4, orderedIDs: ids, selected: Set(0...10)))
        #expect(!range.selects)
        #expect(range.selection == Set(0...10).subtracting([4]))
        range.extend(to: 7)
        #expect(range.selection == Set([0, 1, 2, 3, 8, 9, 10]))
    }

    @Test func shrinkingRestoresEachPhotosPreviousState() throws {
        let before: Set = [3, 5, 14]
        var range = try #require(GridSwipeSelection(anchorIndex: 1, orderedIDs: ids, selected: before))
        range.extend(to: 16)
        #expect(range.selection == Set(1...16))
        range.extend(to: 4)
        #expect(range.selection == Set([1, 2, 3, 4, 5, 14]))
        range.extend(to: 1)
        #expect(range.selection == before.union([1]))

        var removal = try #require(GridSwipeSelection(anchorIndex: 5, orderedIDs: ids, selected: before))
        removal.extend(to: 14)
        #expect(removal.selection == [3])
        removal.extend(to: 5)
        #expect(removal.selection == [3, 14])
    }

    @Test func rangeEndClampsIntoTheItemOrder() throws {
        #expect(GridSwipeSelection(anchorIndex: 20, orderedIDs: ids, selected: []) == nil)
        var range = try #require(GridSwipeSelection(anchorIndex: 18, orderedIDs: ids, selected: []))
        range.extend(to: 99)
        #expect(range.currentIndex == 19)
        range.extend(to: -4)
        #expect(range.currentIndex == 0)
        #expect(range.selection == Set(0...18))
    }

    @Test func fingerPositionResolvesThroughGridGeometry() throws {
        let engine = SquareTileGridEngine(
            sectionCounts: [20],
            profile: GridLevelProfile(
                id: "swipe-test",
                levels: [GridLevelMetrics(levelID: 0, nominalColumns: 4, gap: 10, monthLabels: false)],
                defaultLevel: 0),
            fillOrder: .topLeading)
        let width: CGFloat = 400
        func index(_ point: CGPoint) -> Int? {
            GridSwipeSelection<Int>.index(
                at: point, engine: engine, level: 0, width: width, columnPhase: nil, itemCount: 20)
        }
        let first = try #require(engine.slotRect(flatIndex: 0, level: 0, width: width))
        let sixth = try #require(engine.slotRect(flatIndex: 5, level: 0, width: width))
        #expect(index(CGPoint(x: sixth.midX, y: sixth.midY)) == 5)
        #expect(index(CGPoint(x: -30, y: first.midY)) == 0, "a finger beyond the leading edge keeps its row")
        #expect(index(CGPoint(x: first.midX, y: -1)) == 0)
        let height = engine.contentSize(level: 0, width: width).height
        #expect(index(CGPoint(x: first.midX, y: height + 5)) == 19)
        #expect(index(CGPoint(x: first.midX, y: first.maxY + 5)) == nil, "a row gap keeps the previous end")
    }

    @Test func autoScrollIsIdleInTheMiddleAndGrowsTowardEachEdge() {
        func speed(_ y: CGFloat) -> CGFloat {
            GridSwipeAutoScrollPolicy.velocity(
                touchY: y, visibleMinY: 100, visibleMaxY: 900, edgeBand: 80, maxSpeed: 1000)
        }
        #expect(speed(500) == 0)
        #expect(speed(180) == 0)
        #expect(speed(820) == 0)

        #expect(speed(160) < 0)
        #expect(speed(120) < speed(160))
        #expect(speed(100) == -1000)
        #expect(speed(20) == -1000, "a finger over the top bar scrolls at full speed")

        #expect(speed(840) > 0)
        #expect(speed(880) > speed(840))
        #expect(speed(900) == 1000)
        #expect(speed(990) == 1000)
        #expect(speed(860) == 250, "halfway into the band scrolls at a quarter of the maximum")
    }

    @Test func autoScrollBandLeavesAMiddleZoneOnShortViewports() {
        func speed(_ y: CGFloat) -> CGFloat {
            GridSwipeAutoScrollPolicy.velocity(touchY: y, visibleMinY: 0, visibleMaxY: 90, edgeBand: 80, maxSpeed: 1000)
        }
        #expect(speed(45) == 0)
        #expect(speed(29) < 0)
        #expect(speed(61) > 0)
        #expect(GridSwipeAutoScrollPolicy.velocity(touchY: 10, visibleMinY: 50, visibleMaxY: 50) == 0)
    }
}
