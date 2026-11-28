import Foundation
import Testing

@testable import PhotosCore

@Suite struct LibraryRuntimeStateStreamTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// A subscriber whose task is cancelled while a writer yields a snapshot to it ends without blocking the writer.
    /// The cancellation ends the subscriber's stream inside the task's own cancellation, while the writer resumes that
    /// same task, so neither may wait for the other. A deadlock leaves both threads stuck; the test then fails at its
    /// bound instead of stalling the run.
    @Test func cancellingASubscriberWhileAWriterYieldsToItBlocksNeitherSide() async throws {
        let state = LibraryRuntimeState()
        let stop = Flag()
        let writerEnded = Flag()
        let cancellerEnded = Flag()
        let writer = Thread {
            var searching = false
            while !stop.value {
                searching.toggle()
                let count = searching ? 1 : 0
                state.update { $0.activeSearchCount = count }
            }
            writerEnded.raise()
        }
        let canceller = Thread {
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                // The stream is made here, so no pool thread ever takes the state lock: after a deadlock the test's own
                // wait below still resumes and fails at its bound.
                let updates = state.updates()
                let subscriber = Task.detached { for await _ in updates {} }
                for _ in 0..<Int.random(in: 0...64) { sched_yield() }
                subscriber.cancel()
            }
            cancellerEnded.raise()
        }
        writer.start()
        canceller.start()

        let deadline = ContinuousClock.now + .seconds(30)
        while !cancellerEnded.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        stop.raise()
        while !writerEnded.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cancellerEnded.value, "cancelling subscribers stalled behind a writer")
        #expect(writerEnded.value, "the writer stalled behind a cancelled subscriber")
    }
}
