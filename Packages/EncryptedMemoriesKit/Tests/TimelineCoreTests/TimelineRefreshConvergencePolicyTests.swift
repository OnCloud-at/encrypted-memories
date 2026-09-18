import Foundation
import Testing

@testable import TimelineCore

@Suite struct TimelineRefreshConvergencePolicyTests {
    private let policy = TimelineRefreshConvergencePolicy()

    @Test func pendingVisibilityFollowsTheBoundedUploadSchedule() {
        let delays = TimelineRefreshRetrySchedule.uploadDefault.delays
        for attempt in 0..<(delays.count - 1) {
            #expect(
                policy.decision(after: .pendingInventoryVisibility, attempt: attempt)
                    == .retry(after: delays[attempt + 1]))
        }
        #expect(
            policy.decision(after: .pendingInventoryVisibility, attempt: delays.count - 1) == .notYetVisible,
            "the last delay ends the convergence window")
    }

    @Test func theFirstRetryOfALocallyCreatedPhotoStaysSubSecond() {
        // A kept series favorite or a manual upload is usually listed within a second. A one-second first
        // retry made the grid show it only after four seconds.
        #expect(
            policy.decision(after: .pendingInventoryVisibility, attempt: 0)
                == .retry(after: TimelineRefreshRetrySchedule.uploadDefault.delays[1]))
        #expect(TimelineRefreshRetrySchedule.uploadDefault.delays[1] <= .milliseconds(400))
    }

    @Test func successAndTerminalFailureNeverRetry() {
        #expect(policy.decision(after: nil, attempt: 0) == .succeeded)
        #expect(policy.decision(after: .other, attempt: 0) == .failed)
        #expect(policy.decision(after: .scopeAccessLost, attempt: 0) == .failed)
    }

    @Test func cancellationAndSupersededRoutesStopQuietly() {
        #expect(policy.decision(after: .cancelled, attempt: 0) == .cancelled)
        #expect(policy.decision(after: .superseded, attempt: 0) == .cancelled)
    }
}
