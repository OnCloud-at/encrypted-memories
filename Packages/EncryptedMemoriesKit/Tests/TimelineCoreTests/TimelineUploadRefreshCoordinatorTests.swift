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

    @Test func supersededCancelledResultRunsLatestRequestAndSkipsStaleObserver() async {
        let firstRelease = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))

        await coordinator.request(
            refresh: { _ in
                await recorder.markFirstStarted()
                await firstRelease.wait()
                return .cancelled
            },
            observer: { _ in await recorder.recordOldObservation() }
        )
        await recorder.waitForFirstStart()
        await coordinator.request(
            refresh: { _ in
                await recorder.markSecondStarted()
                return nil
            },
            observer: { _ in await recorder.recordNewObservation() }
        )
        await firstRelease.open()
        await recorder.waitForNewObservation()

        #expect(await recorder.secondStarts == 1)
        #expect(await recorder.oldObservations == 0)
        #expect(await recorder.newObservations == 1)
        await coordinator.cancel()
    }

    @Test func cancelledWorkerCannotClearReplacementWorker() async {
        let firstRelease = AsyncGate()
        let secondRelease = AsyncGate()
        let recorder = CoordinatorRaceRecorder()
        let coordinator = TimelineUploadRefreshCoordinator(policy: .init(schedule: .init(delays: [.zero])))

        await coordinator.request(refresh: { _ in
            await recorder.markFirstStarted()
            while !Task.isCancelled { await Task.yield() }
            await recorder.markFirstCancelled()
            await firstRelease.wait()
            return .cancelled
        })
        await recorder.waitForFirstStart()
        let cancellation = Task { await coordinator.cancel() }
        await recorder.waitForFirstCancellation()

        await coordinator.request(refresh: { _ in
            await recorder.markSecondStarted()
            await secondRelease.wait()
            return nil
        })
        await recorder.waitForSecondStart()
        await firstRelease.open()
        await cancellation.value

        await coordinator.request(refresh: { _ in
            await recorder.markThirdStarted()
            return nil
        })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.thirdStarts == 0)

        await secondRelease.open()
        await recorder.waitForThirdStart()
        #expect(await recorder.thirdStarts == 1)
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

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CoordinatorRaceRecorder {
    private(set) var firstStarts = 0
    private(set) var firstCancellations = 0
    private(set) var secondStarts = 0
    private(set) var thirdStarts = 0
    private(set) var oldObservations = 0
    private(set) var newObservations = 0

    func markFirstStarted() { firstStarts += 1 }
    func markFirstCancelled() { firstCancellations += 1 }
    func markSecondStarted() { secondStarts += 1 }
    func markThirdStarted() { thirdStarts += 1 }
    func recordOldObservation() { oldObservations += 1 }
    func recordNewObservation() { newObservations += 1 }

    func waitForFirstStart() async {
        while firstStarts == 0 { await Task.yield() }
    }

    func waitForFirstCancellation() async {
        while firstCancellations == 0 { await Task.yield() }
    }

    func waitForSecondStart() async {
        while secondStarts == 0 { await Task.yield() }
    }

    func waitForThirdStart() async {
        while thirdStarts == 0 { await Task.yield() }
    }

    func waitForNewObservation() async {
        while newObservations == 0 { await Task.yield() }
    }
}
