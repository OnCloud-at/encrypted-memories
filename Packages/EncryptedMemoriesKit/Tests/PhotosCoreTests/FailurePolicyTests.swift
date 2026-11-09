import XCTest

@testable import PhotosCore

final class FailurePolicyTests: XCTestCase {
    func testPolicySeparatesSafeReadsFromMutations() {
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .safeRead).retryPolicy, .automatic)
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .mutation).retryPolicy, .afterReconciliation)
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .safeRead).presentation, .silent)
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .mutation).presentation, .alert)
    }

    func testFixedRestrictionSkipsAndUnknownDoesNotAutoRetry() {
        XCTAssertEqual(FailurePolicy.resolve(.protonRestriction, context: .safeRead).presentation, .silent)
        XCTAssertEqual(FailurePolicy.resolve(.protonRestriction, context: .safeRead).retryPolicy, .never)
        XCTAssertEqual(FailurePolicy.resolve(.unknown, context: .safeRead).retryPolicy, .manual)
        XCTAssertEqual(FailurePolicy.resolve(.unknown, context: .safeRead).presentation, .alert)
    }
    func testBackgroundAndPersonContextsRespectKnownCauses() {
        XCTAssertEqual(FailurePolicy.resolve(.serviceTemporary, context: .background).retryPolicy, .automatic)
        XCTAssertEqual(
            FailurePolicy.resolve(.serviceTemporary, context: .awaitedByPerson).retryPolicy, .afterReconciliation)
        XCTAssertEqual(FailurePolicy.resolve(.authentication, context: .bulkAction).retryPolicy, .afterPersonAction)
        XCTAssertEqual(FailurePolicy.resolve(.sourceTemporarilyUnavailable, context: .background).presentation, .silent)
        XCTAssertEqual(FailurePolicy.resolve(.sourceGone, context: .awaitedByPerson).retryPolicy, .never)
    }
    func testUnknownAndPartialWritesNeedReconciliation() {
        XCTAssertEqual(FailurePolicy.resolve(.unknown, context: .mutation).retryPolicy, .afterReconciliation)
        XCTAssertEqual(
            FailurePolicy.resolve(.partialCompletion, context: .bulkAction).retryPolicy, .afterReconciliation)
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .safeReadExhausted).presentation, .alert)
        XCTAssertEqual(FailurePolicy.resolve(.network, context: .safeReadExhausted).retryPolicy, .manual)
    }
}
