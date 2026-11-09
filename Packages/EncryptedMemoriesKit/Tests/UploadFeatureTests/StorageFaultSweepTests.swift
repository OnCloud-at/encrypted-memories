import Foundation
import XCTest

/// Runs the fault-injection sweep over every registered storage operation (#1141), and proves with deliberately flawed
/// probe operations that each fixed rule catches its class of defect.
final class StorageFaultSweepTests: XCTestCase {
    /// One assertion over all cases, so a failing case never hides behind an earlier one in the test log.
    func testEveryRegisteredOperationKeepsTheRulesAtEveryStatement() async throws {
        XCTAssertFalse(storageFaultCases.isEmpty)
        let findings = try await sweepFindings(storageFaultCases)
        XCTAssertTrue(findings.isEmpty, "\n" + findings.joined(separator: "\n"))
    }

    func testACaseThatCannotCompleteDoesNotHideTheOthers() async throws {
        let findings = try await sweepFindings([
            ProbeCase(flaw: .failsWithoutAFault), ProbeCase(flaw: .deleteBeforeReplace),
        ])
        XCTAssertEqual(findings.count, 2, findings.joined(separator: "\n"))
        XCTAssertTrue(findings.first?.hasPrefix("probe.failsWithoutAFault did not complete: ") ?? false)
        XCTAssertTrue(findings.last?.hasPrefix("probe.deleteBeforeReplace violates the rules:") ?? false)
    }

    /// Sweeps every case. A case whose sweep throws becomes a finding and never stops the cases after it.
    private func sweepFindings(_ cases: [any StorageFaultCase]) async throws -> [String] {
        var findings: [String] = []
        for faultCase in cases {
            do {
                let report = try await StorageFaultSweep.run(faultCase)
                print(
                    "storage-fault-sweep \(faultCase.id): \(report.statements.count) statements, "
                        + String(format: "%.2f s", report.seconds))
                if report.statements.isEmpty { findings.append("\(faultCase.id) runs no statement on its stores") }
                if !report.violations.isEmpty {
                    findings.append(
                        "\(faultCase.id) violates the rules:\n"
                            + report.violations.map(\.description).joined(separator: "\n"))
                }
            } catch {
                findings.append("\(faultCase.id) did not complete: \(error)")
            }
        }
        return findings
    }

    func testACorrectOperationKeepsEveryRule() async throws {
        try await assertSweep(of: .correct, violates: [:])
    }

    func testTwoTransactionsForOneChangeBreakAllOrNothing() async throws {
        try await assertSweep(of: .splitTransaction, violates: [.allOrNothing: [.failedRun, .crashImage]])
    }

    func testACompensationThatACrashSkipsLeavesAHalfWrittenCrashImage() async throws {
        try await assertSweep(of: .compensatesWhileRunning, violates: [.allOrNothing: [.crashImage]])
    }

    func testDeletingBeforeTheReplacementLosesARecord() async throws {
        try await assertSweep(of: .deleteBeforeReplace, violates: [.noLoss: [.failedRun, .crashImage]])
    }

    func testUploadingWithoutCheckingTheReceiptUploadsTwice() async throws {
        try await assertSweep(
            of: .uploadWithoutReceiptCheck,
            violates: [.noDuplicateUpload: [.restartAfterFailure, .restartFromCrashImage]])
    }

    func testAnOperationThatIsNotIdempotentDoesNotConverge() async throws {
        try await assertSweep(
            of: .notIdempotent, violates: [.restartConverges: [.restartAfterFailure, .restartFromCrashImage]])
    }

    func testAnOperationThatFailsWhenItsWorkIsDoneDoesNotConverge() async throws {
        try await assertSweep(
            of: .failsWhenAlreadyDone, violates: [.restartConverges: [.restartAfterFailure, .restartFromCrashImage]])
    }

    func testAnIgnoredFailureIsNoSuccess() async throws {
        try await assertSweep(of: .ignoresFailure, violates: [.honestOutcome: [.failedRun]])
    }

    func testARunThatEndsBeforeItsLastStatementFailsTheSweep() async throws {
        try await assertSweep(of: .changesItsStatements, violates: [.faultDidNotFire: [.failedRun]])
    }

    func testAStatementOrderThatChangesBetweenRunsFailsTheSweep() async throws {
        try await assertSweep(of: .reordersItsStatements, violates: [.faultHitAnotherStatement: [.failedRun]])
    }

    func testAStoreThatCannotOpenTheWALOfAKilledProcessDoesNotConverge() async throws {
        try await assertSweep(of: .cannotOpenAfterCrash, violates: [.restartConverges: [.restartFromCrashImage]])
    }

    func testAnItemWrittenBeforeItsQueueRowIsNeverQueuedAfterACrash() async throws {
        try await assertSweep(
            of: .marksDoneBeforeQueueing,
            violates: [.restartConverges: [.restartAfterFailure, .restartFromCrashImage]])
    }

    private func assertSweep(
        of flaw: ProbeCase.Flaw, violates expected: [StorageFaultRule: [StorageFaultPhase]],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let report = try await StorageFaultSweep.run(ProbeCase(flaw: flaw))
        XCTAssertGreaterThan(report.statements.count, 0, "the probe runs statements", file: file, line: line)
        let checks = expected.flatMap { rule, phases in phases.map { "\(rule.rawValue), \($0.rawValue)" } }
        XCTAssertEqual(
            report.violatedChecks, Set(checks), report.violations.map(\.description).joined(separator: "\n"),
            file: file, line: line)
    }
}

/// Probe operations on two `StorageFaultTable` stores, `item` and `queue`. Each flaw except `correct` violates exactly
/// one rule of the sweep.
private struct ProbeCase: StorageFaultCase {
    enum Flaw {
        /// One transaction that is safe to run again.
        case correct
        /// One change written in two transactions.
        case splitTransaction
        /// Two transactions that undo the first one when the second fails, which a crash skips.
        case compensatesWhileRunning
        /// A replacement that deletes the old record first, in its own transaction.
        case deleteBeforeReplace
        /// An upload that does not look for the receipt of an earlier upload.
        case uploadWithoutReceiptCheck
        /// A counter that a second run increments again.
        case notIdempotent
        /// An insert that fails when its row already exists.
        case failsWhenAlreadyDone
        /// An operation that reports success after a failed write.
        case ignoresFailure
        /// An operation whose first run ends with a read that later runs leave out.
        case changesItsStatements
        /// An operation whose later runs write the same two rows in the opposite order.
        case reordersItsStatements
        /// A store that refuses to open while the WAL of a killed process holds frames.
        case cannotOpenAfterCrash
        /// An operation that reports failure even without a fault, so its sweep cannot run.
        case failsWithoutAFault
        /// An item written before its queue row, while a later run queues only items that it adds (#352).
        case marksDoneBeforeQueueing
    }

    struct World {
        let store: StorageFaultTable
        let queue: StorageFaultTable
        let remote: StorageFaultRemote
    }

    let flaw: Flaw
    private let runs = RunCounter()
    var id: String { "probe.\(flaw)" }
    var atomicity: StorageFaultAtomicity {
        switch flaw {
        case .correct, .splitTransaction, .compensatesWhileRunning, .ignoresFailure: return .allOrNothing
        case .deleteBeforeReplace, .uploadWithoutReceiptCheck, .notIdempotent, .failsWhenAlreadyDone,
            .changesItsStatements, .reordersItsStatements, .cannotOpenAfterCrash, .marksDoneBeforeQueueing,
            .failsWithoutAFault:
            return .convergesAfterRestart
        }
    }

    func seed(in directory: URL, remote: StorageFaultRemote) async throws {
        let world = try open(directory, remote: remote)
        defer { close(world) }
        XCTAssertTrue(world.store.execute("INSERT INTO item VALUES('a','1'),('b','1');"))
    }

    func open(_ directory: URL, remote: StorageFaultRemote) throws -> World {
        let wal = directory.appendingPathComponent("item.sqlite-wal")
        // A WAL holds frames once it is longer than its 32-byte header.
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        if flaw == .cannotOpenAfterCrash, walSize > 32 {
            throw StorageFaultSweepError("the probe store does not open an unrecovered WAL")
        }
        return World(
            store: try StorageFaultTable(url: directory.appendingPathComponent("item.sqlite")),
            queue: try StorageFaultTable(url: directory.appendingPathComponent("queue.sqlite")), remote: remote)
    }

    func faultTargets(of world: World) -> [Any] { [world.store, world.queue] }

    func run(_ world: World) async -> Bool {
        let store = world.store
        switch flaw {
        case .correct:
            return store.execute(
                "BEGIN IMMEDIATE; UPDATE item SET value='2' WHERE key='a'; "
                    + "INSERT OR REPLACE INTO item VALUES('c','2'); COMMIT;")
        case .splitTransaction:
            return store.execute("UPDATE item SET value='2' WHERE key='a';")
                && store.execute("UPDATE item SET value='2' WHERE key='b';")
        case .compensatesWhileRunning:
            guard store.execute("UPDATE item SET value='2' WHERE key='a';") else { return false }
            guard store.execute("UPDATE item SET value='2' WHERE key='b';") else {
                store.execute("UPDATE item SET value='1' WHERE key='a';")
                return false
            }
            return true
        case .deleteBeforeReplace:
            return store.execute("DELETE FROM item WHERE key='a';")
                && store.execute("INSERT INTO item VALUES('a','2');")
        case .uploadWithoutReceiptCheck:
            world.remote.recordUpload("a")
            return store.execute("INSERT OR REPLACE INTO item VALUES('receipt','a');")
        case .notIdempotent:
            return store.execute("UPDATE item SET value=value||'+' WHERE key='a';")
                && store.execute("UPDATE item SET value='2' WHERE key='b';")
        case .failsWhenAlreadyDone:
            return store.execute("INSERT INTO item VALUES('c','2');") && store.execute("SELECT count(*) FROM item;")
        case .ignoresFailure:
            store.execute("BEGIN IMMEDIATE; UPDATE item SET value='2'; COMMIT;")
            return true
        case .changesItsStatements:
            let first = runs.next() == 0
            return store.execute("UPDATE item SET value='2' WHERE key='a';")
                && store.execute("UPDATE item SET value='2' WHERE key='b';")
                && (!first || store.execute("SELECT count(*) FROM item;"))
        case .reordersItsStatements:
            let order = runs.next() == 0 ? ["a", "b"] : ["b", "a"]
            return order.allSatisfy { store.execute("UPDATE item SET value='2' WHERE key='\($0)';") }
        case .cannotOpenAfterCrash:
            return store.execute("UPDATE item SET value='2' WHERE key='a';")
                && store.execute("UPDATE item SET value='2' WHERE key='b';")
        case .failsWithoutAFault:
            return false
        case .marksDoneBeforeQueueing:
            guard let added = store.insertIfAbsent("c", value: "2") else { return false }
            return !added || world.queue.insertIfAbsent("c") != nil
        }
    }

    func close(_ world: World) {
        world.store.close()
        world.queue.close()
    }

    func state(in directory: URL) throws -> StorageFaultState {
        var state = StorageFaultState()
        for name in ["item", "queue"] {
            let url = directory.appendingPathComponent("\(name).sqlite")
            try state.addSQLiteTables(of: url)
            try state.addRecords(name, of: url, sql: "SELECT key FROM item;")
        }
        return state
    }
}

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The number of earlier runs.
    func next() -> Int {
        lock.withLock {
            defer { count += 1 }
            return count
        }
    }
}
