import Foundation
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class PhotoLibraryBackupControllerStateTests: XCTestCase {
    func testShutdownReleasesTheControllerAndItsRuntimeSignals() async throws {
        var runtime: LibraryRuntimeState? = LibraryRuntimeState()
        weak var releasedRuntime = runtime
        var fixture: ControllerFixture? = try makeControllerFixture(
            prefix: "backup-deallocation",
            runtimeSignals: BackupRuntimeSignalSource(
                current: { [state = runtime!] in BackupThrottleInputs(runtime: state.snapshot(), usesMobileData: false)
                },
                updates: { [state = runtime!] in state.updates() }))
        let defaults = fixture!.defaults
        let suite = fixture!.suite
        let directory = fixture!.directory
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        weak var releasedController = fixture?.controller
        await fixture?.controller.shutdown()
        fixture = nil
        runtime = nil
        _ = await waitUntil { releasedController == nil && releasedRuntime == nil }
        XCTAssertNil(releasedController)
        XCTAssertNil(releasedRuntime, "The network observer must release its signal source after shutdown")
    }

    func testFailedItemsClassifyReasonsWithoutDisplayingTechnicalDetails() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-issue-projection")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let cases: [(BackupIssueKind, UploadBackupSyncQueueState, BackupIssueCategory, String)] = [
            (.network, .discovered, .automatic, "backup.issue_network"),
            (.remoteService, .discovered, .automatic, "backup.issue_remote_service"),
            (.deviceStorage, .discovered, .automatic, "backup.issue_device_storage"),
            (.remoteDraft, .blockedByDraft, .automatic, "backup.issue_remote_draft"),
            (.accountStorage, .discovered, .userResolvable, "backup.issue_account_storage"),
            (.permission, .failed, .userResolvable, "backup.issue_permission"),
            (.deletedElsewhere, .failedPermanent, .decision, "backup.issue_deleted_elsewhere"),
            (.remoteDraftStale, .failedPermanent, .permanent, "backup.issue_remote_draft_stale"),
            (.sourceMissing, .sourceMissing, .permanent, "backup.issue_source_missing"),
            (.unsupported, .failed, .permanent, "backup.issue_unsupported"),
            (.unknown, .failed, .userResolvable, "backup.fail_reason_generic"),
            (.unknown, .discovered, .automatic, "backup.issue_unknown_waiting"),
            (.remoteService, .failed, .userResolvable, "backup.issue_remote_service"),
            (.network, .failed, .userResolvable, "backup.issue_network"),
            (.localState, .failed, .userResolvable, "backup.error_local_state_unavailable"),
            (.unknown, .failedPermanent, .permanent, "backup.issue_permanent"),
        ]
        for (index, testCase) in cases.enumerated() {
            let (kind, state, category, key) = testCase
            let entry = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "reason-\(index)"),
                revision: .init(rawValue: 1), originalFilename: "reason-\(index).heic", state: state,
                lastError: BackupIssueRecord(kind: kind, detail: "PRIVATE SERVER DETAIL").persistedValue,
                updatedAt: Date())
            XCTAssertTrue(queue.upsert(entry))
            let item = try XCTUnwrap(fixture.controller.failedItems().first { $0.source == entry.source })
            XCTAssertEqual(item.category, category, "\(kind), \(state)")
            XCTAssertEqual(item.reason, L10n.string(dynamicKey: key), "\(kind), \(state)")
            XCTAssertEqual(item.technicalDetail, "PRIVATE SERVER DETAIL")
            XCTAssertFalse(item.reason.contains("PRIVATE"))
            XCTAssertEqual(item.isPermanent, category == .permanent || state == .failedPermanent)
        }
        let unsupported = try XCTUnwrap(fixture.controller.failedItems().first { $0.issue == .unsupported })
        fixture.controller.dismissFailedItem(unsupported)
        XCTAssertEqual(
            queue.entry(for: try XCTUnwrap(unsupported.source), revision: try XCTUnwrap(unsupported.revision))?.state,
            .dismissedFailure)
        XCTAssertFalse(fixture.controller.failedItems().contains { $0.id == unsupported.id })
        XCTAssertEqual(queue.summary().resolved, 0, "dismissal is not a successful backup")
        await fixture.controller.shutdown()
    }

    /// A list read that started before the person dismissed a row must not bring that row back.
    func testProblemListReadOvertakenByADismissalIsReadAgain() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-overtaken")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "unsupported"),
            revision: .init(rawValue: 1), originalFilename: "unsupported.heic", state: .failed,
            lastError: BackupIssueRecord(kind: .unsupported, detail: "").persistedValue, updatedAt: Date())
        XCTAssertTrue(queue.upsert(entry))
        let controller = fixture.controller
        let item = try XCTUnwrap(controller.failedItems().first)

        var reads = 0
        var shown: [[String]] = []
        await controller.applyCurrentProblemList(
            {
                reads += 1
                let items = controller.failedItems()
                // The person dismisses the row while the first read is under way.
                if reads == 1 { controller.dismissFailedItem(item) }
                return items
            },
            { shown.append($0.map(\.id)) })

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(shown, [[]], "the read from before the dismissal must not be shown")
        await controller.shutdown()
    }

    func testFailedItemsOmitFreshRowsAndExplainCameraAndOriginalWaits() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-wait-projection")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        for (id, state) in [("fresh", UploadBackupSyncQueueState.discovered), ("queued", .queuedForUpload)] {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                        originalFilename: id, state: state, updatedAt: Date())))
        }
        XCTAssertTrue(fixture.controller.failedItems().isEmpty)
        XCTAssertFalse(fixture.controller.failedItems().offersUserRetry)
        for key in [
            "error.upload_source_not_ready", "backup.issue_waiting_original",
            "The edited photo is waiting for its original resources. Backup will retry automatically.",
            "Das bearbeitete Foto wartet auf seine Originalressourcen. Das Backup versucht es automatisch erneut.",
        ] {
            let record = BackupIssueRecord(kind: .unknown, detail: key, nextAttemptAt: .distantFuture)
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: key), revision: .init(rawValue: 1),
                        originalFilename: key, state: .discovered, lastError: record.persistedValue,
                        updatedAt: Date().addingTimeInterval(3_600))))
        }
        let items = fixture.controller.failedItems()
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0.category == .automatic && $0.retryDescription != nil })
        XCTAssertEqual(
            items.first { $0.filename == "error.upload_source_not_ready" }?.reason,
            L10n.string("backup.issue_source_not_ready"))
        XCTAssertEqual(
            items.first { $0.filename == "backup.issue_waiting_original" }?.reason,
            L10n.string("backup.issue_waiting_original"))
        XCTAssertTrue(
            items.filter { $0.filename != "error.upload_source_not_ready" }
                .allSatisfy { $0.reason == L10n.string("backup.issue_waiting_original") })
        XCTAssertFalse(fixture.controller.failedItems().offersUserRetry)
        XCTAssertTrue(fixture.controller.failedItems(limit: 0).isEmpty)
        await fixture.controller.shutdown()
    }

    func testUserResolvableRetryPreservesAutomaticDatesAndEveryIssueRecord() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-scoped-retry")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let future = Date().addingTimeInterval(3_600)
        let cases: [(String, BackupIssueKind, UploadBackupSyncQueueState)] = [
            ("network", .network, .discovered), ("draft", .remoteDraft, .blockedByDraft),
            ("quota", .accountStorage, .discovered), ("permission", .permission, .failed),
            ("terminal-service", .remoteService, .failed), ("unsupported", .unsupported, .failed),
            ("decision", .deletedElsewhere, .failedPermanent),
        ]
        var entries: [UploadBackupSyncQueueEntry] = []
        for (id, kind, state) in cases {
            let entry = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                originalFilename: id, state: state, attempts: 8,
                lastError: BackupIssueRecord(kind: kind, detail: "detail", nextAttemptAt: future).persistedValue,
                updatedAt: future)
            XCTAssertTrue(queue.upsert(entry))
            entries.append(entry)
        }
        XCTAssertTrue(fixture.controller.failedItems().offersUserRetry)
        let beforeRetry = Date()
        await fixture.controller.retryUserResolvableWork()
        let afterRetry = Date()
        for entry in entries {
            let row = try XCTUnwrap(queue.entry(for: entry.source, revision: entry.revision))
            XCTAssertEqual(row.lastError, entry.lastError, entry.originalFilename)
            let isClassB = ["quota", "permission", "terminal-service"].contains(entry.originalFilename)
            if isClassB {
                XCTAssertEqual(row.state, .discovered)
                XCTAssertEqual(row.attempts, entry.state == .failed ? 0 : entry.attempts)
                // SQLite keeps the date as a double, which can round it a fraction of a microsecond earlier.
                XCTAssertGreaterThanOrEqual(
                    row.updatedAt.timeIntervalSince1970, beforeRetry.timeIntervalSince1970 - 0.001)
                XCTAssertLessThanOrEqual(row.updatedAt.timeIntervalSince1970, afterRetry.timeIntervalSince1970 + 0.001)
            } else {
                // SQLite keeps the date as a double, so compare it within a millisecond.
                XCTAssertEqual(
                    row.updatedAt.timeIntervalSince1970, entry.updatedAt.timeIntervalSince1970, accuracy: 0.001)
                var unchanged = row
                unchanged.updatedAt = entry.updatedAt
                XCTAssertEqual(
                    unchanged, entry, "a scoped retry must not change automatic, decision, or permanent work")
            }
        }
        await fixture.controller.shutdown()
    }

    func testManyFreshOrPermanentRowsCannotHideAPhotoThePersonCanFix() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-limit")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let now = Date()
        for index in 0..<250 {
            // Newer revisions sort first. Fresh rows have no reason, legacy rows carry an earlier build's message,
            // and permanent rows are not the person's to fix.
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "fresh-\(index)"),
                        revision: .init(rawValue: 1_000 + Int64(index)), originalFilename: "fresh", state: .discovered,
                        updatedAt: now)))
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "legacy-\(index)"),
                        revision: .init(rawValue: 2_000 + Int64(index)), originalFilename: "legacy",
                        state: .discovered, lastError: "An earlier build's message", updatedAt: now)))
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "unsupported-\(index)"),
                        revision: .init(rawValue: 500 + Int64(index)), originalFilename: "unsupported",
                        state: .failed, attempts: 8,
                        lastError: BackupIssueRecord(kind: .unsupported, detail: "x").persistedValue,
                        updatedAt: now)))
        }
        let quota = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
            originalFilename: "quota.heic", state: .discovered,
            lastError: BackupIssueRecord(
                kind: .accountStorage, detail: "full", nextAttemptAt: now.addingTimeInterval(21_600)
            ).persistedValue, updatedAt: now.addingTimeInterval(21_600))
        XCTAssertTrue(queue.upsert(quota))

        let items = fixture.controller.failedItems()
        XCTAssertEqual(items.count, 200)
        XCTAssertFalse(items.contains { $0.filename == "fresh" || $0.filename == "legacy" })
        XCTAssertEqual(items.first?.filename, "quota.heic", "a photo the person can fix leads the list")
        XCTAssertTrue(items.offersUserRetry)
        await fixture.controller.retryUserResolvableWork()
        let reopened = try XCTUnwrap(queue.entry(for: quota.source, revision: quota.revision))
        XCTAssertLessThan(reopened.updatedAt, now.addingTimeInterval(60))
        // The reason stays, but the date the list and the scheduler use is the row's own, earlier date.
        let item = try XCTUnwrap(fixture.controller.failedItems(limit: 1_000).first { $0.filename == "quota.heic" })
        XCTAssertLessThan(try XCTUnwrap(item.nextAttemptAt), now.addingTimeInterval(60))
        await fixture.controller.shutdown()
    }

    func testAPhotoThePersonCanFixLeadsTheListBehindThousandsOfWaitingPhotos() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-offline-library")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
                    originalFilename: "quota.heic", state: .failed, attempts: 8,
                    lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue,
                    updatedAt: Date())))
        // An offline pass gives every photo of a large library a reason. Newer revisions sort first.
        let later = Date().addingTimeInterval(3_600)
        let offline = BackupIssueRecord(kind: .network, detail: "offline", nextAttemptAt: later).persistedValue
        XCTAssertTrue(
            queue.upsertBatch(
                (0..<2_500).map { index in
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "offline-\(index)"),
                        revision: .init(rawValue: 1_000 + Int64(index)), originalFilename: "offline",
                        state: .discovered, lastError: offline, updatedAt: later)
                }))
        let items = await fixture.controller.problemItems()
        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(items.first?.filename, "quota.heic", "a photo the person can fix leads the list")
        XCTAssertTrue(items.offersUserRetry)
    }

    func testAnOpenProblemListFollowsANewReasonWhileAPassRuns() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-follow")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let pass = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
        }
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
        let shown = ShownProblemLists()
        let follow = Task {
            await fixture.controller.followProblemList(interval: .milliseconds(10)) { shown.lists.append($0) }
        }
        while shown.lists.isEmpty { await Task.yield() }
        XCTAssertFalse(shown.lists[0].offersUserRetry)

        // The pass gives a photo a reason that the person resolves; no count of the status changes.
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
                    originalFilename: "quota.heic", state: .discovered,
                    lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue,
                    updatedAt: Date().addingTimeInterval(3_600))))
        let deadline = Date().addingTimeInterval(10)
        while shown.lists.last?.offersUserRetry != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(shown.lists.last?.offersUserRetry, true, "Try again appears while the pass runs")

        pass.cancel()
        await fixture.controller.finishSyncForTesting(runID: "run")
        await follow.value
        XCTAssertFalse(fixture.controller.isSyncing, "following ends with the pass")
        await fixture.controller.shutdown()
    }

    @MainActor private final class ShownProblemLists {
        var lists: [[BackupFailedItem]] = []
    }

    func testAUserRetryLeavesARowThatTheRunnerClaimedMeanwhile() throws {
        let fixture = try makeControllerFixture(prefix: "backup-retry-race")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let seen = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
            originalFilename: "quota.heic", state: .failed, attempts: 8,
            lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue, updatedAt: Date())
        XCTAssertTrue(queue.upsert(seen))
        XCTAssertTrue(
            queue.updateState(
                source: seen.source, revision: seen.revision, state: .uploading, attempts: 8,
                lastError: seen.lastError, updatedAt: Date()))
        XCTAssertFalse(queue.reopenForUserRetry(seen, attempts: 0, updatedAt: Date()))
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.state, .uploading)
        XCTAssertTrue(
            queue.updateState(
                source: seen.source, revision: seen.revision, state: .failed, attempts: 8,
                lastError: seen.lastError, updatedAt: Date()))
        let current = try XCTUnwrap(queue.entry(for: seen.source, revision: seen.revision))
        XCTAssertTrue(queue.reopenForUserRetry(current, attempts: 0, updatedAt: Date()))
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.state, .discovered)
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.lastError, seen.lastError)
    }

    func testAFailedRowOfAnAutomaticCauseNeedsThePerson() throws {
        let entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "disk"), revision: .init(rawValue: 1),
            originalFilename: "disk.heic", state: .failed, attempts: 8,
            lastError: BackupIssueRecord(kind: .deviceStorage, detail: "full").persistedValue, updatedAt: Date())
        let item = BackupFailedItem(entry: entry)
        XCTAssertEqual(item.category, .userResolvable, "the app no longer plans a failed row by itself")
        XCTAssertEqual(item.reason, L10n.string("backup.issue_device_storage"), "the list names the cause")
        XCTAssertNil(item.retryDescription, "the list promises no automatic attempt")
    }

    func testUserResolvableRetryStartsAManualPassWithoutClearingTheSystemIssue() async throws {
        let fixture = try makeControllerFixture(
            prefix: "backup-manual-retry", enabled: true, identityResolver: FakeIdentityResolver())
        defer { fixture.cleanup() }
        fixture.controller.setAccessStateForTesting(.full)
        // A real scan would ask PhotoKit, which waits for an authorization answer on a machine without access.
        fixture.controller.replacePassBodyForTesting {}
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let issue = BackupIssueRecord(
            kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
        XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
                    originalFilename: "quota", state: .discovered,
                    lastError: BackupIssueRecord(kind: .accountStorage, detail: "quota").persistedValue,
                    updatedAt: Date().addingTimeInterval(3_600))))
        await fixture.controller.retryUserResolvableWork()
        XCTAssertTrue(fixture.controller.isSyncing, "manual intent starts despite the system issue's future date")
        XCTAssertNotNil(fixture.controller.activeExecutionRunID)
        XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
        await fixture.controller.shutdown()
    }

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

    func testRetirementJoinsChangePreparationAndRejectsItsLateWriter() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-preparation-retirement")
        defer { fixture.cleanup() }
        let preparation = NonCooperativeWriterLatch()
        let consumed = CompletionLatch()
        let orchestration = Task { while !Task.isCancelled { await Task.yield() } }
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "prepared-run", task: orchestration))
        XCTAssertTrue(
            fixture.controller.startPreparedInstantWorkForTesting(
                prepare: {
                    XCTAssertFalse(Thread.isMainThread)
                    await preparation.markStarted()
                    await preparation.waitUntilReleased()
                },
                consume: { await consumed.markCompleted() }
            ))
        await preparation.waitUntilBlocked()
        // Reaching this actor while preparation is blocked also proves UI work remains runnable.
        await fixture.controller.retireInstantWorkForTesting()
        XCTAssertTrue(fixture.controller.isRetiringInstantWorkForTesting)
        await preparation.release()
        await fixture.controller.waitForInstantWorkRetirementForTesting()
        let didConsume = await consumed.isCompleted()
        XCTAssertFalse(didConsume, "a preparation from a retired pass must never enqueue work")
        await fixture.controller.shutdown()
        await orchestration.value
    }

    func testPreparedChangesAreConsumedForTheActiveRun() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-preparation-current")
        defer { fixture.cleanup() }
        let consumed = CompletionLatch()
        let orchestration = Task { while !Task.isCancelled { await Task.yield() } }
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "current-run", task: orchestration))
        XCTAssertTrue(
            fixture.controller.startPreparedInstantWorkForTesting(
                prepare: { XCTAssertFalse(Thread.isMainThread) },
                consume: { await consumed.markCompleted() }
            ))
        await consumed.waitUntilCompleted()
        await fixture.controller.shutdown()
        await orchestration.value
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

    func testBackupDoesNotStartWhenTheRequiredPendingStoreIsMissing() async throws {
        let suite = "photo-backup-controller-pending-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: "photoBackup.enabled.v1")

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: FakeIdentityResolver(),
            uploader: MockUploader(),
            pendingStore: nil,
            requiresPendingStore: true
        )
        controller.setAccessStateForTesting(.full)

        // Without the exclusions an excluded photo could upload, so no pass may start.
        controller.syncNow()
        await controller.retryFailedAndSync()

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isSyncing)
        XCTAssertEqual(controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
        await controller.shutdown()
    }

    func testMissingSourceRecoveryFailureShowsTheLocalizedLocalStateMessage() async throws {
        let suite = "backup-recovery-local-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        defer {
            pending.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: FakeIdentityResolver(), uploader: MockUploader(), pendingStore: pending)
        controller.setEnabledForTesting()
        controller.setAccessStateForTesting(.full)
        let catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName)))
        let info = PhotoBackupAssetInfo(
            localIdentifier: "dropped-photo", creationDate: nil, modificationDate: Date(timeIntervalSince1970: 200),
            pixelWidth: 10, pixelHeight: 10, durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "photo.jpg", mimeType: "image/jpeg")])
        XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
        catalog.close()
        controller.replaceScanForTesting { pending.close() }

        controller.syncNow()
        let finished = await waitUntil { !controller.isSyncing }

        XCTAssertTrue(finished)
        XCTAssertEqual(controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        XCTAssertEqual(queue.count(), 0, "unreadable exclusions must leave recovery pending")
        queue.close()
        await controller.shutdown()
    }

    func testActivationDoesNotStartAPassWhileBackupIsPaused() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-activation-paused", enabled: true)
        defer { fixture.cleanup() }
        fixture.controller.setAccessStateForTesting(.full)
        fixture.controller.pauseBackup()

        fixture.controller.applicationDidBecomeActive()

        XCTAssertFalse(fixture.controller.isSyncing)
        await fixture.controller.shutdown()
    }

    func testActivationDoesNotStartAPassWhileBackupIsOff() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-activation-off")
        defer { fixture.cleanup() }
        fixture.controller.setAccessStateForTesting(.full)

        fixture.controller.applicationDidBecomeActive()

        XCTAssertFalse(fixture.controller.isSyncing)
        await fixture.controller.shutdown()
    }

    /// The excluded list checks its photos again on every activation, also while no pass may start.
    func testActivationTellsThePendingGridWhileBackupIsPaused() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-activation-pending")
        defer { fixture.cleanup() }
        fixture.controller.setEnabledForTesting()
        fixture.controller.setAccessStateForTesting(.full)
        fixture.controller.pauseBackup()
        var changes = 0
        fixture.controller.onLibraryChange = { changes += 1 }

        fixture.controller.applicationDidBecomeActive()

        XCTAssertEqual(changes, 1)
        XCTAssertFalse(fixture.controller.isSyncing)
        await fixture.controller.shutdown()
    }

    func testActivationKeepsTheRunningPass() async throws {
        let fixture = try makeControllerFixture(prefix: "photo-backup-activation-running", enabled: true)
        defer { fixture.cleanup() }
        let writer = NonCooperativeWriterLatch()
        let task = makeNonCooperativeWriter(writer)
        XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))
        await writer.waitUntilStarted()
        await writer.waitUntilBlocked()

        fixture.controller.applicationDidBecomeActive()

        XCTAssertEqual(fixture.controller.activeExecutionRunID, "foreground")
        XCTAssertFalse(fixture.controller.isRunnerStopPendingForTesting)
        await writer.release()
        await task.value
        await fixture.controller.shutdown()
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

    // MARK: - Waiting for Wi-Fi

    func testWiFiReturningDuringTheScanStartsTheNextPassAtOnce() async throws {
        let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
        let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-returns", signals: signals)
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let scans = PassCounter()
        controller.replaceScanForTesting {
            // The runner already found the cellular network; Wi-Fi returns while this pass still scans.
            if scans.increment() == 1 {
                await signals.waitUntilRead()
                signals.setWaitsForWiFi(false)
            }
        }

        controller.syncNow()

        let restarted = await waitUntil { scans.count >= 2 }
        XCTAssertTrue(restarted, "the next pass must not wait for the fallback timer")
        let settled = await waitUntil { scans.count >= 2 && !controller.isSyncing }
        XCTAssertTrue(settled)
        XCTAssertNotEqual(controller.status.phase, .waitingForWiFi, "the status must not stay on Wi-Fi")
        await controller.shutdown()
    }

    func testWiFiWaitDoesNotStretchTheFallback() async throws {
        let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
        let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-fallback", signals: signals)
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let scans = PassCounter()
        controller.replaceScanForTesting { _ = scans.increment() }

        for pass in 1...8 {
            controller.syncNow()
            let finished = await waitUntil {
                scans.count == pass && !controller.isSyncing && controller.isAutoResumeScheduledForTesting
            }
            XCTAssertTrue(finished, "pass \(pass)")
        }

        let waiting = await waitUntil { controller.status.phase == .waitingForWiFi }
        XCTAssertTrue(waiting)
        let wakeAt = try XCTUnwrap(controller.nextAutomaticAttemptAt)
        XCTAssertLessThanOrEqual(
            wakeAt.timeIntervalSinceNow, 31, "eight Wi-Fi waits are no failures and keep the shortest fallback")
        await controller.shutdown()
    }

    func testNetworkChangeEndsTheWiFiWaitWithANewPass() async throws {
        try await assertWiFiWaitEnds(prefix: "backup-wifi-network") { _, signals in signals.announceChange() }
    }

    func testTurningMobileDataOnEndsTheWiFiWaitWithANewPass() async throws {
        try await assertWiFiWaitEnds(prefix: "backup-wifi-setting") { controller, _ in
            controller.mobileDataSettingDidChange()
        }
    }

    private func assertWiFiWaitEnds(
        prefix: String,
        _ end: (PhotoLibraryBackupController, FakeBackupRuntimeSignals) -> Void
    ) async throws {
        let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
        let fixture = try makeWiFiWaitFixture(prefix: prefix, signals: signals)
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let scans = PassCounter()
        controller.replaceScanForTesting { _ = scans.increment() }

        controller.syncNow()
        let waiting = await waitUntil {
            !controller.isSyncing && controller.isAutoResumeScheduledForTesting
                && controller.status.phase == .waitingForWiFi
        }
        XCTAssertTrue(waiting, "the pass ends waiting for Wi-Fi")
        end(controller, signals)
        XCTAssertEqual(scans.count, 1, "nothing starts while the wait holds")

        signals.setWaitsForWiFi(false)
        end(controller, signals)

        let restarted = await waitUntil { scans.count >= 2 }
        XCTAssertTrue(restarted, "the end of the wait starts a pass without the fallback timer")
        await controller.shutdown()
    }

    /// A backup with one runnable row whose scan never touches PhotoKit; only the runner drains.
    private func makeWiFiWaitFixture(prefix: String, signals: FakeBackupRuntimeSignals) throws -> ControllerFixture {
        let fixture = try makeControllerFixture(
            prefix: prefix, identityResolver: FakeIdentityResolver(), runtimeSignals: signals.source)
        fixture.controller.setEnabledForTesting()
        fixture.controller.setAccessStateForTesting(.full)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .fileURL, identifier: "waiting-photo"), revision: .init(rawValue: 1),
                    originalFilename: "waiting-photo.jpg", state: .discovered,
                    updatedAt: Date().addingTimeInterval(-60))))
        queue.close()
        return fixture
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
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

    private func makeControllerFixture(
        prefix: String, enabled: Bool = false, identityResolver: (any UploadIdentityResolving)? = nil,
        runtimeSignals: BackupRuntimeSignalSource = .apple
    ) throws -> ControllerFixture {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if enabled { defaults.set(true, forKey: "photoBackup.enabled.v1") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults,
                runtimeSignals: runtimeSignals
            ),
            identityResolver: identityResolver,
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

/// Injected runtime signals: the test decides when the network is cellular with mobile data off, and when it changes.
private final class FakeBackupRuntimeSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var waitsForWiFi: Bool
    private var reads = 0
    private var continuations: [AsyncStream<LibraryRuntimeSnapshot>.Continuation] = []

    init(waitsForWiFi: Bool) { self.waitsForWiFi = waitsForWiFi }

    var source: BackupRuntimeSignalSource {
        BackupRuntimeSignalSource(
            current: { self.read() },
            updates: { AsyncStream { continuation in self.lock.withLock { self.continuations.append(continuation) } } }
        )
    }

    func setWaitsForWiFi(_ value: Bool) { lock.withLock { waitsForWiFi = value } }

    func announceChange() {
        let continuations = lock.withLock { self.continuations }
        continuations.forEach { $0.yield(LibraryRuntimeSnapshot()) }
    }

    func waitUntilRead(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while lock.withLock({ reads == 0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func read() -> BackupThrottleInputs {
        lock.withLock {
            reads += 1
            return BackupThrottleInputs(isNetworkExpensive: waitsForWiFi, usesMobileData: !waitsForWiFi)
        }
    }
}

private final class PassCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
