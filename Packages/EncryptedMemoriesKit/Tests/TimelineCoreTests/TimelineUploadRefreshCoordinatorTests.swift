import Foundation
import Testing

@testable import TimelineCore

@Suite struct TimelineUploadRefreshCoordinatorTests {
    @Test func retriesOnlyPendingVisibilityWithSharedSchedule() async {
        let recorder = RefreshAttemptRecorder(failures: [.pendingInventoryVisibility, .pendingInventoryVisibility, nil])
        let coordinator = TimelineUploadRefreshCoordinator(
            policy: .init(schedule: .init(delays: [.zero, .zero, .zero])))
        await coordinator.request(
            refresh: { attempt in await recorder.failure(at: attempt) },
            observer: { attempt in await recorder.record(attempt) }
        )
        await recorder.waitForAttempts(3)
        #expect(await recorder.attempts == [0, 1, 2])
        #expect(await recorder.decisions == [.retry(after: .zero), .retry(after: .zero), .succeeded])
        await coordinator.cancel()
    }

    @Test func repeatedSignalsJoinOneDrainAndCauseOneFollowUp() async {
        let recorder = RefreshAttemptRecorder(failures: [nil, nil])
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))
        await coordinator.request(refresh: { attempt in
            let result = await recorder.failure(at: attempt)
            if await recorder.callCount == 1 {
                await coordinator.request(refresh: { next in await recorder.failure(at: next) })
            }
            return result
        })
        await recorder.waitForCalls(2)
        #expect(await recorder.callCount == 2)
        await coordinator.cancel()
    }
}

private actor RefreshAttemptRecorder {
    private let failures: [TimelineRefreshFailureReason?]
    private(set) var callCount = 0
    private(set) var attempts: [Int] = []
    private(set) var decisions: [TimelineRefreshConvergenceDecision] = []

    init(failures: [TimelineRefreshFailureReason?]) { self.failures = failures }

    func failure(at attempt: Int) -> TimelineRefreshFailureReason? {
        defer { callCount += 1 }
        return failures[min(callCount, failures.count - 1)]
    }

    func record(_ value: TimelineUploadRefreshAttempt) {
        attempts.append(value.attempt)
        decisions.append(value.decision)
    }

    func waitForCalls(_ count: Int) async {
        while callCount < count { await Task.yield() }
    }

    func waitForAttempts(_ count: Int) async {
        while attempts.count < count { await Task.yield() }
    }
}
