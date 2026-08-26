import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class PhotoLibraryBackupControllerStateTests: XCTestCase {
    func testRunnerStopIsRetainedDeduplicatedAndBlocksCompletion() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-runner-stop")
        defer { fixture.cleanup() }
        let stop = DelayedRunnerStop()
        fixture.controller.installRunnerStopOperationForTesting {
            await stop.stop()
        }
        let orchestration = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        XCTAssertTrue(
            fixture.controller.installSyncRunForTesting(runID: "run", task: orchestration))

        fixture.controller.stopSync()
        fixture.controller.stopSync()
        await stop.waitUntilStarted()

        let stopCalls = await stop.callCount()
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(fixture.controller.runnerStopRunIDForTesting, "run")
        XCTAssertTrue(fixture.controller.isRunnerStopPendingForTesting)

        let finishTask = Task { @MainActor in
            await fixture.controller.finishSyncForTesting(runID: "run")
        }
        await Task.yield()
        XCTAssertTrue(fixture.controller.isSyncing)
        XCTAssertTrue(fixture.controller.isRunnerStopPendingForTesting)

        await stop.release()
        await finishTask.value
        await orchestration.value

        XCTAssertFalse(fixture.controller.isSyncing)
        XCTAssertFalse(fixture.controller.isRunnerStopPendingForTesting)
    }

    func testShutdownAwaitsTheExistingRunnerStopTask() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-runner-stop-shutdown")
        defer { fixture.cleanup() }
        let stop = DelayedRunnerStop()
        fixture.controller.installRunnerStopOperationForTesting {
            await stop.stop()
        }
        let orchestration = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        XCTAssertTrue(
            fixture.controller.installSyncRunForTesting(runID: "run", task: orchestration))

        fixture.controller.stopSync()
        await stop.waitUntilStarted()
        let shutdownReturned = CompletionLatch()
        let shutdownTask = Task { @MainActor in
            await fixture.controller.shutdown()
            await shutdownReturned.markCompleted()
        }

        await Task.yield()
        let returnedBeforeRelease = await shutdownReturned.isCompleted()
        XCTAssertFalse(returnedBeforeRelease)
        let stopCalls = await stop.callCount()
        XCTAssertEqual(stopCalls, 1)

        await stop.release()
        await shutdownTask.value
        let returnedAfterRelease = await shutdownReturned.isCompleted()
        XCTAssertTrue(returnedAfterRelease)
        await orchestration.value
    }

    func testRunScopedStopCannotCancelAnotherOwner() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-run-owner")
        defer { fixture.cleanup() }
        let cancellation = CompletionLatch()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            await cancellation.markCompleted()
        }
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))

        fixture.controller.stopSync(runID: "background")
        await Task.yield()
        let cancelledByOtherOwner = await cancellation.isCompleted()
        XCTAssertFalse(cancelledByOtherOwner)

        fixture.controller.stopSync(runID: "foreground")
        await task.value
        let cancelledByOwner = await cancellation.isCompleted()
        XCTAssertTrue(cancelledByOwner)
        await fixture.controller.shutdown()
    }

    func testBackgroundCatchUpDoesNotAdoptAnExistingRun() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-run-stand-down")
        defer { fixture.cleanup() }
        let writer = NonCooperativeWriterLatch()
        let task = makeNonCooperativeWriter(writer)
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))
        await writer.waitUntilStarted()
        await writer.waitUntilBlocked()

        var reportedRunID: String?
        let started = ContinuousClock.now
        await fixture.controller.backgroundCatchUp(owner: .iOSBackgroundTask) { runID in
            reportedRunID = runID
        }
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .milliseconds(250))
        XCTAssertNil(reportedRunID)
        XCTAssertEqual(fixture.controller.activeExecutionRunID, "foreground")
        let adoptedForegroundRun = await writer.isCompleted()
        XCTAssertFalse(adoptedForegroundRun)

        await writer.release()
        await task.value
        await fixture.controller.shutdown()
    }

    func testExpirationTracksEveryConcurrentWriterAndRetiresUntilBothReturn() async throws {
        let suite = "photo-backup-controller-retirement-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        let first = NonCooperativeWriterLatch()
        let second = NonCooperativeWriterLatch()
        let firstTask = makeNonCooperativeWriter(first)
        let secondTask = makeNonCooperativeWriter(second)
        XCTAssertTrue(controller.installInstantWorkTaskForTesting(firstTask))
        XCTAssertTrue(controller.installInstantWorkTaskForTesting(secondTask))

        await first.waitUntilStarted()
        await second.waitUntilStarted()
        await first.waitUntilBlocked()
        await second.waitUntilBlocked()

        let expirationStarted = ContinuousClock.now
        await controller.retireInstantWorkForTesting()
        let expirationDuration = expirationStarted.duration(to: ContinuousClock.now)
        XCTAssertLessThan(
            expirationDuration,
            PhotoLibraryBackupController.instantWorkRetirementTimeout + .milliseconds(500),
            "expiration must return after its bounded wait instead of joining writers"
        )
        XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

        await first.release()
        await firstTask.value
        XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

        await second.release()
        await secondTask.value
        await controller.waitForInstantWorkRetirementForTesting()
        XCTAssertFalse(controller.isRetiringInstantWorkForTesting)
        await controller.shutdown()
    }

    func testRetirementRejectsNewTargetedWriter() async throws {
        let suite = "photo-backup-controller-retirement-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        let writer = NonCooperativeWriterLatch()
        let writerTask = makeNonCooperativeWriter(writer)
        XCTAssertTrue(controller.installInstantWorkTaskForTesting(writerTask))
        await writer.waitUntilStarted()
        await writer.waitUntilBlocked()

        let expiration = Task { @MainActor in
            await controller.retireInstantWorkForTesting()
        }
        while !controller.isRetiringInstantWorkForTesting {
            await Task.yield()
        }

        let rejectedWriter = NonCooperativeWriterLatch()
        XCTAssertFalse(
            controller.startInstantWorkForTesting {
                await rejectedWriter.markStarted()
            },
            "retirement must reject a new targeted writer"
        )
        await Task.yield()
        let rejectedWriterStarted = await rejectedWriter.isStarted()
        XCTAssertFalse(rejectedWriterStarted)

        await expiration.value
        await writer.release()
        await writerTask.value
        await controller.waitForInstantWorkRetirementForTesting()
        XCTAssertFalse(controller.isRetiringInstantWorkForTesting)
        await controller.shutdown()
    }

    func testShutdownJoinsRetirementAndAllTrackedWriters() async throws {
        let suite = "photo-backup-controller-retirement-shutdown-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        let first = NonCooperativeWriterLatch()
        let second = NonCooperativeWriterLatch()
        let firstTask = makeNonCooperativeWriter(first)
        let secondTask = makeNonCooperativeWriter(second)
        XCTAssertTrue(controller.installInstantWorkTaskForTesting(firstTask))
        XCTAssertTrue(controller.installInstantWorkTaskForTesting(secondTask))
        await first.waitUntilStarted()
        await second.waitUntilStarted()
        await first.waitUntilBlocked()
        await second.waitUntilBlocked()
        await controller.retireInstantWorkForTesting()
        XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

        let shutdownReturned = CompletionLatch()
        let shutdownTask = Task { @MainActor in
            await controller.shutdown()
            await shutdownReturned.markCompleted()
        }
        await Task.yield()
        let returnedBeforeFirstRelease = await shutdownReturned.isCompleted()
        XCTAssertFalse(returnedBeforeFirstRelease)

        await first.release()
        await firstTask.value
        await Task.yield()
        let returnedBeforeSecondRelease = await shutdownReturned.isCompleted()
        XCTAssertFalse(returnedBeforeSecondRelease)

        await second.release()
        await secondTask.value
        await shutdownTask.value
        let returnedAfterWriters = await shutdownReturned.isCompleted()
        XCTAssertTrue(returnedAfterWriters)
    }

    func testShutdownDoesNotReturnBeforeNonCooperativeInstantWriterCompletes() async throws {
        let suite = "photo-backup-controller-shutdown-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        let writer = NonCooperativeWriterLatch()
        let writeTask = Task.detached(priority: .utility) {
            await writer.markStarted()
            await writer.waitUntilReleased()
            await writer.markCompleted()
        }
        controller.installInstantWorkTaskForTesting(writeTask)

        let shutdownStarted = CompletionLatch()
        let shutdownReturned = CompletionLatch()
        let shutdownTask = Task { @MainActor in
            await shutdownStarted.markCompleted()
            await controller.shutdown()
            await shutdownReturned.markCompleted()
        }

        await shutdownStarted.waitUntilCompleted()
        await writer.waitUntilStarted()
        await writer.waitUntilBlocked()
        await Task.yield()
        let returnedBeforeRelease = await shutdownReturned.isCompleted()
        XCTAssertFalse(
            returnedBeforeRelease,
            "shutdown must not return while the non-cooperative writer remains blocked"
        )
        await writer.release()
        await writeTask.value
        await shutdownTask.value
        let writerCompleted = await writer.isCompleted()
        let returnedAfterRelease = await shutdownReturned.isCompleted()
        XCTAssertTrue(writerCompleted)
        XCTAssertTrue(returnedAfterRelease)
    }

    func testBackgroundExecutionCompositionReservesDiscoveryAndQueuePhases() throws {
        let catalog = BackupExecutionProgress(completedUnitCount: 50, totalUnitCount: 100)
        let queue = BackupExecutionProgress(completedUnitCount: 20, totalUnitCount: 100)

        let scanOnly = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: catalog,
                queue: nil,
                isScanning: true
            ))
        XCTAssertEqual(scanOnly.completedUnitCount, 125_000)
        XCTAssertEqual(scanOnly.totalUnitCount, 1_000_000)

        let combined = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: catalog,
                queue: queue,
                isScanning: true
            ))
        XCTAssertEqual(combined.completedUnitCount, 275_000)

        let finishedWithoutQueue = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: BackupExecutionProgress(completedUnitCount: 100, totalUnitCount: 100),
                queue: nil,
                isScanning: false
            ))
        XCTAssertEqual(finishedWithoutQueue.completedUnitCount, 1_000_000)
    }

    func testLivePhotoLibraryChangesAreAvailableBeforePersistentHistoryCatchesUp() {
        var buffer = PhotoLibraryLiveChangeBuffer()

        buffer.record(
            changedIdentifiers: ["new", "edited"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        buffer.record(
            changedIdentifiers: [],
            deletedIdentifiers: ["edited"],
            requiresFullRescan: false
        )

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.changedIdentifiers, ["new"])
        XCTAssertEqual(snapshot.deletedIdentifiers, ["edited"])
        XCTAssertFalse(snapshot.requiresFullRescan)
    }

    func testCommittingPreparedLiveChangesKeepsChangesThatArriveDuringTheScan() {
        var buffer = PhotoLibraryLiveChangeBuffer()
        buffer.record(
            changedIdentifiers: ["first"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        let prepared = buffer.snapshot()

        buffer.record(
            changedIdentifiers: ["second"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        buffer.commit(through: prepared.generation)

        let remaining = buffer.snapshot()
        XCTAssertEqual(remaining.changedIdentifiers, ["second"])
        XCTAssertEqual(remaining.deletedIdentifiers, [])
    }

    func testNonIncrementalLivePhotoKitChangeRequiresSafeFullRescan() {
        var buffer = PhotoLibraryLiveChangeBuffer()
        buffer.record(
            changedIdentifiers: [],
            deletedIdentifiers: [],
            requiresFullRescan: true
        )

        XCTAssertTrue(buffer.snapshot().requiresFullRescan)
    }

    func testCatalogReplayPolicyDoesNotResurrectRowsRemovedFromAnExistingQueue() {
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 33_771, catalogCount: 34_104),
            .markCompleted,
            "an older populated queue is complete by write ordering even when stale catalog rows make counts differ"
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .completed, queueCount: 33_771, catalogCount: 34_104),
            .skip,
            "later launches must not resurrect the same stale sources"
        )
    }

    func testCatalogReplayPolicyRebuildsOnlyAResetQueueAndResumesAfterInterruption() {
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 0, catalogCount: 34_104),
            .replay
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .inProgress, queueCount: 500, catalogCount: 34_104),
            .replay,
            "a killed rebuild must continue even after its first chunk made the queue non-empty"
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 0, catalogCount: 0),
            .markCompleted,
            "a fresh empty pair needs no replay; the normal scan populates both stores"
        )
    }

    func testDisablingBackupClearsPersistedUserPause() throws {
        let suite = "photo-backup-controller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "photoBackup.userPaused.v1")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        XCTAssertTrue(controller.isUserPaused)

        controller.disableBackup()

        XCTAssertFalse(controller.isUserPaused)
        XCTAssertFalse(defaults.bool(forKey: "photoBackup.userPaused.v1"))
    }

    private struct ControllerFixture {
        let controller: PhotoLibraryBackupController
        let defaults: UserDefaults
        let suite: String
        let directory: URL

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeControllerFixture(prefix: String) throws -> ControllerFixture {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        return ControllerFixture(
            controller: controller,
            defaults: defaults,
            suite: suite,
            directory: directory
        )
    }

    private actor NonCooperativeWriterLatch {
        private var started = false
        private var blocked = false
        private var completed = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                if started {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        }

        func isStarted() -> Bool { started }

        func waitUntilBlocked() async {
            guard !blocked else { return }
            await withCheckedContinuation { continuation in
                if blocked {
                    continuation.resume()
                } else {
                    blockedWaiters.append(continuation)
                }
            }
        }

        func waitUntilReleased() async {
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    private func makeNonCooperativeWriter(
        _ writer: NonCooperativeWriterLatch
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await writer.markStarted()
            await writer.waitUntilReleased()
            await writer.markCompleted()
        }
    }

    private actor CompletionLatch {
        private var completed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markCompleted() {
            guard !completed else { return }
            completed = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func waitUntilCompleted() async {
            guard !completed else { return }
            await withCheckedContinuation { continuation in
                if completed {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func isCompleted() -> Bool { completed }
    }

    private actor DelayedRunnerStop {
        private var calls = 0
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func stop() async {
            calls += 1
            if !started {
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func callCount() -> Int { calls }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                if started {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
