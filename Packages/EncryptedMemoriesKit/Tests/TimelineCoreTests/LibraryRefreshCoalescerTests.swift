import Testing

@testable import TimelineCore

@Suite struct LibraryRefreshCoalescerTests {
    @Test func overlappingRequestWaitsAndRunsExactlyOneFollowUpRefresh() async {
        let coalescer = LibraryRefreshCoalescer()
        let probe = BlockingRefreshProbe()

        let first = await coalescer.enqueue { await probe.refresh() }
        await probe.waitUntilFirstRefreshStarts()
        let second = await coalescer.enqueue { await probe.refresh() }
        let third = await coalescer.enqueue { await probe.refresh() }

        await probe.releaseFirstRefresh()

        #expect(await first.value)
        #expect(await second.value)
        #expect(await third.value)
        #expect(await probe.callCount == 2)
    }

    @Test func completedDrainDoesNotRetainAStaleTask() async {
        let coalescer = LibraryRefreshCoalescer()
        let counter = RefreshCounter()

        #expect(await coalescer.request { await counter.refresh() })
        #expect(await coalescer.request { await counter.refresh() })
        #expect(await counter.value == 2)
    }

    @Test func cancellationDoesNotLetOldDrainClearNewerRequest() async {
        let coalescer = LibraryRefreshCoalescer()
        let blocked = BlockingRefreshProbe()
        let replacement = RefreshCounter()

        let old = await coalescer.enqueue { await blocked.refresh() }
        await blocked.waitUntilFirstRefreshStarts()
        await coalescer.cancel()
        let new = await coalescer.enqueue { await replacement.refresh() }
        await blocked.releaseFirstRefresh()

        #expect(await new.value)
        #expect(await replacement.value == 1)
        _ = await old.value
    }
}

private actor RefreshCounter {
    private(set) var value = 0

    func refresh() -> Bool {
        value += 1
        return true
    }
}

private actor BlockingRefreshProbe {
    private(set) var callCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRefreshContinuation: CheckedContinuation<Void, Never>?

    func refresh() async -> Bool {
        callCount += 1
        guard callCount == 1 else { return true }

        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstRefreshContinuation = continuation
        }
        return true
    }

    func waitUntilFirstRefreshStarts() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstRefresh() {
        firstRefreshContinuation?.resume()
        firstRefreshContinuation = nil
    }
}
