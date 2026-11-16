import Testing

@testable import EncryptedMemoriesMobile

/// How the viewer keeps Info as the user left it when the width class changes on iOS 26. The event orders follow the
/// iOS 26.5 simulator: the system changes Info in the update of the width change, or about half a second after it.
@Suite struct MobileViewerInfoReshowTests {
    @Test func aRotationThatClosesInfoShowsItAgain() throws {
        // A rotation to landscape: the width change arrives first, the system's close follows in the same update.
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        _ = rule.widthClassDidChange()
        let lastGeneration = rule.showInfoDidChange(to: false)
        let last = try #require(lastGeneration)
        let answer1 = rule.correction(checking: last, showInfo: false)
        #expect(answer1 == true)
    }

    @Test func aCheckBeforeTheSystemsCloseLeavesTheDecisionToTheLatestEvent() throws {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        let firstGeneration = rule.widthClassDidChange()
        let first = try #require(firstGeneration)
        let lastGeneration = rule.showInfoDidChange(to: false)
        let last = try #require(lastGeneration)
        let answer2 = rule.correction(checking: first, showInfo: false)
        #expect(answer2 == nil, "Only the latest event decides")
        let answer3 = rule.correction(checking: last, showInfo: false)
        #expect(answer3 == true)
    }

    @Test func aLateSystemCloseAfterAQuietCheckIsStillCorrected() throws {
        // A rotation back to portrait: the check of the width change finds Info unchanged, and the system closes it
        // about half a second later.
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        let changeGeneration = rule.widthClassDidChange()
        let change = try #require(changeGeneration)
        let answer4 = rule.correction(checking: change, showInfo: true)
        #expect(answer4 == nil)
        let closeGeneration = rule.showInfoDidChange(to: false)
        let close = try #require(closeGeneration, "A quiet check must keep the width change pending")
        #expect(rule.intended == true)
        let answer5 = rule.correction(checking: close, showInfo: false)
        #expect(answer5 == true)
    }

    @Test func aFastRotationBackStillCorrectsTheLateClose() throws {
        // Landscape and straight back to portrait before any check: the correction must not end the width change
        // before the system's late close of the second rotation.
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        _ = rule.widthClassDidChange()
        _ = rule.showInfoDidChange(to: false)
        let backGeneration = rule.widthClassDidChange()
        let back = try #require(backGeneration)
        let answer6 = rule.correction(checking: back, showInfo: false)
        #expect(answer6 == true)
        let reshowGeneration = rule.showInfoDidChange(to: true)
        let reshow = try #require(reshowGeneration, "The viewer's own correction arrives while the change is pending")
        let answer7 = rule.correction(checking: reshow, showInfo: true)
        #expect(answer7 == nil)
        let lateCloseGeneration = rule.showInfoDidChange(to: false)
        let lateClose = try #require(lateCloseGeneration)
        let answer8 = rule.correction(checking: lateClose, showInfo: false)
        #expect(answer8 == true)
        #expect(rule.intended == true)
    }

    @Test func infoThatTheUserClosedStaysClosedWhenTheSystemOpensItOnARotation() throws {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        _ = rule.showInfoDidChange(to: false)
        let changeGeneration = rule.widthClassDidChange()
        let change = try #require(changeGeneration)
        let lastGeneration = rule.showInfoDidChange(to: true)
        let last = try #require(lastGeneration)
        let answer9 = rule.correction(checking: change, showInfo: true)
        #expect(answer9 == nil)
        let answer10 = rule.correction(checking: last, showInfo: true)
        #expect(answer10 == false)
    }

    @Test func aSettledWidthChangeLeavesTheNextChangeToTheUser() throws {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        let changeGeneration = rule.widthClassDidChange()
        let change = try #require(changeGeneration)
        let latest = rule.widthChanges
        let settle = rule.widthChangeDidSettle(latest, showInfo: true)
        #expect(settle == nil)
        #expect(!rule.widthChangePending)
        let answer11 = rule.correction(checking: change, showInfo: true)
        #expect(answer11 == nil)
        let close = rule.showInfoDidChange(to: false)
        #expect(close == nil, "The user's own change needs no check")
        #expect(rule.intended == false)
    }

    @Test func theSettleTimePutsAnOpenSystemChangeBackAndEndsTheWidthChange() {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        _ = rule.widthClassDidChange()
        _ = rule.showInfoDidChange(to: false)
        let latest = rule.widthChanges
        let settle = rule.widthChangeDidSettle(latest, showInfo: false)
        #expect(settle == true)
        #expect(!rule.widthChangePending)
        let reopen = rule.showInfoDidChange(to: true)
        #expect(reopen == nil)
        #expect(rule.intended == true)
    }

    @Test func onlyTheSettleTimeOfTheLatestWidthChangeEndsIt() {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        _ = rule.widthClassDidChange()
        let earlier = rule.widthChanges
        _ = rule.widthClassDidChange()
        let settle = rule.widthChangeDidSettle(earlier, showInfo: true)
        #expect(settle == nil)
        #expect(rule.widthChangePending)
    }

    @Test func aChangeWithoutAWidthChangeIsTheUsersChoice() {
        var rule = MobileViewerInfoReshow(isPhone: true, showInfo: true)
        let close = rule.showInfoDidChange(to: false)
        #expect(close == nil)
        #expect(rule.intended == false)
    }

    @Test func anIPadKeepsTheSystemBehavior() {
        var rule = MobileViewerInfoReshow(isPhone: false, showInfo: true)
        let change = rule.widthClassDidChange()
        #expect(change == nil)
        let close = rule.showInfoDidChange(to: false)
        #expect(close == nil)
        #expect(!rule.widthChangePending)
    }
}
