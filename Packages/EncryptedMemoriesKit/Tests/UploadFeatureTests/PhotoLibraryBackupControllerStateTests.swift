import Foundation
import PhotosCore
import SQLite3
import UploadCore
import UploadFeature
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
        let order = BackupProblemListReadOrder()
        await controller.applyCurrentProblemList(
            order: order, generation: order.begin(),
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

    #if DEBUG
        func testAnOpenProblemListFollowsANewReasonWhileAPassRuns() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-follow")
            defer { fixture.cleanup() }
            // The controller is the only owner of its queue file, so its own store reports every write.
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            // The coalescing pause never ends: only a queue write can bring the next read.
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertFalse(shown.lists[0].offersUserRetry)

            // The pass gives a photo a reason that the person resolves; no count of the status changes.
            XCTAssertTrue(queue.upsert(quotaEntry("quota")))
            let deadline = Date().addingTimeInterval(10)
            while shown.lists.last?.offersUserRetry != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(shown.lists.last?.offersUserRetry, true, "Try again appears without waiting for a timer")

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            XCTAssertFalse(fixture.controller.isSyncing, "following ends with the pass")
            await fixture.controller.shutdown()
        }

        func testAnEmptyFirstReadWhileTheSummaryCountsAnItemIsReadAgain() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-empty-first")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("late"))
            let reads = ReadCounter()
            let clock = BackupTestClock()
            let shown = ShownProblemLists()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { reads.next() == 1 ? [] : [item] }, expectingItems: { true }, clock: clock,
                { shown.lists.append($0) }, { unavailable += 1 })
            XCTAssertEqual(
                shown.lists, [[], [item]], "the empty first read is followed by a read that shows the photo")
            XCTAssertEqual(clock.sleeps, [0.25])
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testAListThatStaysEmptyWhileTheSummaryCountsItemsIsReportedAfterBoundedReads() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-stays-empty")
            defer { fixture.cleanup() }
            let reads = ReadCounter()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: {
                    _ = reads.next()
                    return []
                }, expectingItems: { true }, clock: clock, { _ in }, { unavailable += 1 })
            XCTAssertEqual(reads.value, 6, "the first read and five re-reads")
            XCTAssertEqual(clock.sleeps, [0.25, 0.5, 1, 2, 4])
            XCTAssertEqual(unavailable, 1, "an empty list that the summary contradicts is reported, not accepted")
            await fixture.controller.shutdown()
        }

        func testAnEmptyListWithoutAttentionIsNotReadAgain() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-really-empty")
            defer { fixture.cleanup() }
            let reads = ReadCounter()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: {
                    _ = reads.next()
                    return []
                }, expectingItems: { false }, clock: clock, { _ in }, { unavailable += 1 })
            XCTAssertEqual(reads.value, 1)
            XCTAssertTrue(clock.sleeps.isEmpty)
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testACancelledReadShowsNothingAndTheRestartReadsTheList() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-cancelled-read")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("restart"))
            let started = ReadGate()
            let release = ReadGate()
            let shown = ShownProblemLists()
            var unavailable = 0
            let first = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        started.open()
                        await release.wait()
                        return []
                    }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                    { unavailable += 1 })
            }
            await started.wait()
            first.cancel()
            release.open()
            await first.value
            XCTAssertTrue(shown.lists.isEmpty, "a cancelled read applies nothing, not even an empty list")
            XCTAssertEqual(unavailable, 0, "a cancelled read is no report either")

            // The task that starts it again reads anew and shows the photo.
            await fixture.controller.readProblemList(
                using: { [item] }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                { unavailable += 1 })
            XCTAssertEqual(shown.lists, [[item]])
            await fixture.controller.shutdown()
        }

        func testAnOlderReadThatEndsAfterANewerOneNeitherAppliesNorReports() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-older-read")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("newer"))
            let reads = ReadCounter()
            let sixthStarted = ReadGate()
            let sixthMayEnd = ReadGate()
            let shown = ShownProblemLists()
            let order = BackupProblemListReadOrder()
            var unavailable = 0
            // A manual retry whose sixth, empty result arrives late.
            let manual = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        if reads.next() == 6 {
                            sixthStarted.open()
                            await sixthMayEnd.wait()
                        }
                        return []
                    }, order: order, expectingItems: { true }, clock: BackupTestClock(),
                    { shown.lists.append($0) }, { unavailable += 1 })
            }
            await sixthStarted.wait()
            // The automatic read for a summary change starts later and shows the photo.
            await fixture.controller.readProblemList(
                using: { [item] }, order: order, expectingItems: { true }, clock: BackupTestClock(),
                { shown.lists.append($0) }, { unavailable += 1 })
            sixthMayEnd.open()
            await manual.value
            XCTAssertEqual(shown.lists.count, 6, "five empty lists of the manual read, then the newer list only")
            XCTAssertEqual(shown.lists.last, [item], "the older, empty result must not replace the newer list")
            XCTAssertEqual(unavailable, 0, "the older read must not report the list as unavailable")
            await fixture.controller.shutdown()
        }

        func testAReadThatTheControllerShutdownOvertakesNeitherAppliesNorReports() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-shutdown-read")
            defer { fixture.cleanup() }
            let started = ReadGate()
            let release = ReadGate()
            let shown = ShownProblemLists()
            var unavailable = 0
            let read = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        started.open()
                        await release.wait()
                        return []
                    }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                    { unavailable += 1 })
            }
            await started.wait()
            await fixture.controller.shutdown()
            release.open()
            await read.value
            XCTAssertTrue(shown.lists.isEmpty)
            XCTAssertEqual(unavailable, 0)
        }

        func testADecisionReadThatLeavesTheListEmptyReadsAgainAndShowsTheFailedPhoto() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-reread")
            defer { fixture.cleanup() }
            let decision = decisionItem("photo", issue: .deletedElsewhere)
            // The photo failed again with another reason; the summary counts it.
            let failedAgain = decisionItem("photo", issue: .network)
            let model = BackupProblemListModel()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { [failedAgain] }, afterDecision: decision, expectingItems: { true }, clock: clock,
                { model.replaceItems($0) }, { unavailable += 1 })
            XCTAssertEqual(model.items, [failedAgain], "the re-read shows the photo that failed again")
            XCTAssertEqual(model.presentation(expectsItems: true), .list)
            XCTAssertEqual(clock.sleeps, [0.25])
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testADecisionReadThatStaysEmptyWhileTheSummaryCountsItemsEndsUnavailable() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-unavailable")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            model.replaceItems([decisionItem("photo", issue: .deletedElsewhere)])
            let clock = BackupTestClock()
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { true }, clock: clock, { model.replaceItems($0) }, { model.markUnavailable() })
            XCTAssertEqual(
                model.presentation(expectsItems: true), .unavailable, "never a spinner without a reader behind it")
            XCTAssertEqual(clock.sleeps, [0.25, 0.5, 1, 2, 4])
            await fixture.controller.shutdown()
        }

        func testADecisionReadKeepsAnUnresolvedDecisionAndRemovesAResolvedOne() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-filter")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            let decision = decisionItem("decision", issue: .deletedElsewhere)
            let waiting = decisionItem("waiting", issue: .network)
            await fixture.controller.readProblemList(
                using: { [decision, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [decision, waiting], "a decision that is still open stays")

            let reopened = decisionItem("decision", issue: .network)
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [waiting], "the resolved decision leaves at once")

            // Reading without a decision filters nothing.
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, expectingItems: { false }, clock: BackupTestClock(),
                { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [reopened, waiting])
            await fixture.controller.shutdown()
        }

        func testADecisionReadOfAnEmptyQueueShowsNothingNeedsAttention() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-empty")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            XCTAssertEqual(model.presentation(expectsItems: false), .loading)
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { false }, clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.presentation(expectsItems: false), .empty)
            await fixture.controller.shutdown()
        }

        private func decisionItem(_ id: String, issue: BackupIssueKind) -> BackupFailedItem {
            BackupFailedItem(
                id: id, filename: "\(id).heic", reason: "Reason", isPermanent: false, issue: issue,
                nextAttemptAt: .distantFuture)
        }

        func testTheFollowReadsAgainWhenTheFirstReadMissedThePhoto() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-follow-reread")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            // The summary counts a photo that the queue does not return yet.
            fixture.controller.problemListExpectationForTesting = { true }
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let shown = ShownProblemLists()
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { clock.isWaiting }
            XCTAssertEqual(shown.lists.count, 1, "the first read came back empty")
            XCTAssertTrue(shown.lists.first?.isEmpty == true)
            XCTAssertTrue(queue.upsert(quotaEntry("appears")))
            clock.releaseAll()
            try await waitForCondition { shown.lists.count >= 2 }
            XCTAssertGreaterThanOrEqual(shown.lists.count, 2, "the second read did not arrive")
            XCTAssertEqual(shown.lists.dropFirst().first?.map(\.filename), ["appears.heic"])
            follow.cancel()
            clock.releaseAll()
            await follow.value
            await fixture.controller.shutdown()
        }

        func testWritesDuringTheCoalescingPauseShowOnceAfterIt() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-coalesce")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertTrue(queue.upsert(quotaEntry("first")))
            try await waitForCondition { shown.lists.count == 2 }
            try await waitForCondition { clock.isWaiting }

            // Two writes inside the pause: neither shows until the pause ends, then both show in one read.
            XCTAssertTrue(queue.upsert(quotaEntry("second")))
            XCTAssertTrue(queue.upsert(quotaEntry("third")))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(shown.lists.count, 2, "writes inside the pause wait for it")
            clock.releaseAll()
            try await waitForCondition { shown.lists.count == 3 }
            if shown.lists.count >= 3 {
                XCTAssertEqual(Set(shown.lists[2].map(\.filename)), ["first.heic", "second.heic", "third.heic"])
            }

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            await fixture.controller.shutdown()
        }

        func testTheEndOfThePassReadsTheListOnceMore() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-end")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 1)

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            try await waitForCondition { shown.ended }
            clock.releaseAll()
            follow.cancel()
            await follow.value
            XCTAssertEqual(shown.lists.count, 2, "the end of the pass shows the final list once, without a write")
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0, "a closed list leaves nothing behind")
            await fixture.controller.shutdown()
        }

        func testAPassThatEndsDuringThePauseStillShowsItsLastWrites() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-end-in-pause")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertTrue(queue.upsert(quotaEntry("first")))
            try await waitForCondition { shown.lists.count == 2 }
            try await waitForCondition { clock.isWaiting }

            // The last write of the pass and the end of the pass both fall into the pause.
            XCTAssertTrue(queue.upsert(quotaEntry("last")))
            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            XCTAssertEqual(shown.lists.count, 3, "the end of the pass reads once more after the pause")
            XCTAssertEqual(shown.lists.last.map { Set($0.map(\.filename)) }, ["first.heic", "last.heic"])
            await fixture.controller.shutdown()
        }

        func testSeveralOpenListsEachGetTheLastReadAndLeaveNothingBehind() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-several")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let first = ShownProblemLists()
            let second = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let followers = [first, second].map { shown in
                Task {
                    await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                    shown.ended = true
                }
            }
            try await waitForCondition { !first.lists.isEmpty && !second.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 2)

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { first.ended && second.ended }
            for follower in followers {
                follower.cancel()
                await follower.value
            }
            XCTAssertEqual(first.lists.count, 2, "each open list reads once more at the end of the pass")
            XCTAssertEqual(second.lists.count, 2)
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0)
            await fixture.controller.shutdown()
        }

        func testAListClosedWhileItWaitsLeavesNothingBehind() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-closed")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let follow = Task {
                await fixture.controller.followProblemList(clock: HeldBackupSleepClock(clock: BackupTestClock())) {
                    shown.lists.append($0)
                }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 1)

            follow.cancel()  // The person closes the list while it waits for the next write.
            try await waitForCondition { shown.ended }
            await follow.value
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0)
            XCTAssertTrue(fixture.controller.isSyncing, "closing the list does not touch the pass")

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            await fixture.controller.shutdown()
        }

        private func quotaEntry(_ name: String) -> UploadBackupSyncQueueEntry {
            .init(
                source: .init(kind: .photoLibraryAsset, identifier: name), revision: .init(rawValue: 1),
                originalFilename: "\(name).heic", state: .discovered,
                lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue,
                updatedAt: Date().addingTimeInterval(3_600))
        }

        private func waitForCondition(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(condition())
        }
    #endif

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private actor ReadGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        nonisolated func open() { Task { await openNow() } }
        private func openNow() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @MainActor private final class ShownProblemLists {
        var lists: [[BackupFailedItem]] = []
        var ended = false
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

    #if DEBUG
        func testUserResolvableRetryStartsAManualPassWithoutClearingTheSystemIssue() async throws {
            let fixture = try makeControllerFixture(
                prefix: "backup-manual-retry", enabled: true, identityResolver: FakeIdentityResolver(),
                runtimeSignals: .wiFiWithMobileDataOff)
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
            let returned = CompletionLatch()
            let catchUp = Task {
                await fixture.controller.backgroundCatchUp(owner: .iOSBackgroundTask) { runID in
                    reportedRunID = runID
                }
                await returned.markCompleted()
            }
            // The call must return while the foreground run is still blocked. The deadline only guards
            // against a hang; how fast the call returns is not asserted.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !(await returned.isCompleted()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let returnedWhileBlocked = await returned.isCompleted()
            XCTAssertTrue(returnedWhileBlocked, "The catch-up waited for the foreground run.")
            XCTAssertNil(reportedRunID)
            XCTAssertEqual(fixture.controller.activeExecutionRunID, "foreground")
            let adoptedForegroundRun = await writer.isCompleted()
            XCTAssertFalse(adoptedForegroundRun)

            await writer.release()
            await task.value
            await catchUp.value
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
    #endif

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

    #if DEBUG
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
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
                    runtimeSignals: .wiFiWithMobileDataOff),
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

        /// Runs one pass whose scan throws `error`, and returns what the person would read afterwards.
        private func messageAfterAScan(throwing error: Error) async throws -> String? {
            let fixture = try makeControllerFixture(
                prefix: "backup-scan-failure", identityResolver: FakeIdentityResolver(),
                runtimeSignals: .wiFiWithMobileDataOff)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                throw error
            }

            controller.syncNow()
            let finished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the pass must run its scan")
            let message = controller.lastMessage
            await controller.shutdown()
            return message
        }

        func testScanFailureShowsTheLocalizedLocalStateMessageInsteadOfTheTechnicalText() async throws {
            let technical = "Photo library scan state could not be saved"
            let failures: [Error] = [
                UploadError.backend(technical), UploadError.backend("Photo library catalog could not be updated"),
                CocoaError(.fileWriteUnknown),
            ]
            for failure in failures {
                let message = try await messageAfterAScan(throwing: failure)
                XCTAssertEqual(message, L10n.string("backup.error_local_state_unavailable"), "\(failure)")
            }
            let key = "backup.error_local_state_unavailable"
            for language in ["en", "de"] {
                let translated = try XCTUnwrap(try catalogTranslation(of: key, language: language), language)
                XCTAssertFalse(translated.contains("Photo library"), language)
                XCTAssertNotEqual(translated, technical, language)
            }
            XCTAssertEqual(
                try catalogTranslation(of: key, language: "de"),
                "Das Backup kann auf diesem Gerät gerade nicht weitermachen. Bitte starte die App neu.")
        }

        func testCancelledScanShowsNoMessage() async throws {
            let message = try await messageAfterAScan(throwing: CancellationError())
            XCTAssertNil(message)
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
    #endif

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

    #if DEBUG
        // MARK: - Waiting for Wi-Fi

        func testDismissedMissingSourceRecheckKeepsTheWiFiWaitWithoutAPendingUpload() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-dismissed-source-wake", source: signals.source, dismissedSourceRecheck: true)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()

            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting, "The deferred source check is outstanding work, so the backup waits for Wi-Fi")
            try await assertNoAutomaticResume(controller, "Wi-Fi returning resumes the deferred source check")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(controller.status.dismissedFailures, 1)
            XCTAssertEqual(controller.status.needsAttentionCount, 0)
            XCTAssertEqual(controller.status.waitingRetry, 0)
            XCTAssertEqual(controller.status.notBackedUpCount, 1)
            XCTAssertEqual(controller.status.outstandingCount, 1)
            await controller.shutdown()
        }

        func testWiFiReturningDuringTheScanStartsTheNextPassAtOnce() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-returns", source: signals.source)
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

        func testWiFiWaitSchedulesNoAutomaticResumeAndDoesNotStretchTheFallback() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-fallback", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            for pass in 1...8 {
                controller.syncNow()
                let finished = await waitUntil {
                    scans.count == pass && !controller.isSyncing && controller.status.phase == .waitingForWiFi
                }
                XCTAssertTrue(finished, "pass \(pass)")
                try await assertNoAutomaticResume(controller, "pass \(pass)")
            }

            XCTAssertEqual(scans.count, 8, "only the requested passes ran")
            XCTAssertEqual(
                controller.consecutiveNoProgressRunsForTesting, 0, "eight Wi-Fi waits are no failures")
            await controller.shutdown()
        }

        /// The end of the wait is an event: a timer would repeat the whole pass, and on iOS its date would also arm the
        /// background processing request.
        private func assertNoAutomaticResume(
            _ controller: PhotoLibraryBackupController, _ message: String,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            // The pass decides its next wake at the end of its completion; check after that decision. A runner snapshot
            // that reaches the status projector after the completion is not awaited; it can change only the shown
            // date, never schedule a timer.
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, message, file: file, line: line)
            XCTAssertFalse(
                (controller.nextAutomaticAttemptAt ?? .distantPast) > Date(), message, file: file, line: line)
            XCTAssertEqual(controller.status.phase, .waitingForWiFi, message, file: file, line: line)
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
            let fixture = try makeWiFiWaitFixture(prefix: prefix, source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting, "the pass ends waiting for Wi-Fi")
            try await assertNoAutomaticResume(controller, "the wait ends only by the event below")
            end(controller, signals)
            XCTAssertEqual(scans.count, 1, "nothing starts while the wait holds")

            signals.setWaitsForWiFi(false)
            end(controller, signals)

            let restarted = await waitUntil { scans.count >= 2 }
            XCTAssertTrue(restarted, "the end of the wait starts a pass without the fallback timer")
            await controller.shutdown()
        }

        // MARK: - First network path

        func testUndeterminedNetworkThenWiFiStartsThePassWithoutTheWiFiMessage() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            // The bounded wait outlasts the test, so only the first path can start the pass.
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-wifi", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "no pass starts before the first network path")
            XCTAssertFalse(controller.isSyncing)
            XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let finished = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the first path reports Wi-Fi and the pass starts at once")
            XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)
            await controller.shutdown()
        }

        func testUndeterminedNetworkThenCellularWithMobileDataOffWaitsForWiFi() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-cellular", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0)

            runtime.update {
                $0.network = LibraryNetworkState(
                    isReachable: true, isExpensive: true, usedInterfaces: [.cellular], availableInterfaces: [.cellular])
            }

            let waiting = await waitUntil(timeout: .seconds(5)) {
                scans.count == 1 && !controller.isSyncing && controller.status.phase == .waitingForWiFi
            }
            XCTAssertTrue(waiting, "a cellular first path with mobile data off waits for Wi-Fi")
            try await assertNoAutomaticResume(controller, "cellular wait")
            await controller.shutdown()
        }

        func testCellularWithMobileDataOnStartsThePass() async throws {
            let cellular = LibraryNetworkState(isReachable: true, isExpensive: true)
            for initial in [LibraryNetworkState.undetermined, cellular] {
                let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: initial))
                let fixture = try makeWiFiWaitFixture(
                    prefix: "backup-first-path-mobile-data", source: runtimeSource(runtime, usesMobileData: true))
                defer { fixture.cleanup() }
                let controller = fixture.controller
                let scans = PassCounter()
                controller.replaceScanForTesting { _ = scans.increment() }

                controller.syncNow()

                let finished = await waitUntil(timeout: .seconds(10)) { scans.count == 1 && !controller.isSyncing }
                XCTAssertTrue(finished, "mobile data on starts at once, determined: \(initial.isDetermined)")
                XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)
                await controller.shutdown()
            }
        }

        func testTurningMobileDataOnBeforeTheFirstNetworkPathStartsThePass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let usesMobileData = LockedFlag(false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-setting",
                source: BackupRuntimeSignalSource(
                    current: {
                        BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: usesMobileData.value)
                    },
                    updates: { runtime.updates() }),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0)

            usesMobileData.value = true
            controller.mobileDataSettingDidChange()

            let finished = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "turning mobile data on ends the wait for the first path")
            await controller.shutdown()
        }

        func testMissingFirstNetworkPathEndsInTheWiFiWaitAfterTheBoundedWait() async throws {
            // The path monitor never reports: the process state stays undetermined and mobile data is off.
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-missing", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .milliseconds(500))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the pass first waits for the path")
            firstPathWait.releaseAll()

            let waiting = await waitUntil(timeout: .seconds(10)) {
                scans.count == 1 && !controller.isSyncing && controller.status.phase == .waitingForWiFi
            }
            XCTAssertTrue(waiting, "after the bounded wait the pass runs and holds uploads, as without a path")
            try await assertNoAutomaticResume(controller, "the late first path resumes the wait")

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            let resumed = await waitUntil(timeout: .seconds(10)) { scans.count == 2 }
            XCTAssertTrue(resumed, "a first path that arrives late ends the Wi-Fi wait")
            await controller.shutdown()
        }

        func testAnEndedWiFiWaitKeepsItsWakeWhenTheNextPassCannotStart() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-ended-declined", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting)
            try await assertNoAutomaticResume(controller, "the wait holds")

            // Wi-Fi returns, but a system issue with a later retry date declines the next automatic pass.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            signals.setWaitsForWiFi(false)
            controller.syncNow()

            let armed = await waitUntil { controller.isAutoResumeScheduledForTesting }
            XCTAssertTrue(armed, "the declined pass still needs its automatic wake")
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        func testManualRetryResumesAfterCellularWiFiWaitWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: true, returnsDuringScan: false)
        }

        func testManualRetryResumesAfterTheFirstPathWaitExpiresWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: false, returnsDuringScan: false)
        }

        func testManualRetryResumesWhenWiFiReturnsDuringItsScanWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: true, returnsDuringScan: true)
        }

        func testManualRetryResumesInItsOwnRunWhenABackgroundWindowSeesWiFiFirst() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, returnsInBackgroundWindow: true)
        }

        func testManualRetryResumesWhenMobileDataAllowsTheExpensivePathWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, enablesMobileData: true)
        }

        private func assertManualRetryResumesAfterWiFiWait(
            networkDetermined: Bool, returnsDuringScan: Bool, returnsInBackgroundWindow: Bool = false,
            enablesMobileData: Bool = false
        ) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: networkDetermined)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-wifi-retry", source: signals.source,
                firstNetworkPathWait: .milliseconds(100))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let scans = PassCounter()
            let owners = OwnerRecorder()
            let releaseScan = LockedFlag(!returnsDuringScan)
            controller.replaceScanForTesting {
                let pass = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if pass == 1 {
                    while !releaseScan.value, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }

            await controller.retryUserResolvableWork()
            signals.resetReads()

            let waiting = await waitUntil {
                if returnsDuringScan { return scans.count == 1 && owners.values == [.manual] && signals.hasBeenRead }
                return controller.status.phase == .waitingForWiFi && !controller.isSyncing
            }
            XCTAssertTrue(waiting, "The manual pass must reach the policy wait before the network returns")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(owners.values, [.manual])
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue, "The wait preserves the issue")
            XCTAssertEqual(queue.summary().resolved, 0, "An expensive path uploads nothing with mobile data off")

            if !returnsDuringScan {
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                XCTAssertFalse(controller.isSyncing, "An expensive path cannot start the pending manual retry")
                XCTAssertEqual(scans.count, 1, "An expensive path must not consume the pending manual retry")
            }
            signals.setNetworkDetermined(true)
            if enablesMobileData {
                signals.setUsesMobileData(true)
            } else {
                signals.setWaitsForWiFi(false)
            }
            if returnsInBackgroundWindow {
                let windowRuns = PassCounter()
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
                XCTAssertEqual(windowRuns.count, 0, "A window cannot expire the resumed manual retry")
            } else if enablesMobileData {
                controller.mobileDataSettingDidChange()
            } else {
                signals.announceChange()
            }
            releaseScan.value = true

            let resumed = await waitUntil { scans.count >= 2 && !controller.isSyncing }
            XCTAssertTrue(resumed, "The manual retry must resume before the one-hour index retry date")
            XCTAssertEqual(owners.values, [.manual, .manual])
            XCTAssertNil(queue.runtimeIssue(for: .remoteIndexPreparation), "The resumed pass prepares the index")
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            controller.syncNow()
            XCTAssertFalse(controller.isSyncing, "The admitted manual retry cannot bypass a later automatic backoff")
            await controller.shutdown()
        }

        func testBackgroundStartAfterTheFirstPathSnapshotCannotTakeADeferredManualPass() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-path-observer-gap", source: signals.source,
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            await controller.retryUserResolvableWork()
            XCTAssertFalse(controller.isSyncing)

            // Publish the snapshot without notifying the observer, as the real main-actor hop can lag the path.
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let windowRuns = PassCounter()
            await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
            signals.announceChange()

            let finished = await waitUntil { scans.count >= 1 && !controller.isSyncing }
            XCTAssertTrue(finished)
            XCTAssertEqual(windowRuns.count, 0, "The window never owns or expires the deferred manual pass")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testDeferredManualRetryKeepsItsOwnerWhenTheFirstKnownPathFindsABusyLock() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-path-busy-lock", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            await controller.retryUserResolvableWork()
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            // This foreground entry consumes the known snapshot before the observer, but cannot acquire the lock.
            controller.syncNow()
            XCTAssertEqual(scans.count, 0)
            XCTAssertFalse(controller.isSyncing)
            XCTAssertTrue(lock.release(runID: "other-live-run"))

            controller.syncNow()

            let finished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "A declined admission must not consume the person's retry intent")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testDeferredManualRetrySurvivesItsFirstOfflinePassBeforeTheObserver() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: true, holdsResumeLock: false)
        }

        func testManualRetrySurvivesLosingConnectivityAfterAdmission() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: false, holdsResumeLock: false)
        }

        func testFirstOfflineManualRetryKeepsItsIntentWhenWiFiFindsABusyLock() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: true, holdsResumeLock: true)
        }

        private func assertFirstManualOfflinePassResumes(deferred: Bool, holdsResumeLock: Bool) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: !deferred)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-manual-offline", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }

            await controller.retryUserResolvableWork()
            // No main-actor yield: the admitted task has not evaluated the runner's policy yet.
            signals.setNetworkAvailable(false)
            if deferred {
                XCTAssertFalse(controller.isSyncing)
                signals.setNetworkDetermined(true)
                let windowRuns = PassCounter()
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
                XCTAssertEqual(windowRuns.count, 0, "The window cannot own the first offline manual pass")
            }
            let offlineFinished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(offlineFinished)
            XCTAssertEqual(owners.values, [.manual])
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
            XCTAssertEqual(queue.summary().resolved, 0, "The offline pass performs no upload")

            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            if holdsResumeLock {
                XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            }
            signals.setNetworkAvailable(true)
            signals.resetReads()
            signals.announceChange()
            let observed = await waitUntil { signals.hasBeenRead }
            XCTAssertTrue(observed)
            if holdsResumeLock {
                controller.syncNow()
                XCTAssertFalse(controller.isSyncing, "The existing lock rejects the resumed retry")
                XCTAssertEqual(scans.count, 1)
                XCTAssertTrue(lock.release(runID: "other-live-run"))
                controller.syncNow()
            }
            let resumed = await waitUntil { scans.count == 2 && !controller.isSyncing }
            XCTAssertTrue(resumed, "The first offline manual pass must retain its retry past the saved index backoff")
            XCTAssertEqual(owners.values, [.manual, .manual])
            XCTAssertNil(queue.runtimeIssue(for: .remoteIndexPreparation))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            controller.syncNow()
            XCTAssertFalse(controller.isSyncing, "A completed retry consumes its backoff bypass")
            await controller.shutdown()
        }

        func testManualRetrySurvivesAnOfflinePathBetweenCellularAndWiFi() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: false)
        }

        func testManualRetrySurvivesAnotherRetryWhileThePathIsOffline() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: true)
        }

        func testManualRetrySurvivesWiFiReturningDuringTheRepeatedOfflineScan() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: true, wiFiReturnsDuringScan: true)
        }

        private func assertManualRetrySurvivesOffline(
            retryWhileOffline: Bool, wiFiReturnsDuringScan: Bool = false
        ) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-manual-offline-wifi", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let scans = PassCounter()
            let owners = OwnerRecorder()
            let releaseOfflineScan = LockedFlag(!wiFiReturnsDuringScan)
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 2 {
                    while !releaseOfflineScan.value, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(waiting)
            XCTAssertEqual(controller.status.phase, .waitingForWiFi)

            try await assertNoAutomaticResume(controller, "The initial Wi-Fi pass has settled")
            signals.setNetworkAvailable(false)
            signals.resetReads()
            signals.announceChange()
            let offlineObserved = await waitUntil { signals.hasBeenRead }
            XCTAssertTrue(offlineObserved, "The observer consumes the offline snapshot before another retry")
            if retryWhileOffline {
                await controller.retryUserResolvableWork()
            } else {
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
            }
            signals.resetReads()
            let offlinePassReady = await waitUntil {
                if wiFiReturnsDuringScan { return scans.count == 2 && signals.hasBeenRead }
                return !controller.isSyncing
            }
            XCTAssertTrue(offlinePassReady, "The repeated pass must read the offline policy before Wi-Fi returns")
            let offlinePassCount = retryWhileOffline ? 2 : 1
            XCTAssertEqual(
                scans.count, offlinePassCount, "An offline snapshot must not consume the pending manual retry")

            signals.setNetworkAvailable(true)
            signals.setWaitsForWiFi(false)
            signals.resetReads()
            signals.announceChange()
            if wiFiReturnsDuringScan {
                let wakeObserved = await waitUntil { signals.hasBeenRead }
                XCTAssertTrue(wakeObserved, "The Wi-Fi wake arrives while the offline scan still owns the pass")
                XCTAssertTrue(controller.isSyncing)
            }
            releaseOfflineScan.value = true

            let resumed = await waitUntil { scans.count > offlinePassCount && !controller.isSyncing }
            XCTAssertTrue(resumed, "The retry survives the offline path and resumes without the index backoff")
            XCTAssertEqual(owners.values, Array(repeating: .manual, count: offlinePassCount + 1))
            await controller.shutdown()
        }

        func testAWiFiWaitNeverInheritsManualIntentFromAnotherRunsLock() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-foreign-manual-lock", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let scans = PassCounter()
            let releaseScan = LockedFlag(false)
            controller.replaceScanForTesting {
                _ = scans.increment()
                while !releaseScan.value, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            controller.syncNow()
            signals.resetReads()
            let paused = await waitUntil { scans.count == 1 && signals.hasBeenRead }
            XCTAssertTrue(paused)
            // Let the policy result settle while the scan still owns the foreground pass.
            try await Task.sleep(for: .milliseconds(300))
            try holdAutomaticPasses(in: fixture)
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let runID = try XCTUnwrap(controller.activeExecutionRunID)
            XCTAssertTrue(lock.release(runID: runID))
            XCTAssertTrue(lock.acquire(owner: .manual, runID: "another-manual-run").didAcquire)
            releaseScan.value = true
            let ended = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(ended)
            try await assertNoAutomaticResume(controller, "The foreground pass has settled on the expensive path")
            XCTAssertTrue(lock.release(runID: "another-manual-run"))

            signals.setWaitsForWiFi(false)
            signals.announceChange()

            let scheduled = await waitUntil { controller.isAutoResumeScheduledForTesting }
            XCTAssertTrue(scheduled, "An automatic pass still honors its own remote-index backoff")
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
            XCTAssertEqual(scans.count, 1, "Another run's manual lock cannot grant this controller a manual retry")
            await controller.shutdown()
        }

        func testAManualStartBeforeTheFirstNetworkPathStaysManual() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            // A system issue with a later retry date holds automatic passes; only an explicit action passes it.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))

            // This explicit action keeps the system issue, unlike "Back up now".
            await controller.retryUserResolvableWork()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the explicit pass waits for the first path")

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the first path starts the explicit pass, which passes the system issue")
            await controller.shutdown()
        }

        func testABackgroundWindowBeforeTheFirstNetworkPathRunsItsPassWhenThePathArrives() async throws {
            try await assertBackgroundWindowRunsTheDeferredPass(deliverPath: true)
        }

        func testABackgroundWindowWithoutANetworkPathRunsItsPassAfterTheBoundedWait() async throws {
            try await assertBackgroundWindowRunsTheDeferredPass(deliverPath: false)
        }

        /// The OS task of a background window ends when `backgroundCatchUp` returns. It must return once, after the
        /// deferred pass of the same kind ran inside the window.
        private func assertBackgroundWindowRunsTheDeferredPass(deliverPath: Bool) async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background", source: .mobileDataOff(runtime),
                firstNetworkPathWait: deliverPath ? .seconds(60) : .milliseconds(800))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }

            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 && firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the pass waits for the first path")
            XCTAssertEqual(windowEnds.count, 0, "the window stays open while its pass waits")
            if deliverPath {
                runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            } else {
                firstPathWait.releaseAll()
            }

            let ended = await waitUntil(timeout: .seconds(5)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "the window ends after its pass")
            XCTAssertEqual(scans.count, 1, "the deferred pass scanned inside the window")
            XCTAssertEqual(runs.count, 1, "the window received exactly one run")
            XCTAssertEqual(owners.values, [.iOSBackgroundTask], "the pass keeps the kind of the background window")
            let end = await window.value
            XCTAssertEqual(end, .done, "the pass ran after the path came or the first-path wait ended")
            XCTAssertEqual(windowEnds.count, 1, "the window ends exactly once")
            await controller.shutdown()
        }

        func testAnExpiringBackgroundWindowEndsAtOnceAndDropsItsDeferredPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-expired", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0)

            // The iOS expiration handler cancels the work of the window.
            window.cancel()

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "an expired window ends at once")
            XCTAssertEqual(runs.count, 0)
            let end = await window.value
            XCTAssertEqual(end, .noNetworkPath, "the window ended while its pass still waited for the first path")
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(scans.count, 0, "the pass of the expired window does not run after it")
            XCTAssertEqual(windowEnds.count, 1, "the window ends exactly once")
            await controller.shutdown()
        }

        func testAStartAfterACancelledFirstPathTimerStillWaitsForTheUnknownPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-cancel-restart", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstWait = HeldBackupSleepClock(clock: BackupTestClock())
            let nextWait = HeldBackupSleepClock(clock: BackupTestClock())
            defer {
                firstWait.releaseAll()
                nextWait.releaseAll()
            }
            let timerStarted = expectation(description: "The first timer entered its held sleep")
            let timerEnded = expectation(description: "The cancelled timer released its task capture")
            controller.replaceFirstNetworkPathSleepForTesting {
                [lifetime = FirstPathTimerLifetime(ended: timerEnded)] _ in
                timerStarted.fulfill()
                try? await firstWait.sleep(for: 60)
                withExtendedLifetime(lifetime) {}
            }
            let scans = PassCounter()
            let scanned = expectation(description: "The later pass scanned after the first path arrived")
            controller.replaceScanForTesting {
                _ = scans.increment()
                scanned.fulfill()
            }
            let windowEnded = expectation(description: "The expired background window ended")
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                windowEnded.fulfill()
            }
            await fulfillment(of: [timerStarted], timeout: 5)
            XCTAssertEqual(controller.deferredStartWaiterCountForTesting, 1)
            XCTAssertFalse(controller.isSyncing)

            // Drop the controller's copy. The old task alone retains the first sleep's capture.
            controller.replaceFirstNetworkPathSleepForTesting { _ in try? await nextWait.sleep(for: 60) }
            window.cancel()
            await fulfillment(of: [windowEnded], timeout: 5)
            await window.value
            firstWait.releaseAll()
            await fulfillment(of: [timerEnded], timeout: 5)

            controller.syncNow()

            XCTAssertFalse(controller.isSyncing, "A cancelled timer must not end the next start's first-path wait")
            XCTAssertEqual(scans.count, 0, "The unknown path must still defer the later pass")
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            await fulfillment(of: [scanned], timeout: 5)
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        private final class FirstPathTimerLifetime: Sendable {
            private let ended: XCTestExpectation

            init(ended: XCTestExpectation) { self.ended = ended }

            deinit { ended.fulfill() }
        }

        func testAnExpiringBackgroundWindowKeepsADeferredForegroundPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-foreground", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = scans.increment()
            }
            controller.syncNow()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            window.cancel()
            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the foreground pass that waited for the path still runs")
            XCTAssertEqual(owners.values, [.foreground])
            await controller.shutdown()
        }

        func testABackgroundWindowNeverOwnsADeferredManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = scans.increment()
            }
            await controller.retryUserResolvableWork()
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { windowEnds.count == 1 && scans.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(runs.count, 0, "the window cannot stop the explicit pass at its expiration")
            XCTAssertEqual(owners.values, [.manual])
            let end = await window.value
            XCTAssertEqual(end, .done, "the path came; the explicit pass runs on its own")
            await controller.shutdown()
        }

        func testABackgroundWindowCancelledBeforeItWaitsDropsItsDeferredPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-precancelled", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let release = LockedFlag(false)
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                while !release.value { await Task.yield() }
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            // The window expires before it reaches the wait.
            window.cancel()
            release.value = true

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(scans.count, 0, "the pass of the expired window does not run after it")
            await controller.shutdown()
        }

        func testAManualStartOutranksAForegroundStartThatAlreadyWaitsForTheFirstPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-foreground-then-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            // A system issue with a later retry date holds automatic passes; only an explicit action passes it.
            try holdAutomaticPasses(in: fixture)

            controller.syncNow()
            await controller.retryUserResolvableWork()
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && owners.values.count == 1 }
            XCTAssertTrue(started, "the explicit action that waited behind the automatic start runs")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testAnExpiringBackgroundWindowKeepsTheBoundOfADeferredForegroundPass() async throws {
            // The path monitor never reports, so only the bounded wait can start the foreground pass.
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-bound", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(2))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0, "the window waits for its deferred pass")
            window.cancel()
            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)
            firstPathWait.releaseAll()

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the foreground pass still starts when its bounded wait ends")
            await controller.shutdown()
        }

        func testABackgroundWindowThatCannotStartDoesNotWaitForAnotherWindowsDeferral() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-second-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting {}
            let firstEnds = PassCounter()
            let first = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = firstEnds.increment()
            }
            defer { first.cancel() }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(firstEnds.count, 0, "the first window waits for its deferred pass")

            // The person pauses the backup, so the next window has nothing to start and nothing to wait for.
            controller.pauseBackup()
            let secondEnds = PassCounter()
            let second = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .macOSBackgroundActivity)
                _ = secondEnds.increment()
            }
            defer { second.cancel() }

            let ended = await waitUntil(timeout: .seconds(2)) { secondEnds.count == 1 }
            XCTAssertTrue(ended, "a window that cannot start ends at once instead of waiting for the first path")
            await controller.shutdown()
        }

        func testShutdownEndsABackgroundWindowThatWaitsForTheFirstPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-shutdown", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            // macOS gives a background activity no expiration, so only the shutdown can end this window.
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .macOSBackgroundActivity) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
            }
            defer { window.cancel() }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0, "the window waits for its deferred pass")

            await controller.shutdown()

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "a sign-out ends the waiting window")
            XCTAssertEqual(runs.count, 0)
            XCTAssertEqual(scans.count, 0)
        }

        // MARK: Resume at launch against a background window (#472)

        // A background window can launch the app without a scene. The account start then creates the controller, whose
        // resume at launch starts an automatic foreground pass. The window and the resume reach the controller in
        // either order. While no scene is in the foreground, the window must run that pass inside its own time.

        func testAResumeAtLaunchThatWaitsForTheFirstPathHandsItsPassToALaterWindow() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-launch-resume-then-window", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true

            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            await controller.shutdown()
        }

        func testAWindowThatWaitsForTheFirstPathTakesThePassOfALaterResumeAtLaunch() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-window-then-launch-resume", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true

            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            await controller.shutdown()
        }

        func testAWindowRunsTheResumeAtLaunchWhenThePathArrivedBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            signals.setAppInBackground(true)
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-launch-resume-observer-gap", source: signals.source)
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")

            // Publish the snapshot without notifying the observer, as the real main-actor hop can lag the path.
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            signals.announceChange()
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertEqual(scan.starts.count, 1, "the observer starts no second pass")
            await controller.shutdown()
        }

        func testAWindowTakesOverAResumeAtLaunchThatIsAlreadyRunning() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-running-window")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan

            let window = startWindow(controller, scan: scan)
            let adopted = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            XCTAssertTrue(adopted, "the window takes over the running automatic pass")
            XCTAssertEqual(window.record.runIDs, [launch.runID], "the window holds the run of the resume")
            XCTAssertFalse(window.record.hasEnded, "the window stays open while the pass runs")

            scan.open.value = true
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.completedScansAtEnd, 1, "the window ends only after the pass")
            XCTAssertEqual(scan.starts.count, 1, "no second pass starts")
            XCTAssertEqual(scan.owners.values, [.foreground], "the run keeps the owner that started it")
            await window.task.value
            await controller.shutdown()
        }

        func testAnExpiredWindowStopsTheResumeAtLaunchItTookOverWhileTheAppStaysInTheBackground() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-window-expired")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            let runID = try XCTUnwrap(window.record.runIDs.first, "the window takes over the running pass")

            // An expiry that names another run stops nothing.
            controller.stopBackgroundWindowRun(runID: "an-earlier-run")
            XCTAssertFalse(controller.isRunnerStopPendingForTesting, "only the window's own run can be stopped")

            // The expiration handler cancels the window's work, then stops the run it holds.
            window.task.cancel()
            controller.stopBackgroundWindowRun(runID: runID)
            XCTAssertTrue(controller.isRunnerStopPendingForTesting, "the expiry stops the pass in the background")
            XCTAssertEqual(controller.runnerStopRunIDForTesting, runID)

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && !controller.isSyncing }
            XCTAssertTrue(ended, "the window and the stopped pass end")
            scan.open.value = true
            await window.task.value
            await controller.shutdown()
        }

        func testAnExpiredWindowKeepsTheResumeAtLaunchItTookOverOnceTheAppIsInTheForeground() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-window-foreground")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            let runID = try XCTUnwrap(window.record.runIDs.first, "the window takes over the running pass")

            // The person opens the app before the window expires; they now watch this pass.
            launch.runtime.update { $0.executionOpportunity = .foregroundActive }
            window.task.cancel()
            controller.stopBackgroundWindowRun(runID: runID)
            XCTAssertFalse(controller.isRunnerStopPendingForTesting, "the expiry does not stop a pass the person sees")
            XCTAssertEqual(controller.activeExecutionRunID, runID)

            // The pass stays held until the window processed its cancellation; then the pass may finish.
            _ = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            scan.open.value = true
            await window.task.value
            XCTAssertEqual(
                window.record.completedScansAtEnd, 0, "the window ended before the pass it gave back finished")
            let finished = await waitUntil(timeout: .seconds(5)) { !controller.isSyncing }
            XCTAssertTrue(finished)
            XCTAssertEqual(scan.completions.count, 1, "the pass the person sees runs to its end")
            XCTAssertFalse(controller.isRunnerStopPendingForTesting)
            await window.task.value
            await controller.shutdown()
        }

        func testAWindowNeverTakesOverARunningManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-running-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            _ = await waitUntil { scan.starts.count == 1 }
            XCTAssertEqual(scan.owners.values, [.manual])

            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(2)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends at once next to the explicit pass")
            XCTAssertEqual(window.record.runIDs, [], "the window can never stop the explicit pass at its expiration")
            scan.open.value = true
            await controller.shutdown()
        }

        func testAWindowOwnsItsPassWhenTheResumeAtLaunchComesLater() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-window-then-running-resume", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan

            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { scan.starts.count == 1 }
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            scan.open.value = true

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs.count, 1)
            XCTAssertEqual(scan.starts.count, 1, "the resume finds the running pass and starts none")
            XCTAssertEqual(scan.owners.values, [.iOSBackgroundTask])
            await window.task.value
            await controller.shutdown()
        }

        func testAWindowThatCannotTakeTheLockGivesTheResumeAtLaunchBack() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            signals.setAppInBackground(true)
            let launch = try makeLaunchResumeFixture(prefix: "backup-takeover-busy-lock", source: signals.source)
            defer { launch.cleanup() }
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: launch.fixture.directory.appendingPathComponent(
                        PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            await assertAFailedTakeoverGivesTheResumeBack(launch: launch, signals: signals) {
                XCTAssertTrue(lock.release(runID: "other-live-run"))
            }
        }

        func testAWindowThatFindsTheLockUnreadableGivesTheResumeAtLaunchBack() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            signals.setAppInBackground(true)
            // No busy wait, so the held write transaction below makes the lock unreadable at once.
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-takeover-unavailable-lock", source: signals.source,
                databasePolicy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0))
            defer { launch.cleanup() }
            let url = launch.fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)
            var writer: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
            defer { sqlite3_close(writer) }
            XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            await assertAFailedTakeoverGivesTheResumeBack(launch: launch, signals: signals) {
                XCTAssertEqual(sqlite3_exec(writer, "COMMIT;", nil, nil, nil), SQLITE_OK)
            }
        }

        /// The resume at launch waits for the path, the path arrives before its observer, and a window cannot start the
        /// pass it takes. The window ends without a run, the automatic pass stays pending, and the observer starts it.
        private func assertAFailedTakeoverGivesTheResumeBack(
            launch: LaunchResumeFixture, signals: FakeBackupRuntimeSignals, freeTheLock: () -> Void,
            file: StaticString = #filePath, line: UInt = #line
        ) async {
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, file: file, line: line)
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)

            let window = startWindow(controller, scan: scan)
            await window.task.value
            XCTAssertEqual(window.record.runIDs, [], "the window could not start a pass", file: file, line: line)
            XCTAssertEqual(
                controller.deferredStartOwnerForTesting, .foreground, "the automatic pass stays pending",
                file: file, line: line)

            freeTheLock()
            signals.announceChange()
            let ran = await waitUntil(timeout: .seconds(5)) { scan.completions.count == 1 && !controller.isSyncing }
            XCTAssertTrue(ran, "the observer starts the automatic pass", file: file, line: line)
            XCTAssertEqual(scan.owners.values, [.foreground], file: file, line: line)
            await controller.shutdown()
        }

        func testInTheForegroundAResumeAtLaunchThatWaitsForThePathKeepsItsPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-foreground-resume-window", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "a window never owns the pass of an open app")
            XCTAssertEqual(scan.owners.values, [.foreground])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheForegroundAWindowYieldsToAResumeAtLaunchThatWaitedBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-foreground-resume-observer-gap", source: signals.source)
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }

            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "a window never owns the pass of an open app")
            XCTAssertEqual(scan.owners.values, [.foreground])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheBackgroundAWindowNeverOwnsADeferredManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-background-deferred-manual-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.open.value = true
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "the window cannot stop the explicit pass at its expiration")
            XCTAssertEqual(scan.owners.values, [.manual])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheBackgroundAWindowNeverTakesADeferredManualPassBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            signals.setAppInBackground(true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-background-manual-observer-gap", source: signals.source,
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.open.value = true
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .manual)

            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "the window never owns or expires the deferred manual pass")
            XCTAssertEqual(scan.owners.values, [.manual])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheForegroundAWindowDoesNotTakeOverARunningResumeAtLaunch() async throws {
            let launch = try await makeRunningLaunchResume(
                prefix: "backup-foreground-running-resume-window", opportunity: .foregroundActive)
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan

            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(2)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends at once next to the pass of an open app")
            XCTAssertEqual(window.record.runIDs, [])
            scan.open.value = true
            await controller.shutdown()
        }

        /// The window ended once, after the one pass of the launch ran inside it with the window's own owner.
        private func assertWindowRanTheOnlyPass(
            _ window: BackgroundWindowProbe, scan: HeldScan, controller: PhotoLibraryBackupController,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends", file: file, line: line)
            XCTAssertEqual(window.record.runIDs.count, 1, "the window received the pass", file: file, line: line)
            XCTAssertEqual(
                window.record.completedScansAtEnd, 1, "the pass ran inside the window", file: file, line: line)
            XCTAssertEqual(
                scan.owners.values, [.iOSBackgroundTask], "the pass has the window's owner", file: file, line: line)
            XCTAssertNil(controller.deferredStartOwnerForTesting, "no resume is left waiting", file: file, line: line)
            await window.task.value
        }

        /// A backup that is on at launch with a determined path, whose resume at launch already runs and holds its scan.
        private func makeRunningLaunchResume(
            prefix: String, opportunity: LibraryExecutionOpportunity = .backgroundPermitted
        ) async throws -> (fixture: LaunchResumeFixture, runtime: LibraryRuntimeState, runID: String) {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = opportunity
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeLaunchResumeFixture(prefix: prefix, source: .mobileDataOff(runtime))
            fixture.releaseResume()
            _ = await waitUntil { fixture.scan.starts.count == 1 }
            XCTAssertEqual(fixture.scan.owners.values, [.foreground], "the resume at launch runs an automatic pass")
            let runID = try XCTUnwrap(fixture.controller.activeExecutionRunID)
            return (fixture, runtime, runID)
        }

        /// A backup that is on at launch, so the real resume at launch runs; the test decides when it may start.
        private func makeLaunchResumeFixture(
            prefix: String, source: BackupRuntimeSignalSource, databasePolicy: LibraryDatabasePolicy = .conservative
        ) throws -> LaunchResumeFixture {
            let suite = "\(prefix)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "photoBackup.enabled.v1")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: directory, databasePolicy: databasePolicy, defaults: defaults,
                runtimeSignals: source, firstNetworkPathWait: .seconds(60))
            configuration.currentAccessState = { .full }
            let controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: FakeIdentityResolver(), uploader: MockUploader())
            // Installed before the first await, so the resume at launch cannot pass the gate unseen.
            let gate = HeldBackupSleepClock(clock: BackupTestClock())
            controller.holdLaunchResumeForTesting { try? await gate.sleep(for: 0) }
            let scan = HeldScan()
            scan.install(on: controller)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .fileURL, identifier: "waiting-photo"), revision: .init(rawValue: 1),
                        originalFilename: "waiting-photo.jpg", state: .discovered, lastError: nil,
                        updatedAt: Date().addingTimeInterval(-60))))
            queue.close()
            return LaunchResumeFixture(
                fixture: ControllerFixture(
                    controller: controller, defaults: defaults, suite: suite, directory: directory),
                gate: gate, scan: scan)
        }

        private struct LaunchResumeFixture {
            let fixture: ControllerFixture
            let gate: HeldBackupSleepClock
            let scan: HeldScan

            var controller: PhotoLibraryBackupController { fixture.controller }

            func releaseResume() { gate.releaseAll() }

            func cleanup() {
                gate.releaseAll()
                scan.open.value = true
                fixture.cleanup()
            }
        }

        private struct BackgroundWindowProbe {
            let task: Task<Void, Never>
            let record: BackgroundWindowRecord
        }

        private func startWindow(_ controller: PhotoLibraryBackupController, scan: HeldScan) -> BackgroundWindowProbe {
            let record = BackgroundWindowRecord()
            let task = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { record.received($0) }
                record.end(completedScans: scan.completions.count)
            }
            return BackgroundWindowProbe(task: task, record: record)
        }

        /// Holds the wait for the first network path until the test releases it, so the bounded wait ends on cue.
        private func holdFirstNetworkPathWait(of controller: PhotoLibraryBackupController) -> HeldBackupSleepClock {
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            controller.replaceFirstNetworkPathSleepForTesting { wait in
                let (seconds, attoseconds) = wait.components
                try? await clock.sleep(for: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
            }
            return clock
        }

        // MARK: Refresh window (#832)

        /// A backup with one runnable photo in the queue, while no scene is in the foreground unless `inForeground`. The
        /// network is known and usable unless `networkKnown` is false.
        private func makeRefreshFixture(
            prefix: String, networkKnown: Bool = true, inForeground: Bool = false
        ) throws -> ControllerFixture {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = inForeground ? .foregroundActive : .backgroundPermitted }
            if networkKnown {
                runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            }
            return try makeWiFiWaitFixture(
                prefix: prefix, source: .mobileDataOff(runtime), firstNetworkPathWait: .seconds(60))
        }

        private func queueSummary(_ fixture: ControllerFixture) throws -> UploadBackupSyncQueueSummary {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            return queue.summary()
        }

        func testARefreshScanScansUnderItsOwnOwnerAndUploadsNothing() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-only")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            let before = try queueSummary(fixture)
            XCTAssertEqual(before.waiting, 1, "one photo waits for its upload")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(owners.values, [.iOSRefreshTask])
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "the runner never drains, so nothing uploads")
            XCTAssertEqual(try queueSummary(fixture), before, "the photo still waits")
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, "a refresh scan in the background plans no pass")
            XCTAssertFalse(controller.isSyncing)
            // The counter sees a drain: an ordinary pass of the same backup starts one.
            controller.syncNow()
            let drained = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(drained, "an ordinary pass starts the reconcile loop")
            await controller.shutdown()
        }

        /// A scene came to the foreground during the scan and found the pass busy. The end of the scan then plans the
        /// next pass as every pass does, so the person's backup does not wait for the next change.
        func testARefreshScanThatEndsInTheForegroundPlansTheNextPassAsBefore() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-foreground", inForeground: true)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(controller.consecutiveNoProgressRunsForTesting, 0, "a scan is no pass without progress")
            let passStarted = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(passStarted, "the person's pass starts after the scan")
            await controller.shutdown()
        }

        func testARefreshScanDoesNotWaitForTheFirstNetworkPath() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-no-path", networkKnown: false)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned, "a scan needs no network")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(controller.deferredStartWaiterCountForTesting, 0)
            await controller.shutdown()
        }

        func testARefreshScanStartsNothingWhileAnotherPassRuns() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-busy")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let release = LockedFlag(false)
            controller.replaceScanForTesting {
                _ = scans.increment()
                while !release.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            }
            controller.syncNow()
            let running = await waitUntil { scans.count == 1 }
            XCTAssertTrue(running)

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded, "the running pass scans too")
            XCTAssertEqual(scans.count, 1, "never a second scan")
            release.value = true
            await controller.waitForSyncRunCompletionForTesting()
            await controller.shutdown()
        }

        /// A pass that waits for the first network path keeps its start: the refresh scan does not take the lock it
        /// would need when the path arrives.
        func testARefreshScanStartsNothingWhileAPassWaitsForTheFirstNetworkPath() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-deferred", networkKnown: false)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            XCTAssertFalse(controller.isSyncing, "the pass waits for the first path")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded)
            XCTAssertEqual(scans.count, 0)
            await controller.shutdown()
        }

        /// A long window whose pass waits for the first network path keeps its start as well.
        func testARefreshScanStartsNothingWhileALongWindowWaitsForTheFirstNetworkPath() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-window-waits", networkKnown: false)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let waiting = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertTrue(waiting, "the long window waits for the first path")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded)
            XCTAssertEqual(scans.count, 0)
            window.cancel()
            _ = await window.value
            await controller.shutdown()
        }

        /// A long window arrives while a refresh scan runs. The scan yields its lock, and the long window's pass scans and
        /// uploads; the refresh window needed nothing.
        func testALongWindowTakesTheLockOverFromARefreshScan() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-yields")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let refresh = Task { @MainActor in
                await self.runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)

            // A long window that does not stop the scan would wait for it forever; the watchdog bounds the test.
            let watchdogFired = LockedFlag(false)
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                watchdogFired.value = true
                controller.stopSync()
            }
            let longWindow = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let catchUp = await longWindow.value
            watchdog.cancel()

            XCTAssertFalse(watchdogFired.value, "the long window stopped the scan itself")
            XCTAssertEqual(catchUp, .done)
            XCTAssertEqual(owners.values, [.iOSRefreshTask, .iOSBackgroundTask], "the long window's pass scanned")
            XCTAssertEqual(controller.reconcileStartsForTesting, 1, "the long window's pass drained the queue")
            // A scan that did not yield would hold forever; stopping it bounds the test.
            controller.stopSync()
            let refreshOutcome = await refresh.value
            XCTAssertEqual(refreshOutcome, .notNeeded)
            await controller.shutdown()
        }

        /// The long window expired while the scan it stopped came to its end: it starts no pass.
        func testAnExpiredLongWindowStartsNoPassAfterTheRefreshScanEnded() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-yield-expired")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let release = LockedFlag(false)
            controller.replaceScanForTesting {
                // The first scan ends only when the test releases it, also after a stop.
                if scans.increment() == 1 {
                    while !release.value { try? await Task.sleep(for: .milliseconds(10)) }
                }
            }
            let refresh = Task { @MainActor in await controller.backgroundRefreshScan() }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let stopping = await waitUntil { controller.isRunnerStopPendingForTesting }
            XCTAssertTrue(stopping, "the long window stopped the scan")

            // The iOS expiration handler cancels the long window's work while it waits for the scan's end.
            window.cancel()
            release.value = true

            let end = await window.value
            XCTAssertEqual(end, .done)
            _ = await refresh.value
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "an expired window starts no pass")
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        /// Another run holds the lock, for example after a crash of a run whose lease has not ended yet. Its pass
        /// covers the scan: nothing was needed.
        func testARefreshScanWhileAnotherRunHoldsTheLockIsNotNeeded() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-busy-lock")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .notNeeded)
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            XCTAssertEqual(outcome, .notNeeded)
            XCTAssertEqual(scans.count, 0)
            XCTAssertTrue(lock.release(runID: "other-live-run"))
            await controller.shutdown()
        }

        /// The retry date of the remote index holds upload passes, not the scan.
        func testARefreshScanRunsWhileTheRemoteIndexWaitsForItsRetry() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-index-retry")
            defer { fixture.cleanup() }
            try holdAutomaticPasses(in: fixture)
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        /// The person's retry waits for Wi-Fi, which is back. The refresh window must not start that upload pass.
        func testARefreshScanNeverStartsTheResumedManualRetry() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "refresh-scan-manual-retry", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { controller.status.phase == .waitingForWiFi && !controller.isSyncing }
            XCTAssertTrue(waiting, "the manual pass waits for Wi-Fi")
            // Publish the snapshot without notifying the observer: the retry could resume now.
            signals.setWaitsForWiFi(false)

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(owners.values, [.manual, .iOSRefreshTask])
            await controller.shutdown()
        }

        func testTheEndOfTheWindowStopsTheRefreshScanAndFreesTheLock() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-stopped")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting {
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let runIDs = OwnerRecorder()
            let window = Task { @MainActor in
                await controller.backgroundRefreshScan { runIDs.record(BackupExecutionOwner(rawValue: $0)) }
            }
            let started = await waitUntil { scans.count == 1 && !runIDs.values.isEmpty }
            XCTAssertTrue(started)

            let runID = try XCTUnwrap(runIDs.values.first ?? nil).rawValue
            controller.stopBackgroundWindowRun(runID: runID)

            let end = await window.value
            XCTAssertEqual(end, .stopped)
            let next = await controller.backgroundRefreshScan()
            XCTAssertEqual(next, .scanned, "the stopped scan released the lock")
            XCTAssertEqual(scans.count, 2)
            await controller.shutdown()
        }

        private final class WindowEvents {
            var values: [String] = []
            var limit: Duration?
        }

        private func runRefreshWindow(
            events: WindowEvents, lowPower: Bool = false, didExpire: (() -> Bool)? = nil,
            wait: BackgroundAccountWait<PhotoLibraryBackupController>
        ) async -> BackgroundWindowOutcome {
            await PhotoLibraryRefreshWindow.run(
                scheduleNext: { events.values.append("next") },
                isLowPowerModeOn: { lowPower },
                startAccount: { events.values.append("account") },
                waitForController: { limit in
                    events.values.append("wait")
                    events.limit = limit
                    return wait
                },
                didExpire: didExpire ?? { false },
                backupStopped: { events.values.append("backup stopped") },
                backupPaused: { events.values.append("backup paused") },
                onRunStarted: { _ in })
        }

        func testARefreshWindowSubmitsItsNextRequestFirstAndWaitsFifteenSecondsForTheAccount() async {
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .cannotRun(.noAccount))
            XCTAssertEqual(events.values, ["next", "account", "wait"])
            XCTAssertEqual(events.limit, .seconds(15))
            XCTAssertEqual(outcome, .noAccount)
        }

        func testARefreshWindowInLowPowerModeDoesNothing() async {
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, lowPower: true, wait: .notReady)
            XCTAssertEqual(outcome, .notNeeded)
            XCTAssertEqual(events.values, ["next"], "no account start and no scan")
        }

        func testARefreshWindowWithoutItsAccountRecordsWhy() async {
            let locked = await runRefreshWindow(events: WindowEvents(), wait: .cannotRun(.endedAtOnceLocked))
            XCTAssertEqual(locked, .endedAtOnceLocked)
            let late = await runRefreshWindow(events: WindowEvents(), wait: .notReady)
            XCTAssertEqual(late, .failed)
            let expired = await runRefreshWindow(events: WindowEvents(), didExpire: { true }, wait: .notReady)
            XCTAssertEqual(expired, .expired)
        }

        func testARefreshWindowWithBackupOffOrPausedScansNothing() async throws {
            let off = try makeControllerFixture(prefix: "refresh-window-off")
            defer { off.cleanup() }
            let offScans = PassCounter()
            off.controller.replaceScanForTesting { _ = offScans.increment() }
            let offEvents = WindowEvents()
            let offOutcome = await runRefreshWindow(events: offEvents, wait: .ready(off.controller))
            XCTAssertEqual(offOutcome, .notNeeded)
            XCTAssertEqual(offScans.count, 0)
            XCTAssertEqual(offEvents.values.last, "backup stopped", "as the long window, the window stops scheduling")
            await off.controller.shutdown()

            let paused = try makeRefreshFixture(prefix: "refresh-window-paused")
            defer { paused.cleanup() }
            let pausedScans = PassCounter()
            paused.controller.replaceScanForTesting { _ = pausedScans.increment() }
            paused.controller.pauseBackup()
            let pausedEvents = WindowEvents()
            let pausedOutcome = await runRefreshWindow(events: pausedEvents, wait: .ready(paused.controller))
            XCTAssertEqual(pausedOutcome, .notNeeded)
            XCTAssertEqual(pausedScans.count, 0)
            XCTAssertEqual(pausedEvents.values.last, "backup paused")
            await paused.controller.shutdown()
        }

        /// The window expired while it waited for the account: no scan starts in it.
        func testARefreshWindowThatExpiredDuringTheAccountWaitScansNothing() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired")
            defer { fixture.cleanup() }
            let scans = PassCounter()
            fixture.controller.replaceScanForTesting { _ = scans.increment() }
            let outcome = await runRefreshWindow(
                events: WindowEvents(), didExpire: { true }, wait: .ready(fixture.controller))
            XCTAssertEqual(outcome, .expired)
            XCTAssertEqual(scans.count, 0)
            await fixture.controller.shutdown()
        }

        func testARefreshWindowWhoseScanWasStoppedFailed() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-stopped")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting {
                await MainActor.run { controller.stopSync() }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()
            }
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            XCTAssertEqual(outcome, .failed, "a scan stopped before the window's end did not do its work")
            await controller.shutdown()
        }

        func testARefreshWindowThatExpiredDuringItsScanExpired() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired-scan")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let expired = LockedFlag(false)
            controller.replaceScanForTesting {
                expired.value = true
                await MainActor.run { controller.stopSync() }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()
            }
            let outcome = await runRefreshWindow(
                events: WindowEvents(), didExpire: { expired.value }, wait: .ready(controller))
            XCTAssertEqual(outcome, .expired)
            await controller.shutdown()
        }

        func testARefreshWindowThatExpiredAfterItsScanExpired() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired-after-scan")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let expired = LockedFlag(false)
            controller.replaceScanForTesting { expired.value = true }
            let outcome = await runRefreshWindow(
                events: WindowEvents(), didExpire: { expired.value }, wait: .ready(controller))
            XCTAssertEqual(outcome, .expired, "an expiry decides first, as for every window")
            await controller.shutdown()
        }

        func testARefreshScanThatFailsReportsAFailure() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-fails")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { throw UploadError.backend("scan state could not be saved") }
            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .failed)
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            XCTAssertEqual(outcome, .failed)
            await controller.shutdown()
        }

        /// Without photo access no scan can start; that is a failure, not "nothing needed".
        func testARefreshWindowWithoutPhotoAccessFails() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-no-access")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.setAccessStateForTesting(.denied)
            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .couldNotStart)
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(scans.count, 0)
            await controller.shutdown()
        }

        /// The window's end stops a scan while a scene is in the foreground and the queue is empty. The person's pass
        /// starts after it, and the stopped scan does not count as a pass without progress.
        func testARefreshScanStoppedInTheForegroundStartsThePersonsPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeControllerFixture(
                prefix: "refresh-scan-foreground-stopped", identityResolver: FakeIdentityResolver(),
                runtimeSignals: .mobileDataOff(runtime))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            // An empty queue, as after a finished backup.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertEqual(queue.summary().total, 0)
            queue.close()
            let scans = PassCounter()
            controller.replaceScanForTesting {
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let runIDs = OwnerRecorder()
            let window = Task { @MainActor in
                await controller.backgroundRefreshScan { runIDs.record(BackupExecutionOwner(rawValue: $0)) }
            }
            let started = await waitUntil { scans.count == 1 && !runIDs.values.isEmpty }
            XCTAssertTrue(started)
            guard let runID = runIDs.values.first??.rawValue else {
                window.cancel()
                _ = await window.value
                return XCTFail("the refresh scan did not start")
            }

            controller.stopBackgroundWindowRun(runID: runID)

            let end = await window.value
            XCTAssertEqual(end, .stopped)
            XCTAssertEqual(controller.consecutiveNoProgressRunsForTesting, 0)
            let passStarted = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(passStarted, "the person's pass starts after the stopped scan")
            await controller.shutdown()
        }

        func testARefreshWindowThatScannedRan() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-ran")
            defer { fixture.cleanup() }
            let scans = PassCounter()
            fixture.controller.replaceScanForTesting { _ = scans.increment() }
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(fixture.controller))
            XCTAssertEqual(outcome, .ran)
            XCTAssertEqual(scans.count, 1)
            await fixture.controller.shutdown()
        }

        func testARefreshWindowIsRecordedAsItsOwnKind() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "refresh-window-kind-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ledger = BackgroundWindowLedger(
                fileURL: directory.appendingPathComponent("windows.json"), isPurgePending: { false })
            let heard = LockedFlag(true)
            let completion = PhotoLibraryRefreshWindow.begin(ledger: ledger) { heard.value = $0 }
            await completion.finish(.notNeeded, after: {})
            XCTAssertEqual(ledger.records().map(\.kind), [.libraryRefresh])
            XCTAssertEqual(ledger.supportSnapshot().counts.map(\.kind), [.libraryRefresh])
        }

        /// Records a remote index issue with a retry date in an hour, which holds every pass except an explicit one.
        private func holdAutomaticPasses(in fixture: ControllerFixture) throws {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
        }

        private func runtimeSource(_ runtime: LibraryRuntimeState, usesMobileData: Bool) -> BackupRuntimeSignalSource {
            BackupRuntimeSignalSource(
                current: { BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: usesMobileData) },
                updates: { runtime.updates() })
        }

        /// A backup with one runnable row whose scan never touches PhotoKit; only the runner drains.
        private func makeWiFiWaitFixture(
            prefix: String, source: BackupRuntimeSignalSource, dismissedSourceRecheck: Bool = false,
            firstNetworkPathWait: Duration = .seconds(10)
        ) throws -> ControllerFixture {
            let fixture = try makeControllerFixture(
                prefix: prefix, identityResolver: FakeIdentityResolver(), runtimeSignals: source,
                firstNetworkPathWait: firstNetworkPathWait)
            fixture.controller.setEnabledForTesting()
            fixture.controller.setAccessStateForTesting(.full)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(
                            kind: dismissedSourceRecheck ? .photoLibraryAsset : .fileURL, identifier: "waiting-photo"),
                        revision: .init(rawValue: 1), originalFilename: "waiting-photo.jpg", state: .discovered,
                        lastError: dismissedSourceRecheck
                            ? BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
                            : nil,
                        updatedAt: Date().addingTimeInterval(-60))))
            queue.close()
            return fixture
        }
    #endif

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

    func testBackupThatIsOffAtLaunchOrTurnedOffReportsThatNoIndexBuildIsNeeded() async throws {
        let resolver = FakeIdentityResolver()
        let fixture = try makeControllerFixture(prefix: "backup-off-index", enabled: false, identityResolver: resolver)
        defer { fixture.cleanup() }
        try await waitForReports(1, from: resolver, "a launch with backup off")

        fixture.controller.disableBackup()
        try await waitForReports(2, from: resolver, "turning backup off")
    }

    #if DEBUG
        func testTurningBackupOffThatWasOnReportsThatNoIndexBuildIsNeeded() async throws {
            let resolver = FakeIdentityResolver()
            let fixture = try makeControllerFixture(prefix: "backup-on-off-index", identityResolver: resolver)
            defer { fixture.cleanup() }
            try await waitForReports(1, from: resolver, "a launch with backup off")
            fixture.controller.setEnabledForTesting()

            fixture.controller.disableBackup()
            try await waitForReports(2, from: resolver, "turning backup off after it was on")
        }

        func testAPassWhoseScanFinishedWithNothingToUploadReportsThatNoIndexBuildIsNeeded() async throws {
            let resolver = FakeIdentityResolver()
            let reports = try await reportsAfterAPass(prefix: "backup-scan-done-index", resolver: resolver) {}
            XCTAssertEqual(reports, 1, "the finished scan found nothing, so no index build follows")
        }

        func testAPassWhoseScanFailedReportsNothing() async throws {
            let resolver = FakeIdentityResolver()
            let reports = try await reportsAfterAPass(prefix: "backup-scan-failed-index", resolver: resolver) {
                throw UploadError.backend("Photo library scan state could not be saved")
            }
            XCTAssertEqual(reports, 0, "a scan that did not finish may have missed photos that start an index build")
        }

        /// Runs one pass over an empty queue with `scan` in place of the photo library scan, and returns the reports of
        /// no index build that the pass sent. The launch with backup off reports once before the pass; it is not
        /// counted.
        private func reportsAfterAPass(
            prefix: String, resolver: FakeIdentityResolver, scan: @escaping @Sendable () async throws -> Void
        ) async throws -> Int {
            let fixture = try makeControllerFixture(
                prefix: prefix, identityResolver: resolver, runtimeSignals: .wiFiWithMobileDataOff)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try await waitForReports(1, from: resolver, "a launch with backup off")
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                try await scan()
            }

            controller.syncNow()
            let finished = await waitUntil(timeout: .seconds(10)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the pass must run its scan and end")
            let reports = resolver.remoteIndexPreparationNotNeededCount - 1
            await controller.shutdown()
            return reports
        }
    #endif

    private func waitForReports(
        _ count: Int, from resolver: FakeIdentityResolver, _ description: String, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while resolver.remoteIndexPreparationNotNeededCount < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            resolver.remoteIndexPreparationNotNeededCount, count, "\(description) reports no index build", file: file,
            line: line)
    }

    private func makeControllerFixture(
        prefix: String, enabled: Bool = false, identityResolver: (any UploadIdentityResolving)? = nil,
        runtimeSignals: BackupRuntimeSignalSource = .apple, firstNetworkPathWait: Duration = .seconds(10)
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
                runtimeSignals: runtimeSignals,
                firstNetworkPathWait: firstNetworkPathWait
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
    private var networkDetermined: Bool
    private var networkAvailable = true
    private var usesMobileData = false
    private var appInBackground = false
    private var reads = 0
    private var continuations: [AsyncStream<LibraryRuntimeSnapshot>.Continuation] = []

    init(waitsForWiFi: Bool, networkDetermined: Bool = true) {
        self.waitsForWiFi = waitsForWiFi
        self.networkDetermined = networkDetermined
    }

    var source: BackupRuntimeSignalSource {
        BackupRuntimeSignalSource(
            current: { self.read() },
            updates: { AsyncStream { continuation in self.lock.withLock { self.continuations.append(continuation) } } }
        )
    }

    func setWaitsForWiFi(_ value: Bool) { lock.withLock { waitsForWiFi = value } }

    func setNetworkAvailable(_ value: Bool) { lock.withLock { networkAvailable = value } }

    func setUsesMobileData(_ value: Bool) { lock.withLock { usesMobileData = value } }

    func setAppInBackground(_ value: Bool) { lock.withLock { appInBackground = value } }

    var hasBeenRead: Bool { lock.withLock { reads > 0 } }

    func resetReads() { lock.withLock { reads = 0 } }

    func setNetworkDetermined(_ value: Bool) { lock.withLock { networkDetermined = value } }

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
            return BackupThrottleInputs(
                isNetworkAvailable: networkAvailable, isNetworkExpensive: waitsForWiFi, usesMobileData: usesMobileData,
                isNetworkDetermined: networkDetermined, isAppInBackground: appInBackground)
        }
    }
}

#if DEBUG
    /// A scan that records its owner and runs until the test opens it. A stop cancels it before it completes.
    private final class HeldScan: @unchecked Sendable {
        let starts = PassCounter()
        let completions = PassCounter()
        let owners = OwnerRecorder()
        let open = LockedFlag(false)

        @MainActor
        func install(on controller: PhotoLibraryBackupController) {
            controller.replaceScanForTesting { [self] in
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = starts.increment()
                while !open.value { try await Task.sleep(for: .milliseconds(5)) }
                _ = completions.increment()
            }
        }
    }
#endif

/// What one background window received from `backgroundCatchUp`, and how many scans had completed when it ended.
private final class BackgroundWindowRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var scansAtEnd: Int?

    var runIDs: [String] { lock.withLock { ids } }
    var hasEnded: Bool { lock.withLock { scansAtEnd != nil } }
    var completedScansAtEnd: Int? { lock.withLock { scansAtEnd } }

    func received(_ runID: String) { lock.withLock { ids.append(runID) } }
    func end(completedScans: Int) { lock.withLock { scansAtEnd = completedScans } }
}

private final class OwnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BackupExecutionOwner?] = []

    var values: [BackupExecutionOwner?] { lock.withLock { recorded } }

    func record(_ owner: BackupExecutionOwner?) { lock.withLock { recorded.append(owner) } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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

extension PhotoLibraryBackupControllerStateTests {
    private final class RestoreAdmissionStateSpy: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var writes = 0
        var upsertCount: Int { lock.withLock { writes } }
        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            nil
        }
        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { false }
        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { writes += 1 }
            return true
        }
        func count() -> Int { 0 }
    }

    func testRestoreAdmissionDistinguishesUnsupportedStoreFromOwnedWorkWithoutWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for terminal in [true, false] {
            let inner = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
            )
            defer { inner.close() }
            let snapshot = UploadBackupAssetSnapshot(
                source: .init(kind: .photoLibraryAsset, identifier: "restored"),
                revision: .init(rawValue: 42), resourceCount: 2)
            let candidate = UploadBackupAssetCandidate(
                snapshot: snapshot, originalFilename: "restored.heic", byteCount: 1)
            let row = UploadBackupSyncQueueEntry(
                source: snapshot.source, revision: snapshot.revision, originalFilename: candidate.originalFilename,
                state: terminal ? .completed : .uploading, attempts: 3,
                lastError: "kept", updatedAt: Date(timeIntervalSince1970: 1_000))
            XCTAssertTrue(inner.upsert(row))
            let log = BackupEventLog()
            let queue: any UploadBackupSyncQueueStore = SpyQueueStore(inner: inner, log: log)
            let state = RestoreAdmissionStateSpy()
            let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)
            let before = Date()

            let outcome = await PhotoLibraryBackupController.restoredCompoundDeferral(
                engine: engine, candidate: candidate, isCurrent: { true })

            if terminal {
                XCTAssertEqual(outcome, .unreadable, "Unsupported must not become another ordinary 30-second wait")
            } else {
                guard case .waiting(let until)? = outcome else { return XCTFail("Owned active work must still wait") }
                XCTAssertGreaterThanOrEqual(until, before.addingTimeInterval(30))
                XCTAssertLessThanOrEqual(until, Date().addingTimeInterval(30))
            }
            XCTAssertEqual(state.upsertCount, 0)
            XCTAssertTrue(log.events.isEmpty)
            XCTAssertEqual(inner.entry(for: row.source, revision: row.revision), row)
            XCTAssertTrue(inner.isOperational())
        }
    }
}

extension PhotoLibraryBackupControllerStateTests {
    private final class Restore829Resolver: BackupResourceResolving, @unchecked Sendable {
        let candidate: UploadBackupAssetCandidate
        let primary: UploadResourceDescriptor
        let secondaries: [BackupSecondaryResource]
        let mediaType: String
        private let lock = NSLock()
        private var omitted = false
        private var reads = 0
        var resolveCount: Int { lock.withLock { reads } }
        func omitSecondary(_ value: Bool) { lock.withLock { omitted = value } }
        init(
            candidate: UploadBackupAssetCandidate, primary: UploadResourceDescriptor,
            secondaries: [BackupSecondaryResource], mediaType: String
        ) {
            self.candidate = candidate
            self.primary = primary
            self.secondaries = secondaries
            self.mediaType = mediaType
        }
        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            let omit = lock.withLock {
                reads += 1
                return omitted
            }
            return BackupResolvedResource(
                candidate: candidate, descriptor: primary, mediaType: mediaType,
                captureDate: primary.modificationDate, secondaries: omit ? [] : secondaries)
        }
    }

    @MainActor private final class Restore829Fixture {
        enum Shape: Equatable { case photo, video, live, burst }
        let shape: Shape
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let server = EditScenarioServer()
        let clock = BackupTestClock(start: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 2))
        var controller: PhotoLibraryBackupController!
        var pending: PendingBackupManifestStore!
        var identities: UploadIdentityManifestStore!
        var state: UploadBackupStateManifestStore!
        var catalog: PhotoLibraryCatalogManifestStore!
        var pipeline: UploadDedupePipeline!
        var runner: BackupSyncRunner!
        var resolver: Restore829Resolver!
        var queue: UploadBackupSyncQueueManifestStore { controller.queueStoreForTesting! }
        var key: PendingSourceKey { PendingSourceKey(resolver.candidate.snapshot.source) }

        init(shape: Shape) throws {
            self.shape = shape
            suite = "restore-829-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try open()
        }

        private func open() throws {
            pending = try XCTUnwrap(
                PendingBackupManifestStore(
                    url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
            identities = try XCTUnwrap(
                UploadIdentityManifestStore(
                    url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
            pipeline = UploadDedupePipeline(store: identities, checker: server, now: { [clock] in clock.now })
            controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                identityResolver: pipeline, uploader: server, pendingStore: pending, requiresPendingStore: true)
            state = try XCTUnwrap(
                UploadBackupStateManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
            catalog = try XCTUnwrap(
                PhotoLibraryCatalogManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName)))
            let date = Date(timeIntervalSince1970: 1_720_000_000)
            let mainRole: PhotoBackupAssetInfo.Resource.Role = shape == .video ? .originalVideo : .originalPhoto
            var resources: [PhotoBackupAssetInfo.Resource] = [
                .init(
                    role: mainRole,
                    originalFilename: shape == .video ? "MAIN.MOV" : "MAIN.HEIC",
                    mimeType: shape == .video ? "video/quicktime" : "image/heic")
            ]
            if shape == .live {
                resources.append(.init(role: .pairedVideo, originalFilename: "PAIR.MOV", mimeType: "video/quicktime"))
            }
            if shape == .burst {
                resources.append(.init(role: .burstMember, originalFilename: "MEMBER.HEIC", mimeType: "image/heic"))
            }
            let info = PhotoBackupAssetInfo(
                localIdentifier: "restore-asset", creationDate: date, modificationDate: date,
                pixelWidth: 10, pixelHeight: 10, durationSeconds: shape == .video || shape == .live ? 1 : 0,
                isLivePhoto: shape == .live, isVideo: shape == .video, resources: resources)
            let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
            let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
            if catalog.entry(for: info.localIdentifier) == nil {
                XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: clock.now)]))
            }
            func descriptor(_ item: PhotoBackupExportPlan.Item, primary: Bool) throws -> UploadResourceDescriptor {
                let url = directory.appendingPathComponent(item.uploadFilename)
                let bytes = Data("restore-829-\(item.uploadFilename)".utf8)
                try bytes.write(to: url)
                return UploadResourceDescriptor(
                    source: .init(
                        kind: .photoLibraryAsset, identifier: info.localIdentifier,
                        resource: primary ? .primary : item.sourceResource), fileURL: url,
                    filename: item.uploadFilename,
                    fileSize: Int64(bytes.count), modificationDate: date,
                    precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: url))
            }
            resolver = Restore829Resolver(
                candidate: candidate, primary: try descriptor(plan.primary, primary: true),
                secondaries: try plan.secondaries.map {
                    BackupSecondaryResource(
                        descriptor: try descriptor($0, primary: false), mediaType: $0.mimeType ?? "image/heic")
                },
                mediaType: plan.primary.mimeType ?? "image/heic")
            runner = BackupSyncRunner(
                queue: queue, preflight: UploadBackupPreflightIndex(store: state, now: { [clock] in clock.now }),
                resolver: resolver, identityResolver: pipeline, uploader: server,
                configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock,
                events: controller.pendingRecorder, now: { [clock] in clock.now })
        }

        func initialBackup(omittingSecondary: Bool = false) async throws -> PhotoUID {
            resolver.omitSecondary(omittingSecondary)
            let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)
            _ = try await engine.enqueueBatch([resolver.candidate])
            await drain()
            XCTAssertTrue(
                try XCTUnwrap(
                    queue.entry(
                        for: resolver.candidate.snapshot.source,
                        revision: resolver.candidate.snapshot.revision)
                ).state.isTerminalSuccess, "Initial completion must come from the real runner")
            let main = try XCTUnwrap(identities.record(for: resolver.candidate.snapshot.source)?.remoteLinkID)
            resolver.omitSecondary(false)
            return PhotoUID(volumeID: "vol", nodeID: main)
        }

        func restoredState(
            _ main: PhotoUID, retainMemberTrash: Bool = false, marker: Bool = false
        ) throws -> PendingSourceState {
            let excluded = try XCTUnwrap(
                pending.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: main)], at: clock.now)?
                    .first)
            if marker { XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: [excluded]), [key]) }
            for link in server.links { server.personTrash(link.uid) }
            for link in server.links { server.personRestore(link.uid) }
            if !marker {
                XCTAssertTrue(
                    pending.completeEffect(
                        .remoteTrash, for: key, generation: excluded.generation, remoteLinkID: main.nodeID,
                        at: clock.now))
            }
            XCTAssertTrue(pending.completeEffect(.queueSync, for: key, generation: excluded.generation, at: clock.now))
            if retainMemberTrash {
                for secondary in resolver.secondaries {
                    var row = try XCTUnwrap(identities.record(for: secondary.descriptor.source))
                    row.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
                    XCTAssertTrue(identities.upsert(row))
                }
            }
            return try XCTUnwrap(pending.includeRestoredInProton([key], confirmedRemotes: [main], at: clock.now)?.first)
        }

        func drain() async {
            clock.advance(by: 2)
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
        }

        func relaunch() async throws {
            await close()
            try open()
        }

        func close() async {
            await runner?.stop()
            await controller?.shutdown()
            state?.close()
            catalog?.close()
            identities?.close()
            pending?.close()
        }

        func cleanup() async {
            await close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func withRestore829Fixture(
        _ shape: Restore829Fixture.Shape,
        _ body: @MainActor (Restore829Fixture) async throws -> Void
    ) async throws {
        let fixture = try Restore829Fixture(shape: shape)
        do { try await body(fixture) } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private enum Restore829StopFixtureError: Error {
        case invalid(String)
    }

    /// Every artificial wait ends independently. Expiry is invalid fixture evidence, never a kill.
    private actor Restore829StopGate {
        enum End: Sendable { case opened, expired, cleanup }
        private var end: End?
        private var waiters: [CheckedContinuation<End, Never>] = []
        private var expiry: Task<Void, Never>?

        func wait() async -> End {
            if let end { return end }
            if expiry == nil {
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.finish(.expired)
                }
            }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ result: End = .opened) {
            guard end == nil else { return }
            end = result
            expiry?.cancel()
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: result) }
        }

        func close() async {
            finish(.cleanup)
            let ownedExpiry = expiry
            expiry = nil
            await ownedExpiry?.value
        }
    }

    /// The first matching member never reaches the server. Later requests use the real server double.
    private final class Restore829StopUploader: PhotoUploading, @unchecked Sendable {
        let entered = Restore829StopGate()
        let nativeCancel = Restore829StopGate()
        let releaseUpload = Restore829StopGate()
        private let server: EditScenarioServer
        private let memberName: String
        private let lock = NSLock()
        private var request: PhotoUploadRequest?
        private var cancelled: [UUID] = []
        private var events: [String] = []
        private var uploadEnd: Restore829StopGate.End?

        var capabilities: UploadBackendCapabilities { server.capabilities }
        var heldRequest: PhotoUploadRequest? { lock.withLock { request } }
        var cancelledTokens: [UUID] { lock.withLock { cancelled } }
        var trace: [String] { lock.withLock { events } }
        var heldUploadEnd: Restore829StopGate.End? { lock.withLock { uploadEnd } }

        init(server: EditScenarioServer, memberName: String) {
            self.server = server
            self.memberName = memberName
        }

        func record(_ event: String) { lock.withLock { events.append(event) } }

        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            try await server.reserveNetwork(allowsExpensiveNetwork: allowsExpensiveNetwork)
        }

        func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
            try await server.ensureRemoteCapacity(forBytes: bytes, filename: filename)
        }

        func upload(
            _ request: PhotoUploadRequest,
            onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID {
            let hold = lock.withLock {
                guard self.request == nil, request.name == memberName else { return false }
                self.request = request
                events.append("upload-entered")
                return true
            }
            guard hold else { return try await server.upload(request, onProgress: onProgress) }
            await entered.finish()
            // Deliberately ignore task cancellation until the test or this gate's expiry releases us.
            let end = await releaseUpload.wait()
            lock.withLock {
                uploadEnd = end
                events.append("upload-ended")
            }
            guard case .opened = end else {
                throw Restore829StopFixtureError.invalid("held upload expired or entered cleanup")
            }
            throw CancellationError()
        }

        func cancel(token: UUID) async {
            lock.withLock {
                cancelled.append(token)
                events.append("native-cancel")
            }
            await nativeCancel.finish()
            await server.cancel(token: token)
            record("native-cancel-ended")
        }

        func close() async {
            // Release every waiter before joining any owned expiry task.
            await releaseUpload.finish(.cleanup)
            await entered.finish(.cleanup)
            await nativeCancel.finish(.cleanup)
            await releaseUpload.close()
            await entered.close()
            await nativeCancel.close()
        }
    }

    func testStopDuringRestoredBurstMemberUploadRetainsTheExactRestoreDuty() async throws {
        try await withRestore829Fixture(.burst) { f in
            let main = try await f.initialBackup(omittingSecondary: true)
            let checked = try f.restoredState(main, marker: true)
            guard !f.controller.isEnabled, f.server.uploadRequestCount == 1,
                f.server.links.count == 1, f.server.links.first?.uid == main,
                f.server.links.first?.state == .active, f.resolver.secondaries.count == 1,
                checked.remote == main, checked.needsQueueSync, checked.remoteOperation == .remoteTrash,
                let member = f.resolver.secondaries.first, member.descriptor.source.resource.isBurstMember,
                f.identities.record(for: member.descriptor.source) == nil
            else { throw Restore829StopFixtureError.invalid("initial backup/restore fixture") }
            let admission = await f.controller.returnToBackup([checked])
            guard case .waiting? = admission[f.key],
                let admitted = f.queue.entry(
                    for: f.resolver.candidate.snapshot.source,
                    revision: f.resolver.candidate.snapshot.revision),
                !admitted.state.isTerminalSuccess, admitted.remoteCommitReconciliation == nil
            else { throw Restore829StopFixtureError.invalid("restore was not admitted for a real pass") }
            let uploader = Restore829StopUploader(
                server: f.server,
                memberName: ProtonPhotoNameCorrection.correctedName(for: member.descriptor.filename))
            let runner = BackupSyncRunner(
                queue: f.queue,
                preflight: UploadBackupPreflightIndex(store: f.state, now: { [clock = f.clock] in clock.now }),
                resolver: f.resolver, identityResolver: f.pipeline, uploader: uploader,
                configuration: .init(throttle: .init(baseConcurrency: 1)), clock: f.clock,
                events: f.controller.pendingRecorder, now: { [clock = f.clock] in clock.now })
            var drain: Task<BackupSyncProgress, Never>?
            var stop: Task<Void, Never>?
            @MainActor func cleanup() async {
                // Never join a test task while its artificial upload gate remains held.
                await uploader.close()
                await runner.stop()
                await stop?.value
                _ = await drain?.value
            }
            do {
                let resolutionsBefore = f.resolver.resolveCount
                f.clock.advance(by: 2)
                drain = Task {
                    let result = await runner.runUntilDrained(mode: .eligibleOnly)
                    uploader.record("drain-returned")
                    return result
                }
                guard case .opened = await uploader.entered.wait(),
                    let request = uploader.heldRequest, request.mainPhotoUID?.nodeID == main.nodeID,
                    request.expectedSHA1 == member.descriptor.precomputedSHA1Digest,
                    f.resolver.resolveCount > resolutionsBefore, f.queue.isOperational(),
                    f.pending.isOperational(), f.catalog.isOperational(),
                    f.identities.record(for: admitted.source)?.remoteLinkID == main.nodeID,
                    let active = f.queue.entry(for: admitted.source, revision: admitted.revision),
                    active.state == .uploading, active.remoteCommitReconciliation == nil,
                    case .readable(let owed?) = f.pending.sourceStateRead(for: f.key),
                    owed.generation == checked.generation, owed.remote == main, owed.needsQueueSync,
                    owed.remoteOperation == .remoteTrash, f.server.uploadRequestCount == 1,
                    f.server.links.count == 1, f.server.links.first?.state == .active
                else { throw Restore829StopFixtureError.invalid("real active member-upload prerequisite") }
                stop = Task {
                    await runner.stop()
                    uploader.record("stop-returned")
                }
                guard case .opened = await uploader.nativeCancel.wait() else {
                    throw Restore829StopFixtureError.invalid("native cancellation gate expired")
                }
                guard uploader.cancelledTokens.first == request.cancellationToken else {
                    throw Restore829StopFixtureError.invalid("cancellation did not target the held upload")
                }
                await uploader.releaseUpload.finish()
                await stop?.value
                _ = await drain?.value
                guard case .opened? = uploader.heldUploadEnd else {
                    throw Restore829StopFixtureError.invalid("held upload expired before explicit release")
                }
                XCTAssertFalse(Task.isCancelled, "Only the real runner Stop may cancel this pass")
                XCTAssertEqual(uploader.cancelledTokens, [request.cancellationToken])
                let trace = uploader.trace
                let uploadEnded = trace.firstIndex(of: "upload-ended")
                let nativeCancelEnded = trace.firstIndex(of: "native-cancel-ended")
                let stopReturned = trace.firstIndex(of: "stop-returned")
                XCTAssertTrue(
                    uploadEnded.map { end in stopReturned.map { end < $0 } ?? false } ?? false,
                    "Stop must join the actual upload before it returns")
                XCTAssertTrue(
                    nativeCancelEnded.map { end in stopReturned.map { end < $0 } ?? false } ?? false,
                    "Stop must join native cancellation before it returns")
                do {
                    try await runner.checkCancellation()
                    XCTFail("The stopped restore pass must retain its cancellation")
                } catch { XCTAssertTrue(UploadError.isCancellation(error)) }
                let row = try XCTUnwrap(f.queue.entry(for: admitted.source, revision: admitted.revision))
                XCTAssertEqual(row.state, .queuedForUpload, "The interrupted compound stays runnable")
                XCTAssertEqual(row.attempts, admitted.attempts)
                XCTAssertNil(row.remoteCommitReconciliation)
                XCTAssertTrue(f.queue.nextRunnableDate().map { $0 <= f.clock.now } ?? false)
                guard f.queue.isOperational(), case .readable(let pending) = f.pending.sourceStateRead(for: f.key)
                else {
                    throw Restore829StopFixtureError.invalid("post-Stop local state is unreadable")
                }
                let retained = try XCTUnwrap(pending, "Stop must retain the pending restore duty")
                XCTAssertEqual(retained.remote, main)
                XCTAssertEqual(retained.generation, checked.generation)
                XCTAssertEqual(retained.attempts, checked.attempts)
                XCTAssertTrue(retained.needsQueueSync)
                XCTAssertEqual(retained.remoteOperation, .remoteTrash)
                guard f.identities.record(for: admitted.source)?.remoteLinkID == main.nodeID else {
                    throw Restore829StopFixtureError.invalid("post-Stop identity read is unavailable")
                }
                let interruptedIdentity = try XCTUnwrap(f.identities.record(for: member.descriptor.source))
                XCTAssertTrue(interruptedIdentity.isValid(for: member.descriptor))
                XCTAssertNil(interruptedIdentity.remoteLinkID)
                XCTAssertFalse(interruptedIdentity.provesUpload)
                XCTAssertEqual(f.server.uploadRequestCount, 1)
                XCTAssertEqual(f.server.links.count, 1)
                XCTAssertEqual(f.server.links.first?.uid, main)
                XCTAssertEqual(f.server.links.first?.state, .active)
                let pendingOutcome = await f.controller.returnToBackup([checked])
                guard case .waiting? = pendingOutcome[f.key] else {
                    XCTFail("Stop cannot acknowledge the unfinished compound")
                    await cleanup()
                    return
                }
                // The same uploader now forwards the member; no competing runner is started.
                f.clock.advance(by: 2)
                drain = Task { await runner.runUntilDrained(mode: .eligibleOnly) }
                _ = await drain?.value
                let completed = await f.controller.returnToBackup([checked])
                XCTAssertEqual(completed[f.key], .completed)
                XCTAssertEqual(f.server.uploadRequestCount, 2, "Only the missing member commits")
                XCTAssertEqual(f.server.links.filter { $0.mainLinkID == nil && $0.state == .active }.map(\.uid), [main])
                let members = f.server.links.filter { $0.mainLinkID == main.nodeID && $0.state == .active }
                XCTAssertEqual(members.count, 1)
                XCTAssertEqual(f.identities.record(for: member.descriptor.source)?.remoteLinkID, members.first?.linkID)
                XCTAssertEqual(uploader.cancelledTokens, [request.cancellationToken])
                if completed[f.key] == .completed {
                    XCTAssertTrue(f.pending.finishRestoreRecheck(checked, outcome: .completed, at: f.clock.now))
                    XCTAssertNil(
                        f.pending.sourceState(for: f.key), "Only the later complete recheck retires the marker")
                }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }

    func testRestoredPhotoVideoAndLiveWaitForRealCompoundDrainWithoutDuplicateUpload() async throws {
        for shape in [Restore829Fixture.Shape.photo, .video, .live] {
            try await withRestore829Fixture(shape) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: shape == .live, marker: true)
                let uploads = f.server.uploadRequestCount
                let beforeReads = f.resolver.resolveCount
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else {
                    return XCTFail("Enqueue must not report compound completion")
                }
                XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
                XCTAssertEqual(f.pending.sourceState(for: f.key)?.remote, main)
                XCTAssertEqual(
                    f.pending.sourceState(for: f.key)?.remoteOperation, .remoteTrash,
                    "The marker stays until the real recheck")
                await f.drain()
                XCTAssertGreaterThan(f.resolver.resolveCount, beforeReads)
                let completed = await f.controller.returnToBackup([checked])
                XCTAssertEqual(completed[f.key], .completed)
                XCTAssertTrue(
                    f.pending.finishRestoreRecheck(checked, outcome: try XCTUnwrap(completed[f.key]), at: f.clock.now))
                XCTAssertNil(f.pending.sourceState(for: f.key), "Only this verified UID/generation marker retires")
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
                XCTAssertEqual(f.server.links.filter { $0.state == .active }.count, shape == .live ? 2 : 1)
                let reads = f.resolver.resolveCount
                let repeatResult = await f.controller.returnToBackup([checked])
                XCTAssertEqual(
                    repeatResult[f.key], .unreadable, "An acknowledged generation cannot readmit the stale request")
                await f.drain()
                XCTAssertEqual(f.resolver.resolveCount, reads)
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
            }
        }
    }

    func testRestoredBurstRecoversAnActuallyOmittedMemberUnderItsMain() async throws {
        try await withRestore829Fixture(.burst) { f in
            let main = try await f.initialBackup(omittingSecondary: true)
            XCTAssertEqual(f.server.uploadRequestCount, 1, "The initial resolved compound really omitted the member")
            let checked = try f.restoredState(main)
            let admission = await f.controller.returnToBackup([checked])
            guard case .waiting? = admission[f.key] else { return XCTFail("The omitted burst needs a real recheck") }
            await f.drain()
            let outcome = await f.controller.returnToBackup([checked])
            XCTAssertEqual(outcome[f.key], .completed)
            XCTAssertEqual(f.server.uploadRequestCount, 2, "Exactly the missing member uploads")
            let members = f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }
            XCTAssertEqual(members.count, 1)
            XCTAssertEqual(
                f.identities.record(for: try XCTUnwrap(f.resolver.secondaries.first).descriptor.source)?.remoteLinkID,
                members.first?.linkID)
            XCTAssertEqual(
                f.state.record(
                    for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision)?
                    .pendingResourceCount, 0)
        }
    }

    func testRestoredCompoundReconstructsItsDutyAfterClosingAllAccountStores() async throws {
        try await withRestore829Fixture(.live) { f in
            let main = try await f.initialBackup()
            let checked = try f.restoredState(main, retainMemberTrash: true, marker: true)
            let admission = await f.controller.returnToBackup([checked])
            guard case .waiting(let due)? = admission[f.key] else {
                return XCTFail("The first return must stay pending")
            }
            XCTAssertTrue(f.pending.finishRestoreRecheck(checked, outcome: .waiting(until: due), at: f.clock.now))
            let durable = try XCTUnwrap(f.pending.sourceState(for: f.key))
            let uploads = f.server.uploadRequestCount
            await f.runner.stop()
            try await f.relaunch()
            XCTAssertEqual(f.pending.sourceState(for: f.key), durable)
            XCTAssertEqual(durable.remote, main)
            XCTAssertEqual(durable.attempts, checked.attempts)
            f.clock.advance(by: max(0, durable.nextAttemptAt.timeIntervalSince(f.clock.now)))
            let firstAfterRestart = await f.controller.returnToBackup([durable])
            guard case .waiting? = firstAfterRestart[f.key] else {
                return XCTFail("New controller memory is not proof of a completed pass")
            }
            await f.drain()
            let outcome = await f.controller.returnToBackup([durable])
            XCTAssertEqual(outcome[f.key], .completed)
            XCTAssertTrue(
                f.pending.finishRestoreRecheck(durable, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
            XCTAssertNil(f.pending.sourceState(for: f.key))
            XCTAssertEqual(f.server.uploadRequestCount, uploads)
            XCTAssertEqual(f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }.count, 1)
        }
    }

    func testRestoredCompoundRefusesChangedGenerationAndUIDAndPlansTheLatestCatalogRevision() async throws {
        for change in ["generation=generation+1", "remote_link_id='newer-remote'"] {
            try await withRestore829Fixture(.live) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true)
                var db: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_open(
                        f.directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &db),
                    SQLITE_OK)
                let handle = try XCTUnwrap(db)
                defer { sqlite3_close(handle) }
                XCTAssertEqual(sqlite3_exec(handle, "UPDATE source_state SET \(change);", nil, nil, nil), SQLITE_OK)
                let before = try XCTUnwrap(
                    f.queue.entry(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
                let outcome = await f.controller.returnToBackup([checked])
                XCTAssertEqual(outcome[f.key], .unreadable)
                XCTAssertEqual(f.queue.entry(for: before.source, revision: before.revision), before)
            }
        }
        try await withRestore829Fixture(.photo) { f in
            let main = try await f.initialBackup()
            let checked = try f.restoredState(main)
            var entry = try XCTUnwrap(f.catalog.entry(for: f.key.identifier))
            entry.modificationDate = try XCTUnwrap(entry.modificationDate).addingTimeInterval(1)
            XCTAssertTrue(f.catalog.upsertBatch([entry]))
            let before = try XCTUnwrap(
                f.queue.entry(
                    for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
            let outcome = await f.controller.returnToBackup([checked])
            guard case .waiting? = outcome[f.key] else { return XCTFail("A later local revision owes a fresh recheck") }
            let latest = try XCTUnwrap(
                PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)))
            XCTAssertNotEqual(latest.snapshot.revision, before.revision)
            XCTAssertNotNil(f.queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision))
            XCTAssertEqual(f.queue.entry(for: before.source, revision: before.revision), before)
        }
    }

    func testRestoredCompoundDetectsALateAppliedTrashBeforeQueueMutation() async throws {
        try await withRestore829Fixture(.live) { f in
            let main = try await f.initialBackup()
            let checked = try f.restoredState(main, retainMemberTrash: true)
            f.server.personTrash(main)
            let uploads = f.server.uploadRequestCount
            let before = try XCTUnwrap(
                f.queue.entry(
                    for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
            let outcome = await f.controller.returnToBackup([checked])
            XCTAssertEqual(outcome[f.key], .remoteTrashed)
            XCTAssertEqual(f.queue.entry(for: before.source, revision: before.revision), before)
            XCTAssertTrue(
                f.pending.finishRestoreRecheck(checked, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
            let retained = try XCTUnwrap(f.pending.sourceState(for: f.key))
            XCTAssertTrue(retained.remoteTrashed)
            XCTAssertTrue(retained.needsRemoteRestore, "A trash that applies late still owes the real compensation")
            XCTAssertTrue(retained.needsQueueSync)
            XCTAssertEqual(retained.remote, main)
            XCTAssertEqual(f.server.uploadRequestCount, uploads)
        }
    }

    func testRestoredContextEndsOnShutdownAndDoesNotCrossAccountPipelines() async throws {
        try await withRestore829Fixture(.live) { f in
            let main = try await f.initialBackup()
            let checked = try f.restoredState(main, retainMemberTrash: true)
            _ = await f.controller.returnToBackup([checked])
            let context = UploadRestoredCompoundContext(
                source: f.resolver.candidate.snapshot.source,
                revision: f.resolver.candidate.snapshot.revision, generation: checked.generation, confirmedRemote: main)
            let active = try await f.pipeline.restoredPhotoOutcome(context)
            XCTAssertEqual(active, .completed)
            let other = UploadDedupePipeline(store: FakeIdentityStore(), checker: f.server)
            let foreign = try await other.restoredPhotoOutcome(context)
            XCTAssertEqual(foreign, .unreadable, "An account-local registration never crosses pipeline instances")
            await f.controller.shutdown()
            let ended = try await f.pipeline.restoredPhotoOutcome(context)
            XCTAssertEqual(ended, .unreadable)
            XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
        }
    }
}

extension PhotoLibraryBackupControllerStateTests {
    private struct Restore829ControllerEffects: PendingBackupEffects {
        let controller: PhotoLibraryBackupController
        let server: EditScenarioServer
        func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
            await controller.removeFromBackup(identifiers: identifiers)
        }
        func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool { false }
        func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
            await controller.returnToBackup(states)
        }
        func photosVolumeID() async -> String? { "vol" }
        func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            do {
                try await server.trashDuplicates(uids)
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            do {
                try await server.restoreDuplicates(uids)
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .permanentFailure }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .permanentFailure }
    }

    func testCoordinatorReconstructsAndAcknowledgesOnlyARealCompoundPassAfterRestart() async throws {
        try await withRestore829Fixture(.live) { f in
            @MainActor func makeCoordinator() throws -> PendingBackupCoordinator {
                PendingBackupCoordinator(
                    store: f.pending, queues: [.photoLibraryAsset: f.queue],
                    metadataProvider: try XCTUnwrap(f.controller.pendingMetadataProvider),
                    effects: Restore829ControllerEffects(controller: f.controller, server: f.server),
                    recorder: f.controller.pendingRecorder, relations: f.server, now: { [clock = f.clock] in clock.now }
                )
            }
            let main = try await f.initialBackup()
            let checked = try f.restoredState(main, retainMemberTrash: true, marker: true)
            let uploads = f.server.uploadRequestCount
            var coordinator = try makeCoordinator()
            do {
                await coordinator.start()
                let pending = await coordinator.restoreSources(ofRemote: [main])
                guard case .waiting? = pending.outcomes[f.key] else {
                    await coordinator.close()
                    return XCTFail("An enqueue is not an acknowledged compound pass")
                }
                let durable = try XCTUnwrap(f.pending.sourceState(for: f.key))
                XCTAssertEqual(durable.remote, main)
                XCTAssertEqual(durable.attempts, checked.attempts)
                XCTAssertTrue(durable.needsQueueSync)
                XCTAssertEqual(durable.remoteOperation, .remoteTrash)
                await coordinator.close()
                try await f.relaunch()
                XCTAssertEqual(f.pending.sourceState(for: f.key), durable)
                f.clock.advance(by: max(0, durable.nextAttemptAt.timeIntervalSince(f.clock.now)))
                coordinator = try makeCoordinator()
                await coordinator.start()
                XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
                await f.drain()
                let completed = await coordinator.restoreSources(ofRemote: [main])
                XCTAssertEqual(completed.outcomes[f.key], .completed)
                XCTAssertNil(
                    f.pending.sourceState(for: f.key),
                    "Only a real, fresh, same-UID/generation recheck retires the marker")
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
                XCTAssertEqual(f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }.count, 1)
            } catch {
                await coordinator.close()
                throw error
            }
            await coordinator.close()
        }
    }
}
