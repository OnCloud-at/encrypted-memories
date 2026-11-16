import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct TimelineRefreshFailurePolicyTests {
    private struct ScopeLoss: LibraryChangeTerminalError {}
    private struct StillConverging: TimelineInventoryConvergenceError {}
    private struct Unclassified: Error {}
    /// Both marker protocols at once: lost scope access wins, as in both hosts before.
    private struct ScopeLossWhileConverging: LibraryChangeTerminalError, TimelineInventoryConvergenceError {}

    @Test(arguments: [FailureSituation.background, .awaitedByPerson])
    func errorsMapToTheSameReasonInEverySituation(situation: FailureSituation) {
        let expected: [(any Error, TimelineRefreshFailureReason)] = [
            (CancellationError(), .cancelled),
            (ScopeLoss(), .scopeAccessLost),
            (StillConverging(), .pendingInventoryVisibility),
            (ScopeLossWhileConverging(), .scopeAccessLost),
            (Unclassified(), .other),
            (URLError(.notConnectedToInternet), .other),
        ]
        for (error, reason) in expected {
            #expect(TimelineRefreshFailurePolicy.verdict(for: error, situation: situation).reason == reason)
        }
    }

    @Test func onlyLostScopeAccessEndsTheMonitor() {
        let errors: [any Error] = [
            CancellationError(), StillConverging(), Unclassified(), URLError(.timedOut),
        ]
        for error in errors {
            #expect(TimelineRefreshFailurePolicy.verdict(for: error, situation: .background).monitorOutcome == .retry)
        }
        let scopeLoss = TimelineRefreshFailurePolicy.verdict(for: ScopeLoss(), situation: .background)
        #expect(scopeLoss.monitorOutcome == .terminal)
    }

    @Test func aRefreshResultGivesTheMonitorOneOutcomeForSuccessAndEveryFailure() {
        func result(_ reason: TimelineRefreshFailureReason?, covers: Bool = true) -> TimelineRefreshResult {
            TimelineRefreshResult(
                uploadedUID: nil, foundItem: nil, timelineCountBefore: 0, timelineCountAfter: 0,
                filterDescription: "", elapsedMs: 0, errorMessage: reason == nil ? nil : "failed",
                failureReason: reason, publishedLibraryChangeToken: "token", coversWholeLibrary: covers)
        }
        #expect(result(nil).monitorOutcome == .refreshed(token: "token"))
        #expect(result(nil, covers: false).monitorOutcome == .refreshedWithoutRevision)
        #expect(result(.unchanged).monitorOutcome == .refreshed(token: "token"), "an unchanged load is a success")
        #expect(result(.scopeAccessLost).monitorOutcome == .terminal)
        for reason: TimelineRefreshFailureReason in [.pendingInventoryVisibility, .superseded, .cancelled, .other] {
            #expect(result(reason).monitorOutcome == .retry)
        }
    }

    @Test func everyReasonHasOneExplicitMonitorOutcome() {
        let expected: [(TimelineRefreshFailureReason, LibraryChangeRefreshOutcome)] = [
            (.scopeAccessLost, .terminal),
            (.pendingInventoryVisibility, .retry),
            (.superseded, .retry),
            (.cancelled, .retry),
            (.other, .retry),
            (.unchanged, .refreshedWithoutRevision),
        ]
        for (reason, outcome) in expected {
            #expect(TimelineRefreshFailurePolicy.monitorOutcome(for: reason) == outcome)
        }
    }

    @Test func aRefreshNobodyWaitsForStaysSilentForEveryError() {
        let errors: [any Error] = [
            CancellationError(), ScopeLoss(), StillConverging(), Unclassified(), URLError(.notConnectedToInternet),
        ]
        for error in errors {
            #expect(TimelineRefreshFailurePolicy.verdict(for: error, situation: .background).presentation == .silent)
        }
    }

    @Test func aRefreshThatAPersonStartedShowsItsFailure() {
        let errors: [any Error] = [Unclassified(), URLError(.notConnectedToInternet), StillConverging()]
        for error in errors {
            let verdict = TimelineRefreshFailurePolicy.verdict(for: error, situation: .awaitedByPerson)
            #expect(verdict.presentation == .alert)
        }
    }
}
