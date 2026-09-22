import Foundation
import Testing

@testable import ProtonDriveBackend

struct VideoPrefetchCompletionTests {
    @Test func cancellingOneWaiterDoesNotCancelOtherWaitersOrThePrefetch() async throws {
        let completion = VideoPrefetchCompletion()
        let cancelled = Task { try await completion.wait() }
        let current = Task { try await completion.wait() }
        cancelled.cancel()
        do {
            try await cancelled.value
            Issue.record("A cancelled range request remained attached to the prefetch")
        } catch is CancellationError {}
        completion.finish()
        completion.finish()
        try await current.value
        try await completion.wait()
    }

    @Test func cancellationBeforeRegistrationAlwaysReturns() async {
        let completion = VideoPrefetchCompletion()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await completion.wait()
        }
        do {
            try await waiter.value
            Issue.record("A cancelled waiter was registered")
        } catch is CancellationError {
        } catch { Issue.record(error) }
        completion.finish()
    }
}
