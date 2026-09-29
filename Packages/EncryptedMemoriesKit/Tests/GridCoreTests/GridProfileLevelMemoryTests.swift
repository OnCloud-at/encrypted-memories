import Testing

@testable import GridCore

/// iPhone Duo fold and unfold round trip, measured on the simulator: outer display (compact profile, 2 columns),
/// inner display in landscape (regular profile), inner display upright (compact again). The size match alone
/// returned 3 columns to the outer display.
@Suite struct GridProfileLevelMemoryTests {
    @Test func aRoundTripWithoutZoomReturnsToTheStartingLevel() {
        var memory = GridProfileLevelMemory()
        let regular = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        #expect(regular == 1)
        let compact = memory.level(leaving: "regular", at: 1, entering: "compact") { 1 }
        #expect(compact == 0)
        // A second round trip stays stable.
        #expect(memory.level(leaving: "compact", at: 0, entering: "regular") { 2 } == 1)
        #expect(memory.level(leaving: "regular", at: 1, entering: "compact") { 2 } == 0)
    }

    @Test func aZoomAfterArrivalLetsTheSizeMatchDecide() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        // The person pinched to level 2 in the regular profile.
        #expect(memory.level(leaving: "regular", at: 2, entering: "compact") { 3 } == 3)
    }

    @Test func theFirstVisitUsesTheSizeMatch() {
        var memory = GridProfileLevelMemory()
        var matched = false
        let level = memory.level(leaving: "compact", at: 1, entering: "regular") {
            matched = true
            return 2
        }
        #expect(matched)
        #expect(level == 2)
    }

    @Test func resetForgetsTheLevels() {
        var memory = GridProfileLevelMemory()
        _ = memory.level(leaving: "compact", at: 0, entering: "regular") { 1 }
        memory.reset()
        #expect(memory.level(leaving: "regular", at: 1, entering: "compact") { 2 } == 2)
    }
}
