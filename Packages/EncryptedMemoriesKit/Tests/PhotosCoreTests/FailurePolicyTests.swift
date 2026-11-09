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
        XCTAssertGreaterThan(FailureCause.allCases.count, 0)
        XCTAssertEqual(FailureSituation.allCases.count, 3)
        XCTAssertEqual(FailureOperationSafety.allCases.count, 2)
        for cause in FailureCause.allCases {
            for situation in FailureSituation.allCases {
                for safety in FailureOperationSafety.allCases {
                    for exhausted in [false, true] {
                        let policy = FailurePolicy.resolve(
                            cause, situation: situation, safety: safety, retriesExhausted: exhausted)
                        if cause == .partialCompletion {
                            XCTAssertEqual(policy.retry, .afterReconciliation)
                            XCTAssertEqual(policy.presentation, .alert)
                        }
                        if cause == .cancelled && safety == .mutation {
                            XCTAssertEqual(policy.retry, .afterReconciliation)
                            XCTAssertEqual(policy.presentation, .alert)
                        }
                        if cause == .permanent {
                            XCTAssertEqual(policy.retry, .never)
                            XCTAssertEqual(policy.presentation, .alert)
                        }
                        if cause == .protonRestriction {
                            XCTAssertEqual(policy.retry, .never)
                            XCTAssertEqual(policy.presentation, .silent)
                        }
                    }
                }
            }
        }
    }
}
