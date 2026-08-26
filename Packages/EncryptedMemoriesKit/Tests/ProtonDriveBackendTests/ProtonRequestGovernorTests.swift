import Foundation
import ProtonDriveSDK
import Testing

@testable import ProtonDriveBackend

@Suite("Proton request governor")
struct ProtonRequestGovernorTests {
    @Test func immediateWorkOvertakesQueuedBackgroundWork() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api, priority: .background)
        let order = OrderRecorder()

        let background = Task {
            let permit = try await governor.acquire(scope: .api, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        let immediate = Task {
            let permit = try await governor.acquire(scope: .api, priority: .immediate)
            await order.append("immediate")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 2 }

        await governor.finish(first, statusCode: 200)
        try await immediate.value
        try await background.value
        #expect(await order.values == ["immediate", "background"])
    }

    @Test func rateLimitReducesConcurrencyAndSuccessesRecoverIt() async throws {
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(
                initial: 4,
                maximum: 6,
                successWindow: 2
            ))

        for _ in 0..<3 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        let limited = try await governor.acquire(scope: .api)
        await governor.finish(limited, statusCode: 429, retryAfter: 0.001)

        var snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 2)
        #expect(snapshot.rateLimitedLastMinute == 1)
        #expect(snapshot.sustainableRateBeforeLastLimit == 3)
        #expect(snapshot.successfulRequestsPerSecondBeforeLastLimit == 3)
        #expect(snapshot.admissionInterval > 0)

        for _ in 0..<2 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 3)
    }

    @Test func cancellingQueuedRequestDoesNotLeakAWaiter() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        let queued = Task { try await governor.acquire(scope: .api, priority: .maintenance) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("cancelled acquisition unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await governor.snapshot().api.queued == 0)
        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 0)
    }

    @Test func finishingSamePermitTwiceCannotReleaseAnotherRequest() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        await governor.finish(first, statusCode: 200)
        let second = try await governor.acquire(scope: .api)
        let third = Task { try await governor.acquire(scope: .api) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 1)
        #expect(await governor.snapshot().api.queued == 1)

        third.cancel()
        _ = try? await third.value
        await governor.finish(second, statusCode: 200)
    }

    @Test func sdkPriorityScopeSurvivesNativeTaskBoundary() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload, priority: .background)
        let order = OrderRecorder()
        let background = Task {
            let permit = try await governor.acquire(scope: .storageDownload, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }

        let scope = await governor.beginPriorityScope(.immediate)
        let sdkCallback = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await governor.acquire(scope: .storageDownload)
            }
            await order.append("visible")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }
        await governor.finish(first, statusCode: 200)

        try await sdkCallback.value
        await governor.endPriorityScope(scope)
        try await background.value
        #expect(await order.values == ["visible", "background"])
    }

    @Test func explicitPrefetchRemainsBelowImmediateDemandDuringViewerPromotion() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload, priority: .background)
        let order = OrderRecorder()
        let viewerScope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.storageDownload]
        )

        let prefetch = Task {
            let permit = try await governor.acquire(
                scope: .storageDownload,
                priority: .foregroundPrefetch
            )
            await order.append("prefetch")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }

        let immediate = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.immediate) {
                try await governor.acquire(scope: .storageDownload)
            }
            await order.append("immediate")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }

        await governor.finish(first, statusCode: 200)
        try await immediate.value
        try await prefetch.value
        await governor.endPriorityScope(viewerScope)
        #expect(await order.values == ["immediate", "prefetch"])
    }

    @Test func targetedPriorityDoesNotPromoteUnrelatedUpload() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageUpload, priority: .background)
        let order = OrderRecorder()
        let background = Task {
            let permit = try await governor.acquire(scope: .storageUpload, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        let scope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload]
        )
        let unrelated = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await governor.acquire(scope: .storageUpload)
            }
            await order.append("unrelated")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 2 }
        await governor.finish(first, statusCode: 200)

        try await background.value
        await governor.endPriorityScope(scope)
        try await unrelated.value
        #expect(await order.values == ["background", "unrelated"])
    }

    @Test func interactiveViewerScopeBlocksOnlyNewUploadsAndEndResumesThem() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let activeUpload = try await governor.acquire(scope: .storageUpload, priority: .background)
        let scope = await governor.beginPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        let queuedUpload = Task {
            try await governor.acquire(scope: .storageUpload, priority: .background)
        }
        try await Self.waitUntil {
            let snapshot = await governor.snapshot().storageUpload
            return snapshot.inFlight == 1 && snapshot.queued == 1
        }
        await governor.finish(activeUpload, statusCode: 200)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await governor.snapshot().storageUpload.inFlight == 0)
        #expect(await governor.snapshot().storageUpload.queued == 1)

        await governor.endPriorityScope(scope)
        let resumed = try await queuedUpload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(resumed, statusCode: 200)
    }

    @Test func structuredPriorityScopeSurvivesWatchdogAndEndsOnCompletion() async throws {
        let clock = TestClock()
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 1, maximum: 1, priorityLifetime: 1),
            now: { clock.now }
        )
        let activeUpload = try await governor.acquire(scope: .storageUpload, priority: .background)
        let started = AsyncLatch()
        let complete = AsyncLatch()
        let interactive = Task {
            await governor.withPriorityScope(
                .immediate,
                promoting: [.api, .storageDownload],
                suspending: [.storageUpload]
            ) {
                await started.open()
                await complete.wait()
            }
        }
        await started.wait()
        let queuedUpload = Task {
            try await governor.acquire(scope: .storageUpload, priority: .background)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        await governor.finish(activeUpload, statusCode: 200)
        clock.now = clock.now.addingTimeInterval(2)
        _ = await governor.snapshot()

        #expect(await governor.snapshot().storageUpload.inFlight == 0)
        #expect(await governor.snapshot().storageUpload.queued == 1)
        await complete.open()
        await interactive.value
        let resumed = try await queuedUpload.value
        await governor.finish(resumed, statusCode: 200)
        #expect(await governor.snapshot().storageUpload.inFlight == 0)
    }

    @Test func unstructuredPriorityScopeExpiresAndResumesQueuedUploads() async throws {
        let clock = TestClock()
        let governor = ProtonRequestGovernor(
            configuration: Self.configuration(initial: 1, maximum: 1, priorityLifetime: 1),
            now: { clock.now }
        )
        let activeUpload = try await governor.acquire(scope: .storageUpload, priority: .background)
        _ = await governor.beginUnstructuredPriorityScope(
            .immediate,
            promoting: [.api, .storageDownload],
            suspending: [.storageUpload]
        )
        let queuedUpload = Task {
            try await governor.acquire(scope: .storageUpload, priority: .background)
        }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        await governor.finish(activeUpload, statusCode: 200)
        clock.now = clock.now.addingTimeInterval(2)
        _ = await governor.snapshot()
        let resumed = try await queuedUpload.value
        await governor.finish(resumed, statusCode: 200)
        #expect(await governor.snapshot().storageUpload.inFlight == 0)
    }

    @Test func boundedInteractiveRequestReleasesUploadAdmissionWhenCancelled() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let started = AsyncLatch()
        let interactive = Task {
            try await governor.withPriorityScope(
                .immediate,
                promoting: [],
                suspending: [.storageUpload]
            ) {
                await started.open()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()
        let upload = Task { try await governor.acquire(scope: .storageUpload, priority: .background) }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        interactive.cancel()
        _ = try? await interactive.value
        let permit = try await upload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(permit, statusCode: 200)
    }

    @Test func structuredPriorityScopeReleasesUploadAdmissionWhenThrown() async throws {
        struct ExpectedFailure: Error {}

        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let started = AsyncLatch()
        let fail = AsyncLatch()
        let interactive = Task {
            let _: Void = try await governor.withPriorityScope(
                .immediate,
                promoting: [],
                suspending: [.storageUpload]
            ) {
                await started.open()
                await fail.wait()
                throw ExpectedFailure()
            }
        }
        await started.wait()
        let upload = Task { try await governor.acquire(scope: .storageUpload, priority: .background) }
        try await Self.waitUntil { await governor.snapshot().storageUpload.queued == 1 }

        await fail.open()
        await #expect(throws: ExpectedFailure.self) { try await interactive.value }
        let permit = try await upload.value
        #expect(await governor.snapshot().storageUpload.inFlight == 1)
        await governor.finish(permit, statusCode: 200)
    }

    @Test func completedProducerKeepsStoragePermitUntilConsumerObservesEOF() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        let completion = StreamPermitCompletion(governor: governor, permit: first)
        let (source, producer) = AsyncStream<UInt8>.makeStream()
        producer.yield(1)
        producer.finish()
        let wrapped = PermitFinishingAsyncSequence(
            source: AnyAsyncSequence(source),
            completion: completion,
            responseStatusCode: 200,
            retryAfter: nil
        )
        var iterator: PermitFinishingAsyncSequence.Iterator? = wrapped.makeAsyncIterator()

        let second = Task { try await governor.acquire(scope: .storageDownload) }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        #expect(try await iterator?.next() == 1)
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        #expect(await governor.snapshot().storageDownload.queued == 1)

        #expect(try await iterator?.next() == nil)
        iterator = nil
        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func thrownConsumerReleasesStoragePermitAsFailure() async throws {
        struct ExpectedFailure: Error {}
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        let completion = StreamPermitCompletion(governor: governor, permit: first)
        let source = AsyncThrowingStream<UInt8, Error> { continuation in
            continuation.finish(throwing: ExpectedFailure())
        }
        let wrapped = PermitFinishingAsyncSequence(
            source: AnyAsyncSequence(source),
            completion: completion,
            responseStatusCode: 200,
            retryAfter: nil
        )
        var iterator = wrapped.makeAsyncIterator()

        let second = Task { try await governor.acquire(scope: .storageDownload) }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }
        await #expect(throws: ExpectedFailure.self) { try await iterator.next() }

        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func droppingUnconsumedStorageStreamReleasesPermitWithoutRetainingCompletion() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload)
        weak var releasedCompletion: StreamPermitCompletion?
        do {
            let completion = StreamPermitCompletion(governor: governor, permit: first)
            releasedCompletion = completion
        }

        #expect(releasedCompletion == nil)
        try await Self.waitUntil { await governor.snapshot().storageDownload.inFlight == 0 }
        let second = Task { try await governor.acquire(scope: .storageDownload) }
        let secondPermit = try await second.value
        #expect(await governor.snapshot().storageDownload.inFlight == 1)
        await governor.finish(secondPermit, statusCode: 200)
    }

    @Test func retryAfterParsesSecondsAndHTTPDate() throws {
        let url = try #require(URL(string: "https://drive-api.proton.me/test"))
        let seconds = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "7"]
            ))
        #expect(ProtonRetryAfter.seconds(from: seconds) == 7)

        let now = Date(timeIntervalSince1970: 784_111_777)
        let date = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:49:47 GMT"]
            ))
        #expect(ProtonRetryAfter.seconds(from: date, now: now) == 10)
    }

    private static func configuration(
        initial: Int,
        maximum: Int,
        successWindow: Int = 32,
        priorityLifetime: TimeInterval = 60
    ) -> ProtonRequestGovernor.Configuration {
        let scope = ProtonRequestGovernor.Configuration.Scope(
            initialConcurrency: initial,
            maximumConcurrency: maximum
        )
        return .init(
            api: scope,
            storageDownload: scope,
            storageUpload: scope,
            successWindowForIncrease: successWindow,
            starvationPromotionInterval: 10,
            priorityScopeLifetime: priorityLifetime
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition did not become true before timeout")
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private actor AsyncLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
