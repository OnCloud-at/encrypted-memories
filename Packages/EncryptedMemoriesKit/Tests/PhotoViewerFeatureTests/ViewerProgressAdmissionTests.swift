import Foundation
import PhotoViewerCore
import XCTest

final class ViewerProgressAdmissionTests: XCTestCase {
    func testTenThousandCallbacksAdmitAtMostOnePercentSteps() {
        let gate = ViewerProgressAdmission()
        let samples = (0...10_000).compactMap { gate.admit(Double($0) / 10_000) }

        XCTAssertLessThanOrEqual(samples.count, 101)
        XCTAssertEqual(samples.first?.fraction, 0)
        XCTAssertEqual(samples.last?.fraction, 1)
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0.step < $1.step })
    }

    func testRejectsNonFiniteValuesAndClampsFiniteEndpoints() {
        XCTAssertNil(ViewerProgressAdmission().admit(.nan))
        XCTAssertNil(ViewerProgressAdmission().admit(.infinity))
        XCTAssertNil(ViewerProgressAdmission().admit(-.infinity))
        XCTAssertEqual(ViewerProgressAdmission().admit(-1)?.fraction, 0)
        XCTAssertEqual(ViewerProgressAdmission().admit(2)?.fraction, 1)
    }

    func testOnlyNewestAdmittedSampleMayBePublished() throws {
        let gate = ViewerProgressAdmission()
        let old = try XCTUnwrap(gate.admit(0))
        let newest = try XCTUnwrap(gate.admit(0.5))
        XCTAssertNil(gate.admit(0.5))
        XCTAssertNil(gate.admit(0.4))
        var published: [Double] = []

        for sample in [newest, old] where gate.isCurrent(sample) {
            published.append(sample.fraction)
        }

        XCTAssertEqual(published, [0.5])
        XCTAssertFalse(gate.isCurrent(old))
    }

    func testCloseRejectsLateAdmissionAndQueuedPublication() throws {
        let gate = ViewerProgressAdmission()
        let queued = try XCTUnwrap(gate.admit(0))

        gate.close()

        XCTAssertNil(gate.admit(1))
        XCTAssertFalse(gate.isCurrent(queued))
    }

    func testSampleCannotBePublishedThroughAnotherLoadOwner() throws {
        let first = ViewerProgressAdmission()
        let second = ViewerProgressAdmission()
        let firstSample = try XCTUnwrap(first.admit(0.5))
        let secondSample = try XCTUnwrap(second.admit(0.5))

        XCTAssertTrue(first.isCurrent(firstSample))
        XCTAssertTrue(second.isCurrent(secondSample))
        XCTAssertFalse(first.isCurrent(secondSample))
        XCTAssertFalse(second.isCurrent(firstSample))
    }

    func testConcurrentCallbacksKeepAdmissionBoundedAndNewestSampleCurrent() throws {
        let gate = ViewerProgressAdmission()
        final class Samples: @unchecked Sendable {
            let lock = NSLock()
            var values: [ViewerProgressAdmission.Sample] = []
            func append(_ value: ViewerProgressAdmission.Sample) {
                lock.withLock { values.append(value) }
            }
        }
        let samples = Samples()
        DispatchQueue.concurrentPerform(iterations: 10_001) { index in
            if let sample = gate.admit(Double(index) / 10_000) { samples.append(sample) }
        }
        let values = samples.lock.withLock { samples.values }
        XCTAssertLessThanOrEqual(values.count, 101)
        XCTAssertEqual(Set(values.map(\.step)).count, values.count)
        let newest = try XCTUnwrap(values.max { $0.step < $1.step })
        XCTAssertEqual(newest.fraction, 1)
        XCTAssertTrue(gate.isCurrent(newest))
        XCTAssertEqual(values.filter { gate.isCurrent($0) }.count, 1)
    }

    func testEachLoadGateHasIndependentAdmissionState() throws {
        let first = ViewerProgressAdmission()
        let second = ViewerProgressAdmission()

        XCTAssertEqual(try XCTUnwrap(first.admit(0)).step, 0)
        XCTAssertEqual(try XCTUnwrap(second.admit(0)).step, 0)

        first.close()
        XCTAssertNil(first.admit(1))
        XCTAssertEqual(try XCTUnwrap(second.admit(1)).step, 100)
    }
}
