import XCTest

@testable import PhotosCore

final class LibraryStoragePressureTests: XCTestCase {
    func testThresholdsAndHysteresis() {
        let gib: Int64 = 1 << 30
        let mib: Int64 = 1 << 20

        XCTAssertEqual(LibraryStoragePressure.next(after: .normal, availableBytes: 2 * gib), .normal)
        XCTAssertEqual(LibraryStoragePressure.next(after: .normal, availableBytes: 2 * gib - 1), .low)
        XCTAssertEqual(LibraryStoragePressure.next(after: .normal, availableBytes: 512 * mib - 1), .critical)
        XCTAssertEqual(LibraryStoragePressure.next(after: .low, availableBytes: 2 * gib + 256 * mib - 1), .low)
        XCTAssertEqual(LibraryStoragePressure.next(after: .low, availableBytes: 2 * gib + 256 * mib), .normal)
        XCTAssertEqual(
            LibraryStoragePressure.next(after: .critical, availableBytes: 512 * mib + 256 * mib - 1), .critical)
        XCTAssertEqual(LibraryStoragePressure.next(after: .critical, availableBytes: 512 * mib + 256 * mib), .low)
        XCTAssertEqual(LibraryStoragePressure.next(after: .critical, availableBytes: 2 * gib + 256 * mib), .normal)
        XCTAssertEqual(LibraryStoragePressure.next(after: .low, availableBytes: nil), .low)
    }

    func testCriticalPausesAutomaticWritingWorkOnly() {
        let policy = LibraryResourcePolicy()
        let snapshot = LibraryRuntimeSnapshot(storagePressure: .critical)
        for workload: LibraryHeavyWorkload in [.mlIndexing, .videoDerivative] {
            let automatic = LibraryWorkRequest(workload: workload, intent: .automatic)
            let budget = policy.budget(for: automatic, snapshot: snapshot)
            XCTAssertFalse(budget.isAdmitted)
            XCTAssertEqual(budget.reason, .storagePressure)
            XCTAssertTrue(
                policy.budget(
                    for: LibraryWorkRequest(workload: workload, intent: .userInitiated), snapshot: snapshot
                ).isAdmitted)
        }
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .mlInference, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
        // Backup checks free space itself and shows that the device needs storage.
        XCTAssertTrue(
            policy.budget(
                for: LibraryWorkRequest(workload: .backupMaterialization, intent: .automatic), snapshot: snapshot
            ).isAdmitted)
    }

    func testGenerationResetKeepsObservedPressure() {
        let state = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(storagePressure: .critical))
        XCTAssertEqual(state.beginNewGeneration().storagePressure, .critical)
    }

    func testActiveAutomaticWritingLeaseYieldsOnCritical() async throws {
        let state = LibraryRuntimeState()
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        let decision = try await coordinator.withHeavyPermit(
            LibraryWorkRequest(workload: .mlIndexing, intent: .automatic)
        ) { lease in
            state.update { $0.storagePressure = .critical }
            return lease.continuationDecision()
        }
        XCTAssertEqual(decision, .yield(.storagePressure))
    }
}
