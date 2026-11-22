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

    func testTheSummaryCountsLongWaitsInTheCalmLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-long-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("q.sqlite")))
        defer { store.close() }
        let current = Date()
        func seed(_ id: String, _ record: BackupIssueRecord?) {
            XCTAssertTrue(
                store.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                        originalFilename: "\(id).heic", state: .discovered, lastError: record?.persistedValue,
                        updatedAt: current)))
        }
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
}
