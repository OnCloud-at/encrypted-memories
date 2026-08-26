import Testing

@testable import PhotosCore

private actor ShutdownGateLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !open else { return }
        open = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private actor ShutdownGateProbe {
    private var starts = 0
    private var completions = 0

    func start() { starts += 1 }
    func complete() { completions += 1 }
    func snapshot() -> (starts: Int, completions: Int) { (starts, completions) }
}

@Suite("Joined shutdown gate")
struct JoinedShutdownGateTests {
    @Test func concurrentCallersAwaitOneTeardown() async {
        let gate = JoinedShutdownGate()
        let entered = ShutdownGateLatch()
        let release = ShutdownGateLatch()
        let probe = ShutdownGateProbe()

        let first = Task {
            await gate.run {
                await probe.start()
                await entered.signal()
                await release.wait()
                await probe.complete()
            }
        }
        await entered.wait()
        let secondReturned = ShutdownGateProbe()
        let second = Task {
            await gate.run { await probe.start() }
            await secondReturned.complete()
        }

        await Task.yield()
        #expect(await secondReturned.snapshot().completions == 0)
        #expect(await probe.snapshot().starts == 1)

        await release.signal()
        await first.value
        await second.value
        #expect(await probe.snapshot().starts == 1)
        #expect(await probe.snapshot().completions == 1)

        await gate.run { await probe.start() }
        #expect(await probe.snapshot().starts == 1)
    }

    @Test func closeCancelsAndJoinsAdmittedWorkBeforeTeardown() async throws {
        let gate = JoinedShutdownGate()
        let operationEntered = ShutdownGateLatch()
        let releaseOperation = ShutdownGateLatch()
        let admissionClosed = ShutdownGateLatch()
        let teardownProbe = ShutdownGateProbe()
        let shutdownReturned = ShutdownGateProbe()

        let operation = Task {
            try await gate.withAdmission {
                await operationEntered.signal()
                await releaseOperation.wait()
                return Task.isCancelled
            }
        }
        await operationEntered.wait()

        let shutdown = Task {
            gate.closeAdmission()
            await admissionClosed.signal()
            await gate.run {
                await teardownProbe.start()
                await teardownProbe.complete()
            }
            await shutdownReturned.complete()
        }
        await admissionClosed.wait()

        var rejected = false
        do {
            _ = try await gate.withAdmission { 1 }
        } catch is CancellationError {
            rejected = true
        } catch {}
        #expect(rejected)
        #expect(await teardownProbe.snapshot().starts == 0)
        #expect(await shutdownReturned.snapshot().completions == 0)

        await releaseOperation.signal()
        let operationWasCancelled = try await operation.value
        #expect(operationWasCancelled)
        await shutdown.value
        #expect(await teardownProbe.snapshot().starts == 1)
        #expect(await teardownProbe.snapshot().completions == 1)
        #expect(await shutdownReturned.snapshot().completions == 1)
    }
}
