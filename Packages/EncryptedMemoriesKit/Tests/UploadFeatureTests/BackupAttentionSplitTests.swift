import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Only a parked row that waits for the person's decision or for a cause that only the person can fix raises the
/// orange attention line. Every other row that is not backed up shows in a calm line that opens the same list.
final class BackupAttentionSplitTests: XCTestCase {
    private var directory: URL!
    private var store: UploadBackupSyncQueueManifestStore!
    private let refusalStart = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-attention-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
    }

    override func tearDownWithError() throws {
        store?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func seed(
        _ prefix: String, count: Int, state: UploadBackupSyncQueueState, record: BackupIssueRecord?,
        distinctDetail: Bool = true
    ) {
        for index in 0..<count {
            var stored = record
            if distinctDetail { stored?.detail = "\(prefix) detail \(index)" }
            XCTAssertTrue(
                store.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "\(prefix)-\(index)"),
                        revision: .init(rawValue: 1), originalFilename: "\(prefix)-\(index).heic", state: state,
                        lastError: stored?.persistedValue, updatedAt: refusalStart)))
        }
    }

    private var stoppedRefusal: BackupIssueRecord {
        BackupIssueRecord(
            kind: .remoteService, detail: "refused",
            serviceRejection: .init(
                rounds: 3, firstRoundAt: refusalStart, lastRoundAt: refusalStart.addingTimeInterval(72 * 3600)))
    }

    // MARK: - Queue summary

    func testTheSummaryCountsOnlyPersonFixableParkedRowsAsAttention() throws {
        seed("permission", count: 1, state: .failed, record: .init(kind: .permission, detail: ""))
        seed("deleted", count: 2, state: .failedPermanent, record: .init(kind: .deletedElsewhere, detail: ""))
        seed("local", count: 3, state: .failed, record: .init(kind: .localState, detail: ""))
        seed("service", count: 4, state: .failed, record: .init(kind: .remoteService, detail: ""))
        seed("stopped", count: 5, state: .failedPermanent, record: stoppedRefusal)
        seed("missing", count: 7, state: .sourceMissing, record: .init(kind: .sourceMissing, detail: ""))
        seed("device", count: 8, state: .failed, record: .init(kind: .deviceStorage, detail: ""))
        // Runnable rows never count as parked attention, also a full Proton storage and a dismissed photo's recheck.
        seed("account", count: 9, state: .discovered, record: .init(kind: .accountStorage, detail: ""))
        seed("recheck", count: 10, state: .discovered, record: .init(kind: .sourceMissing, detail: ""))
        seed("legacy", count: 11, state: .failed, record: nil)

        let summary = try XCTUnwrap(store.summary())
        XCTAssertEqual(summary.failed, 1 + 2 + 3 + 4 + 5 + 8 + 11)
        XCTAssertEqual(summary.sourceMissing, 7)
        XCTAssertEqual(summary.attention, 1 + 2 + 3)
        XCTAssertEqual(summary.dismissedFailures, 10)
        XCTAssertEqual(summary.waiting, 9)
        XCTAssertEqual(try XCTUnwrap(store.summary()), summary, "a second read gives the same split")

        let status = BackupStatus(progress: BackupSyncProgress(summary: summary), isScanning: false)
        XCTAssertEqual(status.needsAttentionCount, 6)
        XCTAssertEqual(status.notBackedUpCount, 4 + 5 + 7 + 8 + 11)
        XCTAssertEqual(status.notBackedUpFailedCount, 4 + 5 + 8 + 11, "missing photos have their own line")
    }

    func testTheSameStoredErrorInAnotherStateIsJudgedByThatState() throws {
        let permission = BackupIssueRecord(kind: .permission, detail: "same")
        seed("failed", count: 1, state: .failed, record: permission, distinctDetail: false)
        XCTAssertEqual(try XCTUnwrap(store.summary()).attention, 1)
        // The identical text parked as final: no further attempt, so nothing for the person to fix.
        seed("final", count: 2, state: .failedPermanent, record: permission, distinctDetail: false)
        let summary = try XCTUnwrap(store.summary())
        XCTAssertEqual(summary.attention, 1)
        XCTAssertEqual(summary.failed, 3)
    }

    func testAParkedRowThatTurnsFixableIsCountedOnTheNextRead() throws {
        seed("row", count: 1, state: .failed, record: .init(kind: .remoteService, detail: "first"))
        XCTAssertEqual(try XCTUnwrap(store.summary()).attention, 0)
        seed("row", count: 1, state: .failed, record: .init(kind: .permission, detail: "second"), distinctDetail: false)
        XCTAssertEqual(try XCTUnwrap(store.summary()).attention, 1)
    }

    /// The split needs the second read of the parked rows; when that read fails, the whole summary is unknown rather
    /// than a count that calls every parked row calm.
    func testAFailedParkedReadLeavesTheSummaryUnknown() throws {
        seed("permission", count: 1, state: .failed, record: .init(kind: .permission, detail: ""))
        let fault = try SQLiteReadInterrupt(in: store!, matching: "SELECT state, last_error FROM backup_sync_queue")
        defer { fault.stop() }
        XCTAssertNil(store.summary())
        XCTAssertTrue(fault.fired)
    }

    /// A folder that could not be read has no queue row; the status still asks the person, also next to calm rows.
    func testAFolderReadFailureAsksThePerson() {
        let calm = BackupStatus(progress: progress(total: 10, uploaded: 7, failed: 3), isScanning: false)
        XCTAssertEqual(calm.needsAttentionCount, 0)
        let failed = calm.afterFolderEnumerationFailure()
        XCTAssertEqual(failed.phase, .needsAttention)
        XCTAssertEqual(failed.needsAttentionCount, 1)
        XCTAssertEqual(failed.notBackedUpCount, 2)
        XCTAssertNil(failed.fractionCompleted)
        let empty = BackupStatus().afterFolderEnumerationFailure()
        XCTAssertEqual(empty.failed, 1)
        XCTAssertEqual(empty.needsAttentionCount, 1)
        XCTAssertEqual(BackupStatusPresentation(empty).accessory, .attention)
    }

    func testAPausedStatusShowsNoCalmLine() {
        var raw = progress(total: 10, uploaded: 5, waiting: 3, failed: 2)
        raw.isRunning = true
        raw.isPausedByPolicy = true
        let status = BackupStatus(progress: raw, isScanning: false)
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.notBackedUpCount, 2)
        XCTAssertNil(BackupStatusPresentation(status).localizedNotBackedUp)
    }

    /// A stored error is free text, so ten thousand parked rows are ten thousand groups. Both reads must count them
    /// all; the log keeps the durations for the packet.
    func testTenThousandParkedRowsKeepAnExactSplit() throws {
        seed("service", count: 9_000, state: .failed, record: .init(kind: .remoteService, detail: ""))
        seed("permission", count: 1_000, state: .failed, record: .init(kind: .permission, detail: ""))
        let clock = ContinuousClock()
        var first: UploadBackupSyncQueueSummary?
        let firstDuration = clock.measure { first = store.summary() }
        var second: UploadBackupSyncQueueSummary?
        let secondDuration = clock.measure { second = store.summary() }
        XCTAssertEqual(try XCTUnwrap(first).attention, 1_000)
        XCTAssertEqual(try XCTUnwrap(first).failed, 10_000)
        XCTAssertEqual(second, first)
        print("BENCHMARK parked=10000 firstRead=\(firstDuration) secondRead=\(secondDuration)")
    }

    // MARK: - Status and presentation

    private func progress(
        total: Int, uploaded: Int, waiting: Int = 0, failed: Int = 0, sourceMissing: Int = 0, attention: Int = 0,
        isRunning: Bool = false
    ) -> BackupSyncProgress {
        var progress = BackupSyncProgress()
        progress.total = total
        progress.uploaded = uploaded
        progress.waiting = waiting
        progress.failed = failed
        progress.sourceMissing = sourceMissing
        progress.attention = attention
        progress.isRunning = isRunning
        return progress
    }

    func testCalmRowsNeverClaimThatAllFilesAreBackedUp() {
        let status = BackupStatus(
            progress: progress(total: 10, uploaded: 7, failed: 2, sourceMissing: 1), isScanning: false)
        XCTAssertEqual(status.phase, .completed)
        XCTAssertEqual(status.needsAttentionCount, 0)
        XCTAssertEqual(status.notBackedUpCount, 3)
        XCTAssertEqual(status.titleKey, "backup.phase_completed_with_omissions")
        XCTAssertEqual(status.localizedTitle, L10n.string("backup.phase_completed_with_omissions"))

        let display = BackupStatusPresentation(status)
        XCTAssertEqual(display.headlineKey, "backup.phase_completed_with_omissions")
        XCTAssertEqual(display.accessory, .notice)
        XCTAssertNil(display.localizedAttention)
        XCTAssertEqual(display.localizedNotBackedUp, L10n.string("backup.progress_not_backed_up \(3)"))
        XCTAssertEqual(
            BackupSettingsSummary(isAvailable: true, isEnabled: true, isUserPaused: false, display: display), .on)
    }

    func testCalmRowsNextToWaitingWorkKeepTheWaitingHeadline() {
        let status = BackupStatus(progress: progress(total: 10, uploaded: 7, waiting: 2, failed: 1), isScanning: false)
        XCTAssertEqual(status.phase, .waiting)
        let display = BackupStatusPresentation(status)
        XCTAssertEqual(display.accessory, .waiting)
        XCTAssertEqual(display.notBackedUpCount, 1)
        XCTAssertNil(display.localizedAttention)
    }

    func testAttentionRowsStayOrangeAndTheCalmRowsKeepTheirOwnLine() {
        let status = BackupStatus(
            progress: progress(total: 10, uploaded: 5, failed: 4, sourceMissing: 1, attention: 2), isScanning: false)
        XCTAssertEqual(status.phase, .needsAttention)
        XCTAssertEqual(status.needsAttentionCount, 2)
        XCTAssertEqual(status.notBackedUpCount, 3)
        let display = BackupStatusPresentation(status)
        XCTAssertEqual(display.accessory, .attention)
        XCTAssertEqual(display.attentionCount, 2)
        XCTAssertEqual(display.localizedAttention, L10n.string("backup.progress_attention \(2)"))
        XCTAssertEqual(display.localizedNotBackedUp, L10n.string("backup.progress_not_backed_up \(3)"))
        XCTAssertEqual(
            BackupSettingsSummary(isAvailable: true, isEnabled: true, isUserPaused: false, display: display),
            .incomplete)
    }

    func testAnAttentionCountAboveTheParkedRowsIsCappedAtThem() {
        let status = BackupStatus(progress: progress(total: 4, uploaded: 3, failed: 1, attention: 5), isScanning: false)
        XCTAssertEqual(status.needsAttentionCount, 1)
        XCTAssertEqual(status.notBackedUpCount, 0)
    }

    func testARunningPassShowsNoCalmLineBeforeTheSummarySortsTheRows() {
        let status = BackupStatus(
            progress: progress(total: 10, uploaded: 5, waiting: 3, failed: 2, isRunning: true), isScanning: false)
        XCTAssertTrue(status.isActive)
        XCTAssertNil(BackupStatusPresentation(status).localizedNotBackedUp)
    }

    func testAFullProtonStorageAsksThePersonWhileItsRowsWait() {
        var raw = progress(total: 10, uploaded: 7, waiting: 3)
        raw.outstanding = BackupOutstandingSnapshot(count: 3, issue: .accountStorage)
        let display = BackupStatusPresentation(BackupStatus(progress: raw, isScanning: false))
        XCTAssertEqual(display.headlineKey, "backup.phase_waiting_account_storage")
        XCTAssertEqual(display.accessory, .attention)
        XCTAssertEqual(
            BackupSettingsSummary(isAvailable: true, isEnabled: true, isUserPaused: false, display: display),
            .incomplete)

        raw.outstanding = BackupOutstandingSnapshot(count: 3, issue: .deviceStorage)
        let device = BackupStatusPresentation(BackupStatus(progress: raw, isScanning: false))
        XCTAssertEqual(device.headlineKey, "backup.phase_waiting_storage")
        XCTAssertEqual(device.accessory, .waiting, "device storage stays calm")
    }

    func testTheWaitingLineNamesProtonOnlyForATemporaryProtonWait() {
        var raw = progress(total: 10, uploaded: 7, waiting: 3)
        raw.outstanding = BackupOutstandingSnapshot(count: 3, issue: .remoteService)
        let proton = BackupStatusPresentation(BackupStatus(progress: raw, isScanning: false))
        XCTAssertEqual(proton.headlineKey, "backup.phase_waiting_proton")
        XCTAssertEqual(proton.localizedWaitingDetail, L10n.string("backup.progress_waiting \(3)"))

        for issue in [BackupIssueKind.network, .deviceStorage, .unknown] {
            raw.outstanding = BackupOutstandingSnapshot(count: 3, issue: issue)
            let other = BackupStatusPresentation(BackupStatus(progress: raw, isScanning: false))
            XCTAssertEqual(other.localizedWaitingDetail, L10n.string("backup.detail_waiting \(3)"), "\(issue)")
        }
    }

    // MARK: - Index preparation

    func testAnIndexFailureIsAProtonWaitOnlyForATemporaryProtonFailure() {
        let cases: [(UploadError, BackupIssueKind)] = [
            (.retryableBackend(code: 503, message: "busy"), .remoteService),
            (.backend("local"), .unknown),
            (.serviceRejected(code: 422), .unknown),
            (.transport(code: -1009, message: "offline"), .network),
            (.accountStorageFull("full", requiredBytes: 2, availableBytes: 1), .accountStorage),
        ]
        for (error, kind) in cases {
            XCTAssertEqual(BackupSyncRunner.indexPreparationIssueKind(for: error), kind, "\(error)")
        }
    }
}
