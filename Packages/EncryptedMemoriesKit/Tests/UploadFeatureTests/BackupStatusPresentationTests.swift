import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// The shared display projection of `BackupStatus`: a compact, honest row - an icon, a phase
/// headline, one overall-progress subtitle line ("<n> of <m>"), and an optional attention line.
/// Same model on every platform.
final class BackupStatusPresentationTests: XCTestCase {
    func testFailedItemOwnsSharedRetryPresentation() {
        let item = BackupFailedItem(
            id: "retry",
            filename: "photo.jpg",
            reason: "Retry",
            isPermanent: false,
            issue: .network,
            nextAttemptAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNotNil(item.retryDescription)
        XCTAssertNil(
            BackupFailedItem(
                id: "now",
                filename: "photo.jpg",
                reason: "Retry",
                isPermanent: false
            ).retryDescription)
    }

    private func progress(
        total: Int = 0, waiting: Int = 0, uploadQueued: Int = 0, checking: Int = 0,
        uploading: Int = 0, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        skippedRemoteDeletions: Int = 0, sourceMissing: Int = 0, blocked: Int = 0,
        failed: Int = 0, dismissedFailures: Int = 0, attention: Int = 0,
        isRunning: Bool = false, isPausedByPolicy: Bool = false,
        activeTransfer: BackupActiveTransferProgress? = nil
    ) -> BackupSyncProgress {
        var p = BackupSyncProgress()
        p.attention = attention
        p.total = total
        p.waiting = waiting
        p.uploadQueued = uploadQueued
        p.checking = checking
        p.uploading = uploading
        p.uploaded = uploaded
        p.alreadyBackedUp = alreadyBackedUp
        p.skippedRemoteDeletions = skippedRemoteDeletions
        p.sourceMissing = sourceMissing
        p.blocked = blocked
        p.failed = failed
        p.dismissedFailures = dismissedFailures
        p.isRunning = isRunning
        p.isPausedByPolicy = isPausedByPolicy
        p.activeTransfer = activeTransfer
        return p
    }

    private func status(_ p: BackupSyncProgress, isScanning: Bool = false) -> BackupStatus {
        BackupStatus(progress: p, isScanning: isScanning)
    }

    func testUnknownPhotoScanPreservesWiFiAndAttentionReasons() throws {
        let context = BackupStatusProjectionContext(
            isRunning: true, photoDisplay: .init(cycleID: UUID()))
        for phase in [BackupStatus.Phase.waitingForWiFi, .needsAttention] {
            var status = BackupStatus()
            status.phase = phase
            status.totalConsidered = 10
            status.fractionCompleted = 0.4
            status.alreadyBackedUp = 4
            status.photoDisplayProgress = context.photoProgress(for: status, fraction: 0.4)
            XCTAssertEqual(status.photoDisplayProgress?.isChecking, false, "\(phase)")
            let display = BackupStatusPresentation(status)
            XCTAssertEqual(
                display.headlineKey, phase == .waitingForWiFi ? "backup.phase_waiting_wifi" : "backup.phase_attention")
            XCTAssertEqual(display.accessory, phase == .waitingForWiFi ? .waitingForWiFi : .attention)
            XCTAssertFalse(display.isActive)
            XCTAssertNil(display.progressFraction)
            XCTAssertNil(display.localizedSubtitle)
        }
    }

    /// A pass that waits for a reason is not checking: between its start and its scan, and after a failed scan, the row
    /// keeps the real reason (for example a full Proton storage) instead of "Checking".
    func testUnknownPhotoScanPreservesEveryWaitingReason() throws {
        let context = BackupStatusProjectionContext(
            isRunning: true, photoDisplay: .init(cycleID: UUID()))
        let reasons: [(BackupIssueKind, String)] = [
            (.network, "backup.phase_waiting_network"),
            (.remoteService, "backup.phase_waiting_proton"),
            (.deviceStorage, "backup.phase_waiting_storage"),
            (.accountStorage, "backup.phase_waiting_account_storage"),
            (.remoteDraft, "backup.phase_waiting_draft"),
        ]
        for (issue, headlineKey) in reasons {
            var status = BackupStatus()
            status.phase = .waiting
            status.outstandingIssue = issue
            status.outstandingCount = 6
            status.totalConsidered = 10
            status.fractionCompleted = 0.4
            status.alreadyBackedUp = 4
            status.photoDisplayProgress = context.photoProgress(for: status, fraction: 0.4)
            XCTAssertEqual(status.photoDisplayProgress?.isChecking, false, "\(issue)")
            let display = BackupStatusPresentation(status)
            XCTAssertEqual(display.headlineKey, headlineKey, "\(issue)")
            // A full Proton storage is the person's to fix, so its wait asks the person (D5).
            XCTAssertEqual(display.accessory, issue == .accountStorage ? .attention : .waiting, "\(issue)")
            XCTAssertFalse(display.isActive, "\(issue)")
            XCTAssertNil(display.progressFraction, "\(issue)")
            XCTAssertNil(display.localizedSubtitle, "\(issue)")
        }
    }

    func testCheckingHeadlineWhenNoBytesAreMoving() {
        // A running pass with no in-flight upload is checking - never "backing up".
        let s = status(progress(total: 100, uploadQueued: 5, checking: 1, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_checking")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.accessory, .activity)
    }

    func testPerFileProgressNeverLeaksIntoOverallSubtitle() {
        let raw = progress(total: 100, uploadQueued: 5, checking: 1, uploading: 1, alreadyBackedUp: 20, isRunning: true)
        let p = BackupStatusPresentation(status(raw))
        XCTAssertEqual(p.headlineKey, "backup.phase_uploading")
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        XCTAssertEqual(subtitle?.contains("43"), false)
        XCTAssertEqual(subtitle?.contains("%"), false)
        XCTAssertFalse(subtitle?.contains("IMG_5560.MOV") ?? true, "no filename in the subtitle")
    }

    func testSubtitleIsCountOfBackedUpOverTotalWithNoPercentWhenNotUploading() {
        let s = status(progress(total: 100, checking: 1, uploaded: 10, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.backedUp, 30)
        XCTAssertEqual(p.total, 100)
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        XCTAssertEqual(subtitle?.contains("30"), true)
        XCTAssertEqual(subtitle?.contains("100"), true)
        XCTAssertEqual(subtitle?.contains("%"), false)
    }

    func testTransferLivenessIsSeparateFromStableBackedUpCount() async throws {
        let transfer = BackupActiveTransferProgress(
            activeItemCount: 2,
            completedBytes: 51,
            totalBytes: 100,
            completedItemEquivalents: 0.75
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        defer { queue.close() }
        XCTAssertTrue(
            queue.upsertBatch(
                (0..<100).map { index in
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "photo-\(index)", resource: .primary),
                        revision: .init(date: Date(timeIntervalSinceReferenceDate: 42)),
                        originalFilename: "photo.heic",
                        state: index < 20 ? .alreadyBackedUp : index < 22 ? .uploading : .discovered,
                        updatedAt: Date())
                }))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        let context = BackupStatusProjectionContext(
            isRunning: true, photoDisplay: .init(cycleID: UUID(), scanFinished: true))
        await projector.start(generation: generation, context: context) { _ in }
        var live = BackupSyncProgress()
        live.activeTransfer = transfer
        projector.submit(live, generation: generation)
        await projector.drainSubmittedEvents()
        let projected = await projector.projectNow(context: context, generation: generation, revision: 1)
        let raw = try XCTUnwrap(projected?.status)
        let presentation = BackupStatusPresentation(raw)

        XCTAssertEqual(presentation.backedUp, 20)
        XCTAssertEqual(raw.activeTransfer, transfer)
        XCTAssertEqual(raw.activeTransfer?.fraction, 0.51)
        XCTAssertEqual(raw.fractionCompleted, projected?.progress.fraction)
        XCTAssertEqual(presentation.progressFraction, 0.20)
        XCTAssertTrue(try XCTUnwrap(presentation.localizedSubtitle).contains("20"))
        for (index, bytes) in [2, 98].enumerated() {
            live.activeTransfer = .init(
                activeItemCount: 1, completedBytes: Int64(bytes), totalBytes: 100, completedItemEquivalents: 0.1)
            projector.submit(live, generation: generation)
            await projector.drainSubmittedEvents()
            let changed = await projector.projectNow(
                context: context, generation: generation, revision: UInt64(index + 2))
            let changedStatus = try XCTUnwrap(changed?.status)
            XCTAssertEqual(changedStatus.activeTransfer, live.activeTransfer)
            XCTAssertEqual(BackupStatusPresentation(changedStatus).progressFraction, 0.20)
        }
        await projector.stop()
    }

    func testScanningHasNoFakeProgressAndNoSubtitle() {
        let s = status(progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(s.phase, .scanning)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_scanning")
        XCTAssertNil(p.progressFraction, "scanning must stay indeterminate")
        XCTAssertNil(p.localizedSubtitle, "no honest total mid-scan => no subtitle")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.detailLayout, .compact, "scanning must not reserve empty progress rows")
    }

    func testKnownTotalActivePassUsesStableExpandedDetails() {
        let checking = BackupStatusPresentation(
            status(
                progress(
                    total: 100, checking: 1, alreadyBackedUp: 20, isRunning: true
                )))
        let uploading = BackupStatusPresentation(
            status(
                progress(
                    total: 100, uploading: 1, alreadyBackedUp: 20, isRunning: true
                )))

        XCTAssertEqual(checking.detailLayout, .progress)
        XCTAssertEqual(uploading.detailLayout, .progress)
    }

    func testCompletedIsSuccessAndNotActive() {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 6))
        XCTAssertEqual(s.phase, .completed)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.accessory, .success)
        XCTAssertEqual(p.detailLayout, .compact, "completion must collapse the active progress slots")
        XCTAssertNil(p.progressFraction)
    }

    func testCompletedRemoteDeletionsAreInformationalAndExcludedFromBackupTarget() throws {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 3, skippedRemoteDeletions: 3))

        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.backedUp, 7)
        XCTAssertEqual(s.backupTargetCount, 7)
        XCTAssertEqual(s.needsAttentionCount, 0)

        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed_with_remote_deletions")
        XCTAssertEqual(p.accessory, .success)
        XCTAssertEqual(p.total, 7)
        XCTAssertEqual(p.skippedRemoteDeletions, 3)
        XCTAssertNil(p.localizedAttention)
        XCTAssertTrue(try XCTUnwrap(p.localizedSubtitle).contains("7"))
        XCTAssertTrue(try XCTUnwrap(p.localizedRemoteDeletionDetail).contains("3"))
    }

    func testAcknowledgedPermanentFailureEndsCalmlyWithoutClaimingEverythingIsBackedUp() {
        let s = status(progress(total: 10, uploaded: 9, dismissedFailures: 1))
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.backedUp, 9)
        XCTAssertEqual(s.totalConsidered, 10)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed_with_omissions")
        XCTAssertEqual(p.accessory, .notice)
        XCTAssertEqual(p.backedUp, 9)
        XCTAssertEqual(p.total, 10)
        XCTAssertNil(p.localizedAttention)
    }

    func testAttentionLineAppearsOnlyWhenSomethingNeedsTheUser() {
        let clean = BackupStatusPresentation(
            status(progress(total: 10, checking: 1, alreadyBackedUp: 5, isRunning: true)))
        XCTAssertNil(clean.localizedAttention, "nothing failed => no attention line")

        let s = status(progress(total: 10, uploaded: 5, sourceMissing: 1, failed: 2, attention: 3))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_attention")
        XCTAssertEqual(p.attentionCount, s.needsAttentionCount)
        XCTAssertNotNil(p.localizedAttention)
        XCTAssertEqual(p.accessory, .attention)
    }

    func testAttentionCountExcludesRetryableDraftsWhenFailuresCoexist() {
        let s = status(
            progress(total: 20, uploaded: 8, alreadyBackedUp: 9, sourceMissing: 1, blocked: 2, attention: 1))
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .needsAttention)
        XCTAssertEqual(p.attentionCount, 1)
        XCTAssertNotNil(p.localizedAttention)
    }

    func testRemoteIndexInterruptionDoesNotReportWholeBacklogAsFailed() throws {
        var raw = progress(total: 1_481, waiting: 1_481)
        raw.remoteIndexPreparationFailed = true
        raw.remoteIndexPreparationIssue = BackupIssueRecord(
            kind: .remoteService,
            detail: "temporary service interruption",
            nextAttemptAt: Date(timeIntervalSince1970: 1_000)
        )
        let s = status(raw)
        let p = BackupStatusPresentation(s)

        XCTAssertEqual(s.phase, .waiting)
        XCTAssertEqual(p.headlineKey, "backup.phase_waiting_proton")
        XCTAssertEqual(p.accessory, .waiting)
        XCTAssertEqual(s.totalConsidered, 1_481, "the backlog remains truthfully unfinished")
        XCTAssertEqual(s.backedUp, 0)
        XCTAssertEqual(p.attentionCount, 0, "unfinished work must not be labeled as failed media")
        XCTAssertNil(p.localizedAttention)
        XCTAssertNil(p.localizedSystemIssue, "a retry is scheduled: the headline and the next attempt say so")
        XCTAssertEqual(p.nextAttemptAt, Date(timeIntervalSince1970: 1_000))
    }

    func testBackgroundSchedulingFailureIsASeparateActionableSystemIssue() throws {
        let raw = progress(total: 10, waiting: 1, alreadyBackedUp: 9)
        let status = BackupStatus(
            progress: raw,
            isScanning: false,
            executionOpportunityIssue: .backgroundRefreshUnavailable
        )
        let presentation = BackupStatusPresentation(status)

        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting")
        XCTAssertNil(presentation.localizedAttention, "scheduler failures do not belong in the per-photo sheet")
        XCTAssertEqual(
            try XCTUnwrap(presentation.localizedSystemIssue),
            PhotosCore.L10n.string("backup.background_unavailable_action"))
    }

    /// Only an issue that the person can act on shows a line: the two permission cases share one text, a failed
    /// registration keeps its restart text, and the scheduling issues that iOS and the app retry on their own show
    /// nothing.
    func testEveryBackgroundIssueShowsItsLineOrNone() {
        let expectations: [(BackupExecutionOpportunityIssue, String?)] = [
            (.backgroundRefreshUnavailable, "backup.background_unavailable_action"),
            (.backgroundLaunchNotPermitted, "backup.background_unavailable_action"),
            (.registrationFailed, "backup.error_background_registration"),
            (.schedulerCapacity, nil),
            (.immediateRunIneligible, nil),
            (.unknown, nil),
        ]
        for (issue, key) in expectations {
            let presentation = BackupStatusPresentation(
                BackupStatus(
                    progress: progress(total: 10, waiting: 1, alreadyBackedUp: 9), isScanning: false,
                    executionOpportunityIssue: issue))
            XCTAssertEqual(
                presentation.localizedSystemIssue, key.map { PhotosCore.L10n.string(dynamicKey: $0) }, "\(issue)")
        }
    }

    /// An index failure with a scheduled retry shows no extra line, and a needs-attention detail counts the files.
    func testAFailedIndexPreparationNamesNoDetailOfItsOwn() {
        var raw = progress(total: 10, alreadyBackedUp: 8, failed: 2, attention: 2)
        raw.remoteIndexPreparationFailed = true
        let status = BackupStatus(progress: raw, isScanning: false)

        XCTAssertEqual(status.phase, .needsAttention)
        XCTAssertEqual(status.localizedDetail, PhotosCore.L10n.string("backup.detail_attention \(2)"))
        XCTAssertNil(BackupStatusPresentation(status).localizedSystemIssue)
    }

    /// While items need attention, a failed index preparation keeps its retry date but names no cause of its own.
    func testAFailedIndexPreparationKeepsItsRetryDateButNoCauseWhileItemsNeedAttention() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        var raw = progress(total: 10, alreadyBackedUp: 8, failed: 2, attention: 2)
        raw.remoteIndexPreparationFailed = true
        raw.remoteIndexPreparationIssue = BackupIssueRecord(kind: .network, detail: "offline", nextAttemptAt: retryAt)
        let presentation = BackupStatusPresentation(BackupStatus(progress: raw, isScanning: false))

        XCTAssertEqual(presentation.headlineKey, "backup.phase_attention")
        XCTAssertEqual(presentation.nextAttemptAt, retryAt)
        XCTAssertNil(presentation.localizedSystemIssue)
    }

    func testPausedKeepsProgressButIsNotActive() {
        let s = status(progress(total: 10, checking: 1, uploaded: 3, isRunning: true, isPausedByPolicy: true))
        XCTAssertEqual(s.phase, .paused)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_paused")
        XCTAssertEqual(p.accessory, .paused)
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.detailLayout, .progress, "pausing must retain the known progress geometry")
    }

    func testWaitingDraftNamesTheBlockerAndShowsExactRetry() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        var raw = progress(total: 10, alreadyBackedUp: 9, blocked: 1)
        raw.outstanding = BackupOutstandingSnapshot(count: 1, issue: .remoteDraft, nextAttemptAt: retryAt)

        let presentation = BackupStatusPresentation(status(raw))

        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting_draft")
        XCTAssertEqual(presentation.nextAttemptAt, retryAt)
        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertEqual(presentation.attentionCount, 0)
        XCTAssertEqual(presentation.waitingCount, 1)
        XCTAssertNotNil(presentation.localizedWaitingDetail)
        XCTAssertNotNil(presentation.localizedRetryDetail)
    }

    func testWaitingProtonNamesTheCauseAndPreservesItsRetryDate() throws {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        var raw = progress(total: 1, waiting: 1)
        raw.outstanding = .init(count: 1, issue: .remoteService, nextAttemptAt: retryAt)
        let presentation = BackupStatusPresentation(status(raw))
        XCTAssertEqual(presentation.headlineKey, "backup.phase_waiting_proton")
        XCTAssertEqual(presentation.nextAttemptAt, retryAt)
        XCTAssertEqual(presentation.accessory, .waiting)
        XCTAssertNil(presentation.localizedAttention)
        XCTAssertFalse(presentation.localizedHeadline.isEmpty)
    }

    func testSilentSystemIssuesWithoutRowsKeepIdleAndShowNoLine() {
        var raw = progress()
        raw.remoteIndexPreparationFailed = true
        let presentation = BackupStatusPresentation(
            BackupStatus(progress: raw, isScanning: false, executionOpportunityIssue: .schedulerCapacity))
        XCTAssertEqual(presentation.headlineKey, "backup.phase_idle")
        XCTAssertEqual(presentation.accessory, .idle)
        XCTAssertEqual(presentation.attentionCount, 0)
        XCTAssertNil(presentation.localizedSystemIssue)
        let schedulerOnly = BackupStatusPresentation(
            BackupStatus(progress: progress(), isScanning: false, executionOpportunityIssue: .schedulerCapacity))
        XCTAssertEqual(schedulerOnly.headlineKey, "backup.phase_idle")
        XCTAssertNil(schedulerOnly.localizedSystemIssue)
    }

    func testFailedHeadlineStatesTheCountAndOffersReasons() {
        let presentation = BackupStatusPresentation(status(progress(total: 3, uploaded: 1, failed: 2, attention: 2)))
        XCTAssertEqual(presentation.localizedHeadline, PhotosCore.L10n.string("backup.phase_not_backed_up \(2)"))
    }

    func testRetryDatesAppearOnlyForAutomaticRowsAndSectionsShareMembership() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        for category in [BackupIssueCategory.automatic, .userResolvable, .decision, .permanent] {
            let item = BackupFailedItem(
                id: category.rawValue, filename: "photo", reason: "reason", isPermanent: category == .permanent,
                nextAttemptAt: retryAt, category: category)
            XCTAssertEqual(item.retryDescription != nil, category == .automatic)
            XCTAssertFalse(category.symbolName.isEmpty)
        }
        XCTAssertEqual(BackupIssueCategory.automatic.section, .continuesByItself)
        XCTAssertEqual(BackupIssueCategory.userResolvable.section, .actionNeeded)
        XCTAssertEqual(BackupIssueCategory.decision.section, .actionNeeded)
        XCTAssertEqual(BackupIssueCategory.permanent.section, .notPossible)
        XCTAssertEqual(BackupIssueSection.allCases, [.actionNeeded, .continuesByItself, .notPossible])
    }

    func testIdleIsCalmWithNoSubtitle() {
        let idle = BackupStatusPresentation(status(progress()))
        XCTAssertEqual(idle.headlineKey, "backup.phase_idle")
        XCTAssertNil(idle.localizedSubtitle)
        XCTAssertEqual(idle.accessory, .idle)
    }

    func testMappingIsDeterministic() {
        let s = status(progress(total: 100, checking: 1, alreadyBackedUp: 40, isRunning: true))
        XCTAssertEqual(BackupStatusPresentation(s), BackupStatusPresentation(s))
    }
}
