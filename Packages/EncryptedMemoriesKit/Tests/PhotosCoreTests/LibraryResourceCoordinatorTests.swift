import XCTest

@testable import PhotosCore

final class LibraryResourceCoordinatorTests: XCTestCase {
    func testRuntimeStatePublishesNewestAndGenerationResetClearsFeatureDemand() async throws {
        let state = LibraryRuntimeState()
        let stream = state.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.generation, 0)

        state.update {
            $0.hasVisibleMediaDemand = true
            $0.activeUserTransferCount = 3
        }
        let updated = await iterator.next()
        XCTAssertEqual(updated?.activeUserTransferCount, 3)
        let noOp = state.update { _ in }
        XCTAssertEqual(noOp, updated)

        let reset = state.beginNewGeneration()
        XCTAssertEqual(reset.generation, 1)
        XCTAssertFalse(reset.hasVisibleMediaDemand)
        XCTAssertEqual(reset.activeUserTransferCount, 0)
    }

    func testPolicyMatrixProtectsCriticalAndVisibleWork() {
        let policy = LibraryResourcePolicy()
        let automatic = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let interactive = LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small)

        var snapshot = LibraryRuntimeSnapshot(thermalLevel: .critical)
        XCTAssertFalse(policy.budget(for: interactive, snapshot: snapshot).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(hasVisibleMediaDemand: true)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertTrue(policy.budget(for: interactive, snapshot: snapshot).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(thermalLevel: .serious)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertEqual(policy.budget(for: interactive, snapshot: snapshot).maxItemsPerQuantum, 1)
        XCTAssertFalse(
            policy.budget(
                for: LibraryWorkRequest(workload: .mlModelLoading, intent: .userInitiated, memoryClass: .large),
                snapshot: snapshot
            ).isAdmitted)

        snapshot = LibraryRuntimeSnapshot(isLowPowerMode: true)
        XCTAssertFalse(policy.budget(for: automatic, snapshot: snapshot).isAdmitted)
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .backupHashing, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
    }

    func testRequestWithoutDemandPreservesLegacyBudget() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(workload: .mlIndexing, intent: .automatic),
            snapshot: LibraryRuntimeSnapshot()
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 1)
        XCTAssertEqual(budget.maxItemsPerQuantum, 2)
        XCTAssertNil(budget.maximumWallTime)
        XCTAssertEqual(budget.reason, .nominal)
    }

    func testAutomaticMLDemandReceivesRequestedNominalEnvelope() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(
                workload: .mlIndexing,
                intent: .automatic,
                demand: LibraryWorkDemand(
                    maximumInternalParallelism: 3,
                    maximumItemsPerQuantum: 32,
                    maximumWallTime: .seconds(2)
                )
            ),
            snapshot: LibraryRuntimeSnapshot()
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 3)
        XCTAssertEqual(budget.maxItemsPerQuantum, 32)
        XCTAssertEqual(budget.maximumWallTime, .seconds(2))
        XCTAssertEqual(budget.reason, .nominal)
    }

    func testFairPressureRestrictsAutomaticMLDemandToOneAssetAndHalfSecond() {
        let budget = LibraryResourcePolicy().budget(
            for: LibraryWorkRequest(
                workload: .mlIndexing,
                intent: .automatic,
                demand: LibraryWorkDemand(
                    maximumInternalParallelism: 3,
                    maximumItemsPerQuantum: 128,
                    maximumWallTime: .seconds(2)
                )
            ),
            snapshot: LibraryRuntimeSnapshot(thermalLevel: .fair)
        )

        XCTAssertTrue(budget.isAdmitted)
        XCTAssertEqual(budget.internalParallelism, 1)
        XCTAssertEqual(budget.maxItemsPerQuantum, 1)
        XCTAssertEqual(budget.maximumWallTime, .milliseconds(500))
        XCTAssertEqual(budget.reason, .fairPressure)
    }

    func testLeaseYieldsToEveryLiveSafetySignal() async throws {
        let cases:
            [(
                LibraryWorkYieldReason,
                @Sendable (LibraryRuntimeState) -> Void
            )] = [
                (.visibleDemand, { state in state.update { $0.hasVisibleMediaDemand = true } }),
                (.userInteraction, { state in state.update { $0.hasActiveUserInteraction = true } }),
                (.lowPowerMode, { state in state.update { $0.isLowPowerMode = true } }),
                (.thermalPressure, { state in state.update { $0.thermalLevel = .serious } }),
                (.memoryPressure, { state in state.update { $0.memoryBudgetTier = .reduced } }),
                (.executionSuspended, { state in state.update { $0.executionOpportunity = .suspended } }),
                (.generationChanged, { state in _ = state.beginNewGeneration() }),
            ]
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)

        for (expected, mutate) in cases {
            let state = LibraryRuntimeState()
            let coordinator = LibraryResourceCoordinator(runtimeState: state)
            let decision = try await coordinator.withHeavyPermit(request) { lease in
                XCTAssertTrue(lease.shouldContinue())
                mutate(state)
                return lease.continuationDecision()
            }
            XCTAssertEqual(decision, .yield(expected))
        }
    }

    func testLeaseUsesInjectedMonotonicDeadline() async throws {
        let clock = TestMonotonicClock()
        let coordinator = LibraryResourceCoordinator(
            runtimeState: LibraryRuntimeState(),
            monotonicNow: { clock.now() }
        )
        let request = LibraryWorkRequest(
            workload: .mlIndexing,
            intent: .automatic,
            demand: LibraryWorkDemand(
                maximumInternalParallelism: 3,
                maximumItemsPerQuantum: 32,
                maximumWallTime: .seconds(2)
            )
        )

        let decisions = try await coordinator.withHeavyPermit(request) { lease in
            let before = lease.continuationDecision()
            clock.advance(by: 1_999_999_999)
            let inside = lease.continuationDecision()
            clock.advance(by: 1)
            let expired = lease.continuationDecision()
            return [before, inside, expired]
        }

        XCTAssertEqual(
            decisions,
            [
                .continueWork,
                .continueWork,
                .yield(.timeSliceCompleted),
            ])
    }

    func testHigherPriorityWaiterPreemptsAutomaticLeaseAtBoundary() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let holderGate = AsyncGate()
        let leaseBox = LeaseBox()
        let automatic = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
            ) { lease in
                await leaseBox.store(lease)
                await holderGate.wait()
            }
        }
        let lease = await leaseBox.waitForLease()
        XCTAssertTrue(lease.shouldContinue())

        let interactive = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .mlInference,
                    intent: .interactive,
                    memoryClass: .small
                )
            ) { _ in true }
        }
        let didPreempt = await waitUntil {
            lease.continuationDecision() == .yield(.higherPriorityWork)
        }
        XCTAssertTrue(didPreempt)

        await holderGate.open()
        try await automatic.value
        let interactiveCompleted = try await interactive.value
        XCTAssertTrue(interactiveCompleted)
    }

    func testExpiredVisibleDemandReleasesWaitingModelLoadPermit() async throws {
        let state = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(hasVisibleMediaDemand: true)
        )
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        let permit = Task {
            try await coordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .mlModelLoading,
                    intent: .automatic,
                    memoryClass: .large
                )
            ) { _ in true }
        }

        await Task.yield()
        let metricsWhileBlocked = await coordinator.metrics()
        XCTAssertEqual(metricsWhileBlocked.permitsAcquired, 0)

        state.update { $0.hasVisibleMediaDemand = false }
        let admitted = try await permit.value
        let finalMetrics = await coordinator.metrics()
        XCTAssertTrue(admitted)
        XCTAssertEqual(finalMetrics.permitsAcquired, 1)
        XCTAssertEqual(finalMetrics.permitsReleased, 1)
    }

    func testEnforcedCoordinatorAllowsOnlyOneHeavyPermit() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let counter = ActiveCounter()
        let request = LibraryWorkRequest(workload: .backupHashing, intent: .automatic)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await coordinator.withHeavyPermit(request) { _ in
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum()
        XCTAssertEqual(maximum, 1)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.permitsAcquired, 8)
        XCTAssertEqual(metrics.permitsReleased, 8)
        XCTAssertEqual(metrics.maximumConcurrentPermits, 1)
    }

    func testCancelledWaiterDoesNotLeakAdmission() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let gate = AsyncGate()
        let request = LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
        let holder = Task {
            try await coordinator.withHeavyPermit(request) { _ in await gate.wait() }
        }
        await gate.waitUntilEntered()

        let cancelled = Task {
            try await coordinator.withHeavyPermit(request) { _ in XCTFail("cancelled waiter ran") }
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        await gate.open()
        try await holder.value
        let completed = try await coordinator.withHeavyPermit(request) { _ in true }
        XCTAssertTrue(completed)
    }

    func testRecoveryHysteresisRequiresStableDelay() async throws {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .critical))
        let coordinator = LibraryResourceCoordinator(
            runtimeState: state, recoveryDelay: .milliseconds(30)
        )
        await coordinator.startObserving()
        let request = LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        let initiallyAdmitted = await coordinator.budget(for: request).isAdmitted
        XCTAssertFalse(initiallyAdmitted)

        state.update { $0.thermalLevel = .nominal }
        try await Task.sleep(for: .milliseconds(5))
        let admittedDuringRecovery = await coordinator.budget(for: request).isAdmitted
        XCTAssertFalse(admittedDuringRecovery)
        try await Task.sleep(for: .milliseconds(40))
        let admittedAfterRecovery = await coordinator.budget(for: request).isAdmitted
        XCTAssertTrue(admittedAfterRecovery)
    }

    func testGenerationChangeRejectsAQueuedOldSessionPermit() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        let gate = AsyncGate()
        let request = LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
        let holder = Task {
            try await coordinator.withHeavyPermit(request) { _ in await gate.wait() }
        }
        await gate.waitUntilEntered()
        let stale = Task {
            try await coordinator.withHeavyPermit(request) { _ in XCTFail("stale session work ran") }
        }

        state.beginNewGeneration()
        try await Task.sleep(for: .milliseconds(5))
        await gate.open()
        try await holder.value
        do {
            try await stale.value
            XCTFail("expected stale work cancellation")
        } catch is CancellationError {}
    }
}

private actor AsyncGate {
    private var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor ActiveCounter {
    private var active = 0
    private var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() { active -= 1 }
    func current() -> Int { active }
    func maximum() -> Int { peak }
}

private actor LeaseBox {
    private var lease: LibraryWorkLease?

    func store(_ lease: LibraryWorkLease) {
        self.lease = lease
    }

    func waitForLease() async -> LibraryWorkLease {
        while lease == nil { await Task.yield() }
        return lease!
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 { lock.withLock { value } }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}
