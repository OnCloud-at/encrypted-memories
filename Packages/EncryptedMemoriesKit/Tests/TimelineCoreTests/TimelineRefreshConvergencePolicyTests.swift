import Foundation
import Testing

@testable import TimelineCore

@Suite struct TimelineRefreshConvergencePolicyTests {
    private let policy = TimelineRefreshConvergencePolicy()

    @Test func pendingVisibilityUsesTheExistingBoundedUploadSchedule() {
        #expect(policy.decision(after: .pendingInventoryVisibility, attempt: 0) == .retry(after: .seconds(1)))
        #expect(policy.decision(after: .pendingInventoryVisibility, attempt: 1) == .retry(after: .seconds(3)))
        #expect(policy.decision(after: .pendingInventoryVisibility, attempt: 2) == .retry(after: .seconds(8)))
        #expect(policy.decision(after: .pendingInventoryVisibility, attempt: 3) == .retry(after: .seconds(18)))
        #expect(policy.decision(after: .pendingInventoryVisibility, attempt: 4) == .notYetVisible)
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
