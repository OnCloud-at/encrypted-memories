import Foundation
import XCTest

@testable import PhotosCore

/// The first full remote index build and the timeline metadata pass both read the whole library. The pass waits for
/// the build, but never longer than the gate's limits.
final class TimelineMetadataStartGateTests: XCTestCase {
    private let inventory = TimelineMetadataReconciliation.Inventory(
        items: [
            PhotoItem(
                uid: PhotoUID(volumeID: "library", nodeID: "0001"), captureTime: Date(timeIntervalSince1970: 500),
                mediaType: "image/jpeg")
        ], classifiedNodeIDs: [], libraryID: "library")

    func testThePassStartsOnlyAfterTheBuildEnds() async {
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let events = StartGateEvents()
        let started = expectation(description: "pass started")
        gate.buildStarted()
        reconciliation.schedule(inventory) { _ in
            await events.append("pass")
            started.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(300))
        await events.append("build ended")
        gate.open()
        await fulfillment(of: [started], timeout: 10)
        let log = await events.entries
        XCTAssertEqual(log, ["build ended", "pass"])
        reconciliation.retire()
        await reconciliation.waitForCurrentPass()
    }

    func testABuildThatDoesNotStartReleasesThePassAfterTheStartLimit() async {
        let elapsed = await elapsedUntilThePassStarts(
            gate: TimelineMetadataStartGate(startLimit: .milliseconds(300), limit: .seconds(60)))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .seconds(10), "the start limit must release the pass")
    }

    func testARunningBuildHoldsThePassAtMostForTheLimit() async {
        let gate = TimelineMetadataStartGate(startLimit: .seconds(2), limit: .seconds(3))
        gate.buildStarted()
        let elapsed = await elapsedUntilThePassStarts(gate: gate)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(3), "a started build is not bound by the start limit")
        XCTAssertLessThan(elapsed, .milliseconds(4_500), "the pass must not wait longer than the limit")
    }

    func testAnOpenGateStartsThePassAsBefore() async {
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
        gate.open()
        let elapsed = await elapsedUntilThePassStarts(gate: gate)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    func testRetirementEndsAHeldPassWithoutRunningIt() async {
        let gate = TimelineMetadataStartGate(startLimit: .seconds(60), limit: .seconds(60))
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let events = StartGateEvents()
        reconciliation.schedule(inventory) { _ in await events.append("pass") }
        try? await Task.sleep(for: .milliseconds(100))
        reconciliation.retire()
        let joined = expectation(description: "shutdown joined the held pass")
        let join = Task {
            await reconciliation.waitForCurrentPass()
            joined.fulfill()
        }
        await fulfillment(of: [joined], timeout: 5)
        join.cancel()
        let log = await events.entries
        XCTAssertEqual(log, [])
    }

    private func elapsedUntilThePassStarts(gate: TimelineMetadataStartGate) async -> Duration {
        let reconciliation = TimelineMetadataReconciliation(startGate: gate)
        let clock = ContinuousClock()
        let begin = clock.now
        let events = StartGateEvents()
        let started = expectation(description: "pass started")
        reconciliation.schedule(inventory) { _ in
            await events.record(clock.now - begin)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 15)
        // A pass that is still held must not outlive the test.
        reconciliation.retire()
        await reconciliation.waitForCurrentPass()
        return await events.elapsed ?? .seconds(1_000_000)
    }
}

private actor StartGateEvents {
    private(set) var entries: [String] = []
    private(set) var elapsed: Duration?
    func append(_ entry: String) { entries.append(entry) }
    func record(_ value: Duration) { elapsed = value }
}
