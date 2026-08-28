import Foundation
import PhotosCore
import Testing

@testable import TimelineCore

@Suite struct LibraryChangeMonitorTests {
    @Test func refreshesOnlyAfterOpaqueTokenChanges() async throws {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(5), failureInterval: .milliseconds(5))
        ) {
            await counter.increment()
            return .refreshed
        }

        try await Task.sleep(for: .milliseconds(18))
        #expect(await counter.value == 0)

        await provider.set("b")
        let deadline = ContinuousClock.now + .seconds(2)
        while await counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test func stopAndRestartPreservesBaselineForChangesWhileSuspended() async throws {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        let policy = LibraryChangePollingPolicy(
            interval: .milliseconds(5), failureInterval: .milliseconds(5))
        await monitor.start(provider: provider, policy: policy) {
            await counter.increment()
            return .refreshed
        }
        try await Task.sleep(for: .milliseconds(12))
        await monitor.stop()

        await provider.set("b")
        await monitor.restart(provider: provider, policy: policy) {
            await counter.increment()
            return .refreshed
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test func failedRefreshDoesNotConsumeChangedToken() async throws {
        let provider = TokenProvider("a")
        let attempts = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .milliseconds(5), failureInterval: .milliseconds(5))
        ) {
            await attempts.increment()
            return await attempts.value > 1 ? .refreshed : .retry
        }

        try await Task.sleep(for: .milliseconds(12))
        await provider.set("b")
        let deadline = ContinuousClock.now + .seconds(2)
        while await attempts.value < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await attempts.value == 2)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func seededBaselineDetectsMutationBeforeFirstPoll() async {
        let provider = TokenProvider("new")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            initialToken: "cached"
        ) {
            await counter.increment()
            return .refreshed
        }

        // The second probe proves that the first changed token was accepted and committed.
        await provider.waitUntilProbeCount(2)
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func restartDoesNotReplaceANewerRetainedBaselineWithStartupSeed() async {
        let provider = TokenProvider("a")
        let counter = Counter()
        let monitor = LibraryChangeMonitor()
        let policy = LibraryChangePollingPolicy(
            interval: .zero, failureInterval: .zero)
        await monitor.start(provider: provider, policy: policy, initialToken: "a") {
            await counter.increment()
            return .refreshed
        }
        await provider.set("b")
        let countAfterMutation = await provider.probeCount
        // One probe observes the mutation. The next proves that the new baseline was committed.
        await provider.waitUntilProbeCount(countAfterMutation + 2)
        #expect(await counter.value == 1)
        await monitor.stop()

        let countBeforeRestart = await provider.probeCount
        await monitor.start(provider: provider, policy: policy, initialToken: "a") {
            await counter.increment()
            return .refreshed
        }
        await provider.waitUntilProbeCount(countBeforeRestart + 1)
        #expect(await counter.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopWaitsForANonCooperativeProbeBeforeReturning() async {
        let provider = BlockingTokenProvider()
        let completion = CompletionProbe()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            Issue.record("A cancelled probe must not publish a library change")
            return .refreshed
        }

        await provider.waitUntilEntered()
        let stopTask = Task {
            await monitor.stop()
            await completion.markComplete()
        }
        await provider.waitUntilCancellationObserved()

        #expect(await completion.isComplete == false)
        await provider.release()
        await stopTask.value
        #expect(await completion.isComplete)
    }

    @Test(.timeLimit(.minutes(1)))
    func startDuringStopRunsAfterTheRetiringProbeReturns() async {
        let retiringProvider = BlockingTokenProvider()
        let replacementProvider = TokenProvider("replacement")
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: retiringProvider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            Issue.record("A cancelled probe must not publish a library change")
            return .refreshed
        }

        await retiringProvider.waitUntilEntered()
        let stopTask = Task { await monitor.stop() }
        await retiringProvider.waitUntilCancellationObserved()

        // This request arrives while stop() is suspended on a non-cooperative probe.
        // It must become the active monitor after that probe retires, rather than being dropped.
        await monitor.start(
            provider: replacementProvider,
            policy: .init(interval: .zero, failureInterval: .zero)
        ) {
            .refreshed
        }
        await retiringProvider.release()
        await stopTask.value

        #expect(await replacementProvider.observesProbeCount(1))
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalScopeFailureRetiresTaskBeforeHostRecoveryRestartsMonitor() async {
        let provider = TerminalTokenProvider()
        let replacement = TokenProvider("replacement")
        let terminalCallbacks = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            onTerminal: { _ in
                await terminalCallbacks.increment()
                await monitor.restart(
                    provider: replacement,
                    policy: .init(interval: .zero, failureInterval: .zero)
                ) {
                    .refreshed
                }
            },
            onChange: {
                Issue.record("A terminal scope failure must not publish a library change")
                return .refreshed
            }
        )

        await provider.waitUntilProbed()
        await replacement.waitUntilProbeCount(1)

        #expect(await provider.probeCount == 1)
        #expect(await terminalCallbacks.value == 1)
        await monitor.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalRefreshOutcomeRetiresTaskBeforeCallingHostRecovery() async {
        let provider = TokenProvider("new")
        let terminalCallbacks = Counter()
        let monitor = LibraryChangeMonitor()
        await monitor.start(
            provider: provider,
            policy: .init(interval: .zero, failureInterval: .zero),
            initialToken: "old",
            onTerminal: { _ in await terminalCallbacks.increment() },
            onChange: { .terminal }
        )

        await provider.waitUntilProbeCount(1)
        while await terminalCallbacks.value == 0 { await Task.yield() }

        #expect(await provider.probeCount == 1)
        #expect(await terminalCallbacks.value == 1)
        await monitor.stop()
    }
}

private actor TokenProvider: LibraryChangeTokenProvider {
    private var token: String
    private(set) var probeCount = 0
    private var probeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ token: String) { self.token = token }

    func set(_ token: String) { self.token = token }

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        let completed = probeWaiters.filter { probeCount >= $0.count }
        probeWaiters.removeAll { probeCount >= $0.count }
        for waiter in completed {
            waiter.continuation.resume()
        }
        return token
    }

    func waitUntilProbeCount(_ count: Int) async {
        guard probeCount < count else { return }
        await withCheckedContinuation { continuation in
            probeWaiters.append((count, continuation))
        }
    }

    func observesProbeCount(_ count: Int, withinSchedulerTurns turns: Int = 10_000) async -> Bool {
        for _ in 0..<turns {
            if probeCount >= count { return true }
            await Task.yield()
        }
        return probeCount >= count
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor BlockingTokenProvider: LibraryChangeTokenProvider {
    private let entered = TestSignal()
    private let cancellationObserved = TestSignal()
    private let releaseSignal = TestSignal()

    func libraryChangeToken() async throws -> String {
        await entered.signal()
        while !Task.isCancelled {
            await Task.yield()
        }
        await cancellationObserved.signal()
        await releaseSignal.wait()
        return "cancelled-probe"
    }

    func waitUntilEntered() async { await entered.wait() }
    func waitUntilCancellationObserved() async { await cancellationObserved.wait() }
    func release() async { await releaseSignal.signal() }
}

private struct ExpectedTerminalLibraryChangeError: LibraryChangeTerminalError {}

private actor TerminalTokenProvider: LibraryChangeTokenProvider {
    private(set) var probeCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func libraryChangeToken() async throws -> String {
        probeCount += 1
        waiter?.resume()
        waiter = nil
        throw ExpectedTerminalLibraryChangeError()
    }

    func waitUntilProbed() async {
        guard probeCount == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor TestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
