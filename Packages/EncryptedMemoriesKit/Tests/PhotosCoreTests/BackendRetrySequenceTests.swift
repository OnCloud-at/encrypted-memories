import XCTest

@testable import PhotosCore

@MainActor
final class BackendRetrySequenceTests: XCTestCase {
    /// Records the steps of the retries and holds each shutdown of the earlier backend until the test releases it.
    @MainActor private final class Recorder {
        var events: [String] = []
        var holdsRetire = true
        private var retireGates: [CheckedContinuation<Void, Never>] = []

        var isRetiring: Bool { !retireGates.isEmpty }

        func retire() async {
            events.append("retire begins")
            if holdsRetire { await withCheckedContinuation { retireGates.append($0) } }
            events.append("retire ends")
        }

        /// Releases every held shutdown, so a test never waits for a retry that a defect left blocked.
        func releaseRetire() {
            retireGates.forEach { $0.resume() }
            retireGates = []
        }
    }

    /// Yields until `condition` holds, for at most five seconds, so a missing event fails instead of hanging.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "the condition did not become true", file: file, line: line)
    }

    func testTheNextBackendStartsOnlyAfterTheEarlierOneShutDown() async {
        let sequence = BackendRetrySequence()
        let recorder = Recorder()
        Task {
            await sequence.run(retire: { await recorder.retire() }, start: { recorder.events.append("start") })
            recorder.events.append("returns")
        }
        await waitUntil { recorder.isRetiring }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.events, ["retire begins"], "nothing starts while the earlier backend shuts down")
        XCTAssertNotNil(sequence.current)

        recorder.releaseRetire()
        await waitUntil { recorder.events.contains("returns") }

        XCTAssertEqual(recorder.events, ["retire begins", "retire ends", "start", "returns"])
        XCTAssertNil(sequence.current)
    }

    func testARetryDuringAShutdownStartsNoSecondBackend() async {
        let sequence = BackendRetrySequence()
        let recorder = Recorder()
        Task {
            await sequence.run(retire: { await recorder.retire() }, start: { recorder.events.append("start") })
            recorder.events.append("first returns")
        }
        await waitUntil { recorder.isRetiring }
        Task {
            await sequence.run(
                retire: { await recorder.retire() }, start: { recorder.events.append("second start") })
            recorder.events.append("second returns")
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.events, ["retire begins"], "the second retry waits for the running one")

        recorder.releaseRetire()
        await waitUntil { recorder.events.contains("first returns") && recorder.events.contains("second returns") }

        XCTAssertEqual(
            recorder.events.filter { !$0.hasSuffix("returns") }, ["retire begins", "retire ends", "start"],
            "one shutdown and one start")
    }

    func testACancelledRetryStartsNoBackend() async {
        let sequence = BackendRetrySequence()
        let recorder = Recorder()
        Task {
            await sequence.run(retire: { await recorder.retire() }, start: { recorder.events.append("start") })
            recorder.events.append("returns")
        }
        await waitUntil { recorder.isRetiring }

        let cancelled = sequence.cancel()
        XCTAssertNotNil(cancelled, "a teardown gets the running retry to wait for")
        XCTAssertNil(sequence.current)
        recorder.releaseRetire()
        await waitUntil { recorder.events.contains("returns") }

        XCTAssertEqual(
            recorder.events, ["retire begins", "retire ends", "returns"], "a sign-out during the retry starts nothing")
    }

    func testAFinishedRetryLetsTheNextRetryRun() async {
        let sequence = BackendRetrySequence()
        let recorder = Recorder()
        recorder.holdsRetire = false

        await sequence.run(retire: { await recorder.retire() }, start: { recorder.events.append("start") })
        await sequence.run(retire: { await recorder.retire() }, start: { recorder.events.append("start") })

        XCTAssertEqual(
            recorder.events, ["retire begins", "retire ends", "start", "retire begins", "retire ends", "start"])
        XCTAssertNil(sequence.current)
    }
}
