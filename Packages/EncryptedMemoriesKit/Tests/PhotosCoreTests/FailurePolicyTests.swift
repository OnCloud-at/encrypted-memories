import XCTest

@testable import PhotosCore

final class FailurePolicyTests: XCTestCase {
    func testSafeReadAndMutationCanBothBeAwaited() {
        let read = FailurePolicy.resolve(.network, situation: .awaitedByPerson, safety: .safeRead)
        XCTAssertEqual(read.retry, .automatic)
        XCTAssertEqual(read.presentation, .silent)
        let write = FailurePolicy.resolve(.network, situation: .awaitedByPerson, safety: .mutation)
        XCTAssertEqual(write.retry, .afterReconciliation)
        XCTAssertEqual(write.presentation, .alert)
        let exhausted = FailurePolicy.resolve(
            .network, situation: .awaitedByPerson, safety: .safeRead, retriesExhausted: true)
        XCTAssertEqual(exhausted.retry, .manual)
        XCTAssertEqual(exhausted.presentation, .alert)
    }

    func testEveryCauseSituationAndSafetyObeysInvariants() {
        typealias Expected = (FailureRetryRule, FailurePresentation)
        let automatic: Expected = (.automatic, .silent)
        let manual: Expected = (.manual, .alert)
        let reconcile: Expected = (.afterReconciliation, .alert)
        let action: Expected = (.afterPersonAction, .alert)
        let never: Expected = (.never, .alert)
        let silent: Expected = (.never, .silent)
        // Columns: read, exhausted read, mutation, exhausted mutation.
        let rows: [(FailureCause, [Expected])] = [
            (.network, [automatic, manual, reconcile, reconcile]),
            (.serviceTemporary, [automatic, manual, reconcile, reconcile]),
            (.localTransient, [automatic, manual, reconcile, reconcile]),
            (.authentication, [action, action, action, action]),
            (.sourceTemporarilyUnavailable, [automatic, manual, reconcile, reconcile]),
            (.sourceGone, [never, never, never, never]),
            (.rateLimited, [automatic, manual, reconcile, reconcile]),
            (.protonRestriction, [never, never, never, never]),
            (.cancelled, [silent, silent, reconcile, reconcile]),
            (.unsupported, [never, never, never, never]),
            (.permanent, [never, never, never, never]),
            (.permission, [action, action, action, action]),
            (.deviceStorage, [action, action, action, action]),
            (.accountStorage, [action, action, action, action]),
            (.localState, [manual, manual, reconcile, reconcile]),
            (.userDecision, [action, action, action, action]),
            (.partialCompletion, [reconcile, reconcile, reconcile, reconcile]),
            (.unknown, [manual, manual, reconcile, reconcile]),
        ]
        XCTAssertEqual(rows.count, FailureCause.allCases.count)
        for cause in FailureCause.allCases {
            XCTAssertEqual(rows.filter { $0.0 == cause }.count, 1, "Missing or duplicate row: \(cause)")
        }
        XCTAssertEqual(FailureSituation.allCases.count, 3)
        XCTAssertEqual(FailureOperationSafety.allCases.count, 2)
        var failures: [String] = []
        for (cause, expected) in rows {
            for situation in FailureSituation.allCases {
                for (index, safety) in [FailureOperationSafety.safeRead, .mutation].enumerated() {
                    for exhausted in [false, true] {
                        let actual = FailurePolicy.resolve(
                            cause, situation: situation, safety: safety, retriesExhausted: exhausted)
                        let cell = cause == .protonRestriction && situation == .background
                            ? silent : expected[index * 2 + (exhausted ? 1 : 0)]
                        if actual.retry != cell.0 || actual.presentation != cell.1 {
                            failures.append("\(cause), \(situation), \(safety), exhausted=\(exhausted): \(actual)")
                        }
                        if exhausted && actual.retry == .automatic {
                            failures.append("Automatic retry after exhaustion: \(cause), \(situation), \(safety)")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
