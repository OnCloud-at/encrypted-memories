import XCTest

@testable import PhotosCore

@MainActor
final class AccountTeardownCoordinatorTests: XCTestCase {
    private enum ExpectedFailure: Error {
        case failed
    }

    private final class Recorder {
        var values: [String] = []
    }

    func testRunsOwnersInStageAndRegistrationOrder() async throws {
        let recorder = Recorder()
        let coordinator = try AccountTeardownCoordinator(owners: [
            owner("purge", stage: .purgeClaims, recorder: recorder),
            owner("photo", stage: .photoBackup, recorder: recorder),
            owner("platform-b", stage: .platformTasks, recorder: recorder),
            owner("platform-a", stage: .platformTasks, recorder: recorder),
            owner("logs", stage: .logs, recorder: recorder),
        ])

        let report = await coordinator.teardown()

        XCTAssertEqual(recorder.values, ["platform-b", "platform-a", "photo", "logs", "purge"])
        XCTAssertEqual(report.completedOwnerIDs, recorder.values)
        XCTAssertTrue(report.succeeded)
    }

    func testDuplicateOwnerIDIsRejected() {
        XCTAssertThrowsError(
            try AccountTeardownCoordinator(owners: [
                AccountTeardownOwner(id: "same", stage: .photoBackup) {},
                AccountTeardownOwner(id: "same", stage: .facade) {},
            ])
        ) { error in
            XCTAssertEqual(
                error as? AccountTeardownConfigurationError,
                .duplicateOwnerID("same")
            )
        }
    }

    func testFailureDoesNotPreventLaterOwners() async throws {
        let recorder = Recorder()
        let coordinator = try AccountTeardownCoordinator(owners: [
            AccountTeardownOwner(id: "smart", stage: .smartSearch) {
                recorder.values.append("smart")
                throw ExpectedFailure.failed
            },
            AccountTeardownOwner(id: "facade", stage: .facade) {
                recorder.values.append("facade")
            },
            AccountTeardownOwner(id: "purge", stage: .purgeClaims) {
                recorder.values.append("purge")
            },
        ])

        let report = await coordinator.teardown()

        XCTAssertEqual(recorder.values, ["smart", "facade", "purge"])
        XCTAssertEqual(report.completedOwnerIDs, ["facade", "purge"])
        XCTAssertEqual(
            report.failures,
            [
                AccountTeardownFailure(ownerID: "smart", stage: .smartSearch)
            ])
    }

    func testConcurrentAndRepeatedCallsShareOneExecution() async throws {
        var executionCount = 0
        let coordinator = try AccountTeardownCoordinator(owners: [
            AccountTeardownOwner(id: "owner", stage: .platformTasks) {
                executionCount += 1
                await Task.yield()
            }
        ])

        async let first = coordinator.teardown()
        async let second = coordinator.teardown()
        let reports = await [first, second]
        let third = await coordinator.teardown()

        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(reports[0], reports[1])
        XCTAssertEqual(reports[0], third)
    }

    private func owner(
        _ id: String,
        stage: AccountTeardownStage,
        recorder: Recorder
    ) -> AccountTeardownOwner {
        AccountTeardownOwner(id: id, stage: stage) {
            recorder.values.append(id)
        }
    }
}
