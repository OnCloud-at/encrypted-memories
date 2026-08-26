import Foundation
import Testing

@testable import ProtonDriveBackend

@Suite("SDK cancellation adaptation")
struct SDKCancellableOperationTests {
    @Test func successfulOperationDoesNotInvokeCancellation() async throws {
        let probe = CancellationProbe()

        let value = try await SDKCancellableOperation.run { token in
            await probe.recordOperation(token)
            return 42
        } cancel: { token in
            await probe.cancel(token)
        }

        #expect(value == 42)
        #expect(await probe.operationToken != nil)
        #expect(await probe.cancellationToken == nil)
    }

    @Test func taskCancellationUsesTheOperationsExactToken() async throws {
        let probe = CancellationProbe()
        let task = Task {
            try await SDKCancellableOperation.run { token in
                await probe.waitForCancellation(of: token)
                throw CancellationError()
            } cancel: { token in
                await probe.cancel(token)
            }
        }

        while await probe.operationToken == nil {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await probe.cancellationToken == probe.operationToken)
        #expect(await probe.cancellationCount == 1)
    }

    @Test func cancellationRPCIsJoinedAfterNonCooperativeOperationReturns() async {
        let probe = JoinedCancellationProbe()
        let returned = CancellationReturnProbe()
        let task = Task {
            do {
                _ = try await SDKCancellableOperation.run { token in
                    await probe.runOperation(token)
                    return 42
                } cancel: { token in
                    await probe.runCancellation(token)
                }
            } catch {}
            await returned.markReturned()
        }

        while await probe.operationToken == nil {
            await Task.yield()
        }
        task.cancel()
        while await probe.cancellationToken == nil {
            await Task.yield()
        }

        await probe.releaseOperation()
        while await probe.operationReturned == false {
            await Task.yield()
        }
        #expect(
            await returned.hasReturned == false,
            "the wrapper must retain the native cancel owner after the operation settles")
        #expect(await probe.cancellationCount == 1)

        await probe.releaseCancellation()
        await task.value
        #expect(await returned.hasReturned)
        #expect(await probe.cancellationToken == probe.operationToken)
        #expect(await probe.cancellationCount == 1)
    }

    @Test func enumerationCollectorPreservesOrderAfterCompletion() throws {
        let collector = SDKEnumerationCollector<Int>()

        collector.receive(.success(3))
        collector.receive(.success(5))
        collector.receive(.success(8))

        #expect(try collector.collected() == [3, 5, 8])
    }

    @Test func enumerationCollectorRejectsPartialResultAfterFirstError() {
        struct ExpectedFailure: Error {}
        let collector = SDKEnumerationCollector<Int>()

        collector.receive(.success(3))
        collector.receive(.failure(ExpectedFailure()))
        collector.receive(.success(8))

        #expect(throws: ExpectedFailure.self) {
            try collector.collected()
        }
    }
}

private actor CancellationReturnProbe {
    private(set) var hasReturned = false

    func markReturned() {
        hasReturned = true
    }
}

private actor JoinedCancellationProbe {
    private(set) var operationToken: UUID?
    private(set) var cancellationToken: UUID?
    private(set) var cancellationCount = 0
    private(set) var operationReturned = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func runOperation(_ token: UUID) async {
        operationToken = token
        await withCheckedContinuation { operationContinuation = $0 }
        operationReturned = true
    }

    func runCancellation(_ token: UUID) async {
        cancellationToken = token
        cancellationCount += 1
        await withCheckedContinuation { cancellationContinuation = $0 }
    }

    func releaseOperation() {
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private actor CancellationProbe {
    private(set) var operationToken: UUID?
    private(set) var cancellationToken: UUID?
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func recordOperation(_ token: UUID) {
        operationToken = token
    }

    func waitForCancellation(of token: UUID) async {
        operationToken = token
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel(_ token: UUID) {
        cancellationToken = token
        cancellationCount += 1
        continuation?.resume()
        continuation = nil
    }
}
