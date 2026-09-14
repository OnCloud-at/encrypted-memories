import Testing

@testable import PhotosCore

@Suite struct LibrarySceneActivityLedgerTests {
    @Test func emptyLedgerPermitsBackgroundExecution() {
        let ledger = LibrarySceneActivityLedger()
        #expect(ledger.isEmpty)
        #expect(ledger.opportunity == .backgroundPermitted)
    }

    @Test func singleSceneMapsEachPhaseDirectly() {
        var ledger = LibrarySceneActivityLedger()
        #expect(ledger.update(sceneID: "a", phase: .active) == .foregroundActive)
        #expect(ledger.update(sceneID: "a", phase: .inactive) == .foregroundInactive)
        #expect(ledger.update(sceneID: "a", phase: .background) == .backgroundPermitted)
        #expect(ledger.sceneCount == 1)
    }

    @Test func anyActiveSceneKeepsTheAccountForegroundActive() {
        var ledger = LibrarySceneActivityLedger()
        ledger.update(sceneID: "a", phase: .active)
        ledger.update(sceneID: "b", phase: .background)
        #expect(ledger.opportunity == .foregroundActive)

        // A second window going inactive must not demote the account while the first stays active.
        #expect(ledger.update(sceneID: "b", phase: .inactive) == .foregroundActive)
    }

    @Test func inactiveOutranksBackgroundAcrossScenes() {
        var ledger = LibrarySceneActivityLedger()
        ledger.update(sceneID: "a", phase: .background)
        ledger.update(sceneID: "b", phase: .inactive)
        #expect(ledger.opportunity == .foregroundInactive)
    }

    @Test func backgroundIsPermittedOnlyWhenEveryConnectedSceneIsInBackground() {
        var ledger = LibrarySceneActivityLedger()
        ledger.update(sceneID: "a", phase: .active)
        ledger.update(sceneID: "b", phase: .active)
        #expect(ledger.update(sceneID: "a", phase: .background) == .foregroundActive)
        #expect(ledger.update(sceneID: "b", phase: .background) == .backgroundPermitted)
    }

    @Test func closingAWindowRemovesOnlyThatSceneFromTheAggregate() {
        var ledger = LibrarySceneActivityLedger()
        ledger.update(sceneID: "a", phase: .background)
        ledger.update(sceneID: "b", phase: .active)
        #expect(ledger.remove(sceneID: "b") == .backgroundPermitted)
        #expect(ledger.phase(of: "b") == nil)
        #expect(ledger.phase(of: "a") == .background)
        #expect(ledger.remove(sceneID: "unknown") == .backgroundPermitted)
        #expect(ledger.remove(sceneID: "a") == .backgroundPermitted)
        #expect(ledger.isEmpty)
    }
}
