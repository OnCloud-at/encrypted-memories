import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// A wait that never ends by itself (Photos cannot hand out the file, an edit waits for its original, Proton is
/// temporarily unavailable) shows the calm "Not finished yet." after 7 days and counts in the calm line. The retries
/// continue; the section stays "Continues by itself".
final class BackupLongWaitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 3600

    private func record(_ wait: String, since: Date?) -> BackupIssueRecord {
        switch wait {
        case "photos":
            BackupIssueRecord(
                kind: .unknown, detail: BackupItemOutcome.sourceUnavailableDetail, automaticRetryAttempt: 3,
                waitingSince: since)
        case "original":
            BackupIssueRecord(
                kind: .unknown, detail: "backup.issue_waiting_original", automaticRetryAttempt: 3, waitingSince: since)
        case "proton":
            BackupIssueRecord(kind: .remoteService, detail: "busy", automaticRetryAttempt: 3, waitingSince: since)
        default:
            BackupIssueRecord(kind: .network, detail: "offline", automaticRetryAttempt: 3, waitingSince: since)
        }
    }

    // MARK: - Stored format

    func testTheWaitStartIsStoredAndAnOlderRecordHasNone() throws {
        let stored = record("photos", since: now)
        XCTAssertEqual(BackupIssueRecord.decode(stored.persistedValue), stored)
        let older = BackupIssueRecord(kind: .unknown, detail: BackupItemOutcome.sourceUnavailableDetail)
        XCTAssertNil(BackupIssueRecord.decode(older.persistedValue)?.waitingSince)
        // A record of an older build has no field at all and decodes as before.
        let legacy =
            BackupIssueRecord.storagePrefix
            + Data(#"{"kind":"unknown","detail":"backup.issue_source_unavailable","automaticRetryAttempt":2}"#.utf8)
            .base64EncodedString()
        let decoded = try XCTUnwrap(BackupIssueRecord.decode(legacy))
        XCTAssertNil(decoded.waitingSince)
        XCTAssertEqual(decoded.automaticRetryAttempt, 2)
    }

    func testAContinuingWaitKeepsItsStartAndAnotherWaitStartsNow() {
        let began = now.addingTimeInterval(-3 * day)
        let earlier = record("photos", since: began)
        XCTAssertEqual(BackupItemOutcome.waitStart(continuing: earlier, sameWait: true, now: now), began)
        XCTAssertEqual(BackupItemOutcome.waitStart(continuing: earlier, sameWait: false, now: now), now)
        XCTAssertEqual(BackupItemOutcome.waitStart(continuing: nil, sameWait: true, now: now), now)
        let undated = record("photos", since: nil)
        XCTAssertEqual(BackupItemOutcome.waitStart(continuing: undated, sameWait: true, now: now), now)
    }

    // MARK: - Outcome

    func testAWaitOfSevenDaysShowsNotFinishedYetAndKeepsItsSection() {
        for wait in ["photos", "original", "proton"] {
            let long = BackupItemOutcome(
                state: .discovered, record: record(wait, since: now.addingTimeInterval(-7 * day)), now: now)
            XCTAssertEqual(long.reason, L10n.string("backup.issue_unknown_waiting"), wait)
            XCTAssertEqual(long.section, .continuesByItself, wait)
            XCTAssertEqual(long.category, .automatic, wait)
            XCTAssertFalse(long.raisesAttention, wait)
            XCTAssertTrue(
                BackupItemOutcome.isLongWait(
                    state: .discovered, record: record(wait, since: now.addingTimeInterval(-7 * day)), now: now), wait)

            let short = BackupItemOutcome(
                state: .discovered, record: record(wait, since: now.addingTimeInterval(-7 * day + 60)), now: now)
            XCTAssertEqual(
                short.reason,
                BackupItemOutcome(state: .discovered, record: record(wait, since: nil), now: now).reason,
                "\(wait): a shorter wait keeps its own reason")
        }
    }

    func testOnlyTheBoundedWaitsOfARunnableRowCountAsLong() {
        let old = now.addingTimeInterval(-30 * day)
        XCTAssertFalse(
            BackupItemOutcome.isLongWait(state: .discovered, record: record("network", since: old), now: now),
            "a lost connection shows its own waiting line")
        let unproven = BackupIssueRecord(kind: .remoteService, detail: "local", waitingSince: old)
        XCTAssertFalse(
            BackupItemOutcome.isLongWait(state: .discovered, record: unproven, now: now),
            "an item retry of another error is no Proton wait")
        for state in [UploadBackupSyncQueueState.failed, .failedPermanent, .sourceMissing, .completed] {
            XCTAssertFalse(
                BackupItemOutcome.isLongWait(state: state, record: record("photos", since: old), now: now), "\(state)")
        }
        XCTAssertFalse(BackupItemOutcome.isLongWait(state: .discovered, record: record("photos", since: nil), now: now))
        XCTAssertFalse(BackupItemOutcome.isLongWait(state: .discovered, record: nil, now: now))
    }

    // MARK: - Summary and status

    private func makeStore() throws -> UploadBackupSyncQueueManifestStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-long-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("q.sqlite")))
        addTeardownBlock {
            store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return store
    }

    private func seed(
        _ store: UploadBackupSyncQueueManifestStore, _ id: String, state: UploadBackupSyncQueueState = .discovered,
        _ record: BackupIssueRecord?, updatedAt: Date = Date()
    ) {
        XCTAssertTrue(
            store.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                    originalFilename: "\(id).heic", state: state, lastError: record?.persistedValue,
                    updatedAt: updatedAt)))
    }

    func testTheSummaryCountsLongWaitsInTheCalmLine() throws {
        let store = try makeStore()
        let current = Date()
        func seed(_ id: String, _ record: BackupIssueRecord?) { self.seed(store, id, record, updatedAt: current) }
        seed("photos-long", record("photos", since: current.addingTimeInterval(-8 * day)))
        seed("original-long", record("original", since: current.addingTimeInterval(-9 * day)))
        seed("proton-long", record("proton", since: current.addingTimeInterval(-10 * day)))
        seed("photos-short", record("photos", since: current.addingTimeInterval(-1 * day)))
        seed("network-long", record("network", since: current.addingTimeInterval(-30 * day)))
        seed("plain", nil)

        let summary = try XCTUnwrap(store.summary())
        XCTAssertEqual(summary.waiting, 6)
        XCTAssertEqual(summary.longWaiting, 3)

        let status = BackupStatus(progress: BackupSyncProgress(summary: summary), isScanning: false)
        XCTAssertEqual(status.phase, .waiting, "the retries continue")
        XCTAssertEqual(status.longWaitingCount, 3)
        XCTAssertEqual(status.notBackedUpCount, 3)
        XCTAssertEqual(status.needsAttentionCount, 0)
        let display = BackupStatusPresentation(status)
        XCTAssertEqual(display.localizedNotBackedUp, L10n.string("backup.progress_not_backed_up \(3)"))
        XCTAssertNotEqual(display.accessory, .attention)
    }

    // MARK: - Where a long wait counts

    func testOnlyARowThatWaitsToBeRetriedCountsAsLongAndTheProblemListShowsTheSameRows() throws {
        let store = try makeStore()
        let old = record("photos", since: now.addingTimeInterval(-8 * day))
        seed(store, "waiting", old)
        seed(store, "checking", state: .checking, old)
        XCTAssertFalse(BackupItemOutcome.isLongWait(state: .checking, record: old, now: now))

        let summary = try XCTUnwrap(store.summary(now: now))
        XCTAssertEqual(summary.longWaiting, 1)
        var listed: [UploadBackupSyncQueueEntry] = []
        try store.decisionForEachProblemEntry {
            listed.append($0)
            return true
        }
        let longInList = listed.filter {
            BackupItemOutcome.isLongWait(state: $0.state, record: BackupIssueRecord.decode($0.lastError), now: now)
        }
        XCTAssertEqual(longInList.count, summary.longWaiting, "the list shows every wait that the summary counts")
    }

    func testTheSummaryJudgesTheBoundaryAtTheGivenMoment() throws {
        let store = try makeStore()
        seed(store, "photos", record("photos", since: now))
        XCTAssertEqual(try XCTUnwrap(store.summary(now: now.addingTimeInterval(7 * day - 1))).longWaiting, 0)
        XCTAssertEqual(try XCTUnwrap(store.summary(now: now.addingTimeInterval(7 * day))).longWaiting, 1)
    }

    func testADismissedRecheckNeverCountsAsALongWait() throws {
        let store = try makeStore()
        // A photo that the person dismissed as missing and that the backup checks again: its record names a missing
        // source, also when it carries the detail and the start of an old wait.
        let dismissed = BackupIssueRecord(
            kind: .sourceMissing, detail: BackupItemOutcome.sourceUnavailableDetail, automaticRetryAttempt: 3,
            waitingSince: now.addingTimeInterval(-30 * day))
        seed(store, "dismissed", dismissed)
        let summary = try XCTUnwrap(store.summary(now: now))
        XCTAssertEqual(summary.pendingSourceRechecks, 1)
        XCTAssertEqual(summary.longWaiting, 0, "a dismissed recheck counts as a dismissed failure only")
    }

    func testAWaitStartInTheFutureIsNoLongWait() throws {
        let future = record("proton", since: now.addingTimeInterval(8 * day))
        XCTAssertFalse(BackupItemOutcome.isLongWait(state: .discovered, record: future, now: now))
        XCTAssertEqual(
            BackupItemOutcome(state: .discovered, record: future, now: now).reason,
            BackupItemOutcome(state: .discovered, record: record("proton", since: nil), now: now).reason)
        let store = try makeStore()
        seed(store, "skewed", record("photos", since: now.addingTimeInterval(8 * day)))
        let summary = try XCTUnwrap(store.summary(now: now))
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertEqual(summary.longWaiting, 0)
    }

    func testTheStatusNeverCountsMoreLongWaitsThanWaitingRows() {
        var raw = BackupSyncProgress()
        raw.total = 5
        raw.waiting = 2
        raw.longWaiting = 5
        XCTAssertEqual(BackupStatus(progress: raw, isScanning: false).longWaitingCount, 2)
        raw.longWaiting = -3
        XCTAssertEqual(BackupStatus(progress: raw, isScanning: false).longWaitingCount, 0)
    }

    func testTheProblemListReloadsWhenARowCrossesAWeek() {
        var raw = BackupSyncProgress()
        raw.total = 3
        raw.waiting = 3
        let before = BackupStatus(progress: raw, isScanning: false).problemListKey
        raw.longWaiting = 1
        XCTAssertNotEqual(BackupStatus(progress: raw, isScanning: false).problemListKey, before)
    }

    /// A stored error is free text, so ten thousand waiting rows are ten thousand groups. The count must stay exact; the
    /// log keeps the durations, also of a health probe that needs the store's lock during the read.
    func testTenThousandWaitingRowsKeepAnExactLongWaitCount() throws {
        let store = try makeStore()
        let entries = (0..<10_000).map { index in
            UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "bulk-\(index)"), revision: .init(rawValue: 1),
                originalFilename: "bulk-\(index).heic", state: .discovered,
                lastError: BackupIssueRecord(
                    kind: .remoteService, detail: "busy \(index)", automaticRetryAttempt: 2,
                    waitingSince: now.addingTimeInterval(index.isMultiple(of: 2) ? -8 * day : -1 * day)
                ).persistedValue,
                updatedAt: now)
        }
        XCTAssertTrue(store.upsertBatch(entries))
        let clock = ContinuousClock()
        var first: UploadBackupSyncQueueSummary?
        let firstDuration = clock.measure { first = store.summary(now: now) }
        let probe = LockProbe(store)
        probe.start()
        var second: UploadBackupSyncQueueSummary?
        let secondDuration = clock.measure { second = store.summary(now: now) }
        let worstProbe = probe.stop()
        XCTAssertEqual(try XCTUnwrap(first).longWaiting, 5_000)
        XCTAssertEqual(try XCTUnwrap(first).waiting, 10_000)
        XCTAssertEqual(second, first)
        print(
            "BENCHMARK waiting=10000 firstRead=\(firstDuration) secondRead=\(secondDuration) "
                + "worstProbe=\(worstProbe)")
    }

    /// Measures how long a health probe waits for the store's lock while a read runs.
    private final class LockProbe: @unchecked Sendable {
        private let store: UploadBackupSyncQueueManifestStore
        private let lock = NSLock()
        private var running = false
        private var worst = Duration.zero
        private let finished = DispatchSemaphore(value: 0)

        init(_ store: UploadBackupSyncQueueManifestStore) { self.store = store }

        func start() {
            lock.withLock { running = true }
            Thread.detachNewThread { [self] in
                let clock = ContinuousClock()
                while lock.withLock({ running }) {
                    let waited = clock.measure { _ = store.isOperational() }
                    lock.withLock { worst = max(worst, waited) }
                    Thread.sleep(forTimeInterval: 0.0005)
                }
                finished.signal()
            }
        }

        func stop() -> Duration {
            lock.withLock { running = false }
            finished.wait()
            return lock.withLock { worst }
        }
    }
}
