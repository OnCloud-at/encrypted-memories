import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class BackupRetryPolicyTests: XCTestCase {
    func testDelaysGrowExponentiallyAndCap() {
        let policy = BackupRetryPolicy(baseDelay: 1, maxDelay: 900, maxAttempts: 8)
        XCTAssertEqual(policy.delay(afterAttempts: 0), 0)
        XCTAssertEqual(policy.delay(afterAttempts: 1), 1)
        XCTAssertEqual(policy.delay(afterAttempts: 2), 2)
        XCTAssertEqual(policy.delay(afterAttempts: 3), 4)
        XCTAssertEqual(policy.delay(afterAttempts: 10), 512)
        XCTAssertEqual(policy.delay(afterAttempts: 11), 900, "the cap must clamp the exponential")
        XCTAssertEqual(policy.delay(afterAttempts: 1000), 900, "huge attempt counts must not overflow")
    }

    func testParkThreshold() {
        let policy = BackupRetryPolicy(baseDelay: 1, maxDelay: 900, maxAttempts: 3)
        XCTAssertFalse(policy.shouldPark(attempts: 2))
        XCTAssertTrue(policy.shouldPark(attempts: 3))
        XCTAssertTrue(policy.shouldPark(attempts: 4))
    }

    func testDefensiveBounds() {
        let policy = BackupRetryPolicy(baseDelay: -5, maxDelay: -10, maxAttempts: 0)
        XCTAssertEqual(policy.baseDelay, 0)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
        XCTAssertEqual(policy.maxAttempts, 1)
    }
}

final class BackupAutomaticRetryPlannerTests: XCTestCase {
    private let policy = BackupRetryPolicy(baseDelay: 1, maxDelay: 900, maxAttempts: 8)
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNoOutstandingWorkSchedulesNothing() {
        XCTAssertNil(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: 0, queueDate: now, consecutiveNoProgressRuns: 10,
                now: now, retryPolicy: policy
            ))
    }

    func testPastEligibilityCannotCreateAnEmptyRunHotLoop() {
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: 1,
                queueDate: now.addingTimeInterval(-1),
                consecutiveNoProgressRuns: 1,
                now: now,
                retryPolicy: policy
            ), now.addingTimeInterval(30))
    }

    func testFutureQueueEligibilityWinsEvenWhenSoonerThanFallback() {
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: 1,
                queueDate: now.addingTimeInterval(120),
                consecutiveNoProgressRuns: 1,
                now: now,
                retryPolicy: policy
            ), now.addingTimeInterval(120))
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: 1,
                queueDate: now.addingTimeInterval(10),
                consecutiveNoProgressRuns: 8,
                now: now,
                retryPolicy: policy
            ), now.addingTimeInterval(10), "opening or tapping retry must never postpone persisted eligibility")
    }

    func testMissingEligibilityUsesGrowingFallback() {
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: 1,
                queueDate: nil,
                consecutiveNoProgressRuns: 8,
                now: now,
                retryPolicy: policy
            ), now.addingTimeInterval(128))
    }
}

final class BackupThrottlePolicyTests: XCTestCase {
    func testConcurrencyTable() {
        let policy = BackupThrottlePolicy(baseConcurrency: 2)

        XCTAssertEqual(policy.maxConcurrentItems(for: .unconstrained), 2)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .fair)), 2)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isLowPowerMode: true)), 1)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isNetworkConstrained: true)), 1)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isNetworkExpensive: true)), 1)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isNetworkAvailable: false)), 0)
    }

    func testThermalPressureKeepsProgressButReducesConcurrentHeavyWork() {
        let policy = BackupThrottlePolicy(baseConcurrency: 6)

        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .nominal)), 6)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .fair)), 6)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .serious)), 2)
        XCTAssertEqual(
            policy.maxConcurrentItems(for: .init(thermalLevel: .critical)), 1,
            "critical thermal still makes forward progress without six concurrent exports")
    }

    func testBaseConcurrencyIsAtLeastOne() {
        XCTAssertEqual(BackupThrottlePolicy(baseConcurrency: 0).maxConcurrentItems(for: .unconstrained), 1)
    }
}

final class LibraryWorkloadGovernorPolicyTests: XCTestCase {
    func testVisibleMediaKeepsFullBudgetAtEveryThermalLevel() {
        let policy = LibraryWorkloadGovernorPolicy()

        for thermalLevel in [
            LibraryThermalLevel.nominal,
            .fair,
            .serious,
            .critical,
        ] {
            let budget = policy.budget(
                for: .visibleMedia,
                signals: LibraryWorkloadSignals(thermalLevel: thermalLevel),
                baseConcurrency: 6
            )
            XCTAssertEqual(budget.maxConcurrentItems, 6)
            XCTAssertFalse(budget.shouldYield)
        }
    }

    func testSemanticIndexingContinuesAtSeriousButYieldsForForegroundAndCriticalPressure() {
        let policy = LibraryWorkloadGovernorPolicy()

        let serious = policy.budget(
            for: .backgroundSemanticIndexing,
            signals: LibraryWorkloadSignals(thermalLevel: .serious)
        )
        XCTAssertEqual(serious.maxConcurrentItems, 1)
        XCTAssertFalse(serious.shouldYield)

        XCTAssertTrue(
            policy.budget(
                for: .backgroundSemanticIndexing,
                signals: LibraryWorkloadSignals(thermalLevel: .serious, hasVisibleMediaDemand: true)
            ).shouldYield)
        XCTAssertTrue(
            policy.budget(
                for: .backgroundSemanticIndexing,
                signals: LibraryWorkloadSignals(thermalLevel: .serious, isLowPowerMode: true)
            ).shouldYield)
        XCTAssertTrue(
            policy.budget(
                for: .backgroundSemanticIndexing,
                signals: LibraryWorkloadSignals(thermalLevel: .critical)
            ).shouldYield)
    }

    func testBackupBudgetMatchesExistingThrottleContract() {
        let policy = LibraryWorkloadGovernorPolicy()

        XCTAssertEqual(policy.budget(for: .userInitiatedBackup, baseConcurrency: 2).maxConcurrentItems, 2)
        XCTAssertEqual(
            policy.budget(
                for: .userInitiatedBackup,
                signals: LibraryWorkloadSignals(thermalLevel: .serious),
                baseConcurrency: 6
            ).maxConcurrentItems, 2)
        XCTAssertEqual(
            policy.budget(
                for: .userInitiatedBackup,
                signals: LibraryWorkloadSignals(thermalLevel: .critical),
                baseConcurrency: 6
            ).maxConcurrentItems, 1)
    }

    func testBackgroundLocationYieldsToVisibleMediaAndActiveTransfers() {
        let policy = LibraryWorkloadGovernorPolicy()

        XCTAssertFalse(policy.budget(for: .backgroundLocationCrawl).shouldYield)
        XCTAssertTrue(
            policy.budget(
                for: .backgroundLocationCrawl,
                signals: LibraryWorkloadSignals(hasVisibleMediaDemand: true)
            ).shouldYield)
        XCTAssertTrue(
            policy.budget(
                for: .backgroundLocationCrawl,
                signals: LibraryWorkloadSignals(hasActiveUserInitiatedTransfer: true)
            ).shouldYield)
    }
}
