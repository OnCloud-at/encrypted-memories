import Foundation
import PhotosCore
import XCTest

@testable import UploadCore
@testable import UploadFeature

/// The guide for a large first backup (#275): one hint while it runs, one completion headline when it ends.
final class BackupFirstBackupGuideTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "BackupFirstBackupGuideTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func status(
        _ phase: BackupStatus.Phase, total: Int, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        dismissedFailures: Int = 0, skippedRemoteDeletions: Int = 0, remaining: Int = 0,
        guide: BackupFirstBackupGuide.State? = nil, totalKnown: Bool? = nil
    ) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.totalConsidered = total
        status.uploaded = uploaded
        status.alreadyBackedUp = alreadyBackedUp
        status.dismissedFailures = dismissedFailures
        status.skippedRemoteDeletions = skippedRemoteDeletions
        status.remainingCount = remaining
        status.firstBackupGuide = guide
        status.photoDisplayProgress = totalKnown.map {
            BackupPhotoDisplayProgress(isTotalKnown: $0, isChecking: false, fraction: nil)
        }
        return status
    }

    private let threshold = BackupFirstBackupGuide.largeBackupThreshold

    // MARK: - Photos that are not backed up

    /// A first backup that ends with photos that are not backed up is no plain completion, also when nothing asks the
    /// person: the calm photos make it end quietly, without the completion headline.
    func testACompletionWithCalmPhotosEndsTheGuideQuietly() {
        var calm = status(.completed, total: 2_000, uploaded: 1_997, guide: .running, totalKnown: true)
        calm.failed = 3
        XCTAssertEqual(calm.needsAttentionCount, 0)
        XCTAssertTrue(calm.hasOmissions)
        XCTAssertEqual(BackupFirstBackupGuide.next(.running, after: calm), .done)
        XCTAssertNotEqual(BackupStatusPresentation(calm).headlineKey, "backup.phase_first_completed")
    }

    /// A status that asks the person shows no hint about speed: photos that need the person, or a full Proton storage.
    func testAStatusThatAsksThePersonShowsNoHint() {
        var attention = status(.needsAttention, total: 2_000, uploaded: 500, guide: .running, totalKnown: true)
        attention.failed = 1
        attention.needsAttentionCount = 1
        XCTAssertEqual(BackupStatusPresentation(attention).accessory, .attention)
        XCTAssertFalse(BackupStatusPresentation(attention).showsLargeBackupHint)

        var storage = status(.waiting, total: 2_000, uploaded: 500, remaining: 1_500, guide: .running, totalKnown: true)
        storage.outstandingIssue = .accountStorage
        storage.outstandingCount = 1_500
        XCTAssertEqual(BackupStatusPresentation(storage).accessory, .attention)
        XCTAssertFalse(BackupStatusPresentation(storage).showsLargeBackupHint)

        storage.outstandingIssue = .network
        XCTAssertTrue(BackupStatusPresentation(storage).showsLargeBackupHint, "a calm wait keeps the hint")
    }

    // MARK: - Steps

    /// The first status decides whether this can be a first backup at all.
    func testTheFirstStatusMakesAFirstBackupCandidateOnlyWithNothingBackedUp() {
        for phase in [BackupStatus.Phase.idle, .scanning, .checking, .uploading, .waiting] {
            XCTAssertEqual(BackupFirstBackupGuide.next(nil, after: status(phase, total: 5_000)), .candidate, "\(phase)")
        }
        XCTAssertEqual(BackupFirstBackupGuide.next(nil, after: status(.uploading, total: 5_000, uploaded: 1)), .done)
        XCTAssertEqual(BackupFirstBackupGuide.next(nil, after: status(.completed, total: 20, uploaded: 20)), .done)
    }

    /// The first active status after the scan decides, once: checking or uploading with a known total. A large backup
    /// is guided, a smaller one is not.
    func testTheFirstActiveStatusAfterTheScanDecides() {
        for phase in [BackupStatus.Phase.checking, .uploading] {
            XCTAssertEqual(
                BackupFirstBackupGuide.next(.candidate, after: status(phase, total: threshold)), .running, "\(phase)")
            XCTAssertEqual(
                BackupFirstBackupGuide.next(.candidate, after: status(phase, total: threshold - 1)), .done,
                "a smaller backup is not guided: \(phase)")
        }
    }

    /// A few photos that Proton already holds, as duplicates or remote proofs, do not stop a large first backup.
    func testAFewPhotosAlreadyInProtonDoNotStopALargeFirstBackup() {
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.scanning, total: 5_000, alreadyBackedUp: 2)),
            .candidate)
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.checking, total: 5_000, alreadyBackedUp: 2)),
            .running)
    }

    /// A reinstall over a backed-up library finds most photos in Proton during the scan: fewer than the threshold are
    /// left when it starts checking.
    func testAReinstallOverABackedUpLibraryEndsQuietly() {
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.checking, total: 5_000, alreadyBackedUp: 4_990)),
            .done)
    }

    /// A first pass that is completed or needs attention before it checks anything ends the candidate, and a small
    /// first check ends it too, so a later pass on a grown library never starts the guide.
    func testAFirstPassThatEndsBeforeItChecksEndsTheCandidate() {
        XCTAssertEqual(BackupFirstBackupGuide.next(.candidate, after: status(.needsAttention, total: 3)), .done)
        XCTAssertEqual(BackupFirstBackupGuide.next(.candidate, after: status(.completed, total: 3, uploaded: 3)), .done)
        var step = BackupFirstBackupGuide.next(.candidate, after: status(.uploading, total: 3))
        XCTAssertEqual(step, .done, "a small first check ends it")
        step = BackupFirstBackupGuide.next(step, after: status(.needsAttention, total: 3))
        XCTAssertEqual(step, .done)
        XCTAssertEqual(BackupFirstBackupGuide.next(step, after: status(.checking, total: 9_000)), .done)
    }

    /// Scan and upload run in parallel: photos that this backup uploaded while it scanned do not end the candidate.
    func testUploadsDuringTheScanKeepTheCandidate() {
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.scanning, total: 5_000, uploaded: 40)), .candidate)
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.checking, total: 5_000, uploaded: 40)), .running)
    }

    /// Before the first check nothing decides: the scan, waits and pauses keep the candidate.
    func testNoPhaseBeforeTheFirstCheckDecides() {
        for phase in [BackupStatus.Phase.scanning, .paused, .waiting, .waitingForWiFi, .idle] {
            XCTAssertEqual(
                BackupFirstBackupGuide.next(.candidate, after: status(phase, total: 5_000)), .candidate, "\(phase)")
        }
    }

    /// While the photo total is unknown, after a scan that failed or stopped, the photos so far are only part of the
    /// library: a count that already reaches the threshold starts the guide, but nothing ends the candidate until a
    /// scan has counted every photo.
    func testAnUnknownPhotoTotalNeverEndsTheCandidate() {
        let small = threshold - 1
        for unknown in [
            status(.checking, total: small, totalKnown: false), status(.uploading, total: small, totalKnown: false),
            status(.completed, total: small, uploaded: small, totalKnown: false),
            status(.needsAttention, total: small, totalKnown: false),
        ] {
            XCTAssertEqual(BackupFirstBackupGuide.next(.candidate, after: unknown), .candidate, "\(unknown.phase)")
        }
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.checking, total: threshold, totalKnown: false)),
            .running, "a partial count that reaches the threshold is large in any case")
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.candidate, after: status(.checking, total: small, totalKnown: true)), .done)
        XCTAssertEqual(
            BackupFirstBackupGuide.next(
                .candidate, after: status(.completed, total: small, uploaded: small, totalKnown: true)),
            .done)
    }

    func testAPlainCompletionAfterUploadsShowsTheCompletionUntilTheScreenIsSeen() {
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.running, after: status(.completed, total: 1_200, uploaded: 1_200)),
            .completedUnseen)
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.completedUnseen, after: status(.completed, total: 1_200, uploaded: 1_200)),
            .completedUnseen)
        XCTAssertEqual(BackupFirstBackupGuide.afterScreenSeen(.completedUnseen), .done)
    }

    /// Omissions, respected deletions and a library that was already backed up end the guide without the headline.
    func testOtherCompletionsEndTheGuideWithoutTheHeadline() {
        let endings = [
            status(.completed, total: 1_200, uploaded: 1_000, dismissedFailures: 1),
            status(.completed, total: 1_200, uploaded: 1_000, skippedRemoteDeletions: 2),
            status(.completed, total: 1_200, alreadyBackedUp: 1_200),
        ]
        for ending in endings {
            XCTAssertEqual(BackupFirstBackupGuide.next(.running, after: ending), .done)
        }
    }

    /// A pass that completes while the photo total is unknown backed up only the photos found so far: the guide keeps
    /// running, and the next completion after a scan that counted every photo shows the headline.
    func testACompletionWhileThePhotoTotalIsUnknownKeepsTheGuideRunning() {
        let partial = status(.completed, total: 2_000, uploaded: 2_000, totalKnown: false)
        XCTAssertEqual(BackupFirstBackupGuide.next(.running, after: partial), .running)
        XCTAssertFalse(BackupStatusPresentation(status(.completed, total: 2_000, guide: .running)).showsLargeBackupHint)
        let scanned = status(.completed, total: 30_000, uploaded: 30_000, totalKnown: true)
        XCTAssertEqual(BackupFirstBackupGuide.next(.running, after: scanned), .completedUnseen)
    }

    func testTheGuideKeepsRunningThroughWaitsProblemsAndIdle() {
        for phase in [BackupStatus.Phase.waiting, .paused, .waitingForWiFi, .needsAttention, .idle, .checking] {
            XCTAssertEqual(
                BackupFirstBackupGuide.next(.running, after: status(phase, total: 1_200, uploaded: 300)), .running,
                "\(phase)")
        }
        XCTAssertEqual(BackupFirstBackupGuide.afterScreenSeen(.running), .running)
    }

    /// A new run with work ends an unseen completion; a run without remaining work, or an idle status, keeps it.
    func testOnlyANewRunWithWorkEndsAnUnseenCompletion() {
        XCTAssertEqual(
            BackupFirstBackupGuide.next(
                .completedUnseen, after: status(.uploading, total: 1_210, uploaded: 1_200, remaining: 10)),
            .done)
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.completedUnseen, after: status(.checking, total: 1_200, uploaded: 1_200)),
            .completedUnseen, "no remaining work")
        XCTAssertEqual(
            BackupFirstBackupGuide.next(.completedUnseen, after: status(.idle, total: 0)), .completedUnseen)
        XCTAssertEqual(BackupFirstBackupGuide.next(.done, after: status(.uploading, total: 9_000)), .done)
    }

    // MARK: - Presentation

    func testTheHintShowsOnlyWhileTheGuidedBackupRuns() {
        XCTAssertTrue(
            BackupStatusPresentation(status(.uploading, total: 1_200, uploaded: 10, guide: .running))
                .showsLargeBackupHint)
        XCTAssertTrue(
            BackupStatusPresentation(status(.waiting, total: 1_200, uploaded: 10, guide: .running))
                .showsLargeBackupHint)
        XCTAssertFalse(BackupStatusPresentation(status(.idle, total: 0, guide: .running)).showsLargeBackupHint)
        XCTAssertFalse(BackupStatusPresentation(status(.uploading, total: 1_200)).showsLargeBackupHint)
        XCTAssertFalse(
            BackupStatusPresentation(status(.uploading, total: 1_200, guide: .done)).showsLargeBackupHint)
        XCTAssertFalse(
            BackupStatusPresentation(status(.completed, total: 1_200, uploaded: 1_200, guide: .completedUnseen))
                .showsLargeBackupHint)
    }

    func testAnUnseenCompletionShowsTheFirstBackupHeadlineAndDetail() {
        let completed = BackupStatusPresentation(
            status(.completed, total: 1_200, uploaded: 1_200, guide: .completedUnseen))
        XCTAssertEqual(completed.headlineKey, "backup.phase_first_completed")
        XCTAssertEqual(completed.localizedHeadline, L10n.string("backup.phase_first_completed"))
        XCTAssertEqual(completed.localizedSubtitle, L10n.string("backup.detail_first_completed \(1_200)"))
        XCTAssertEqual(completed.accessory, .success)

        let seen = BackupStatusPresentation(status(.completed, total: 1_200, uploaded: 1_200, guide: .done))
        XCTAssertEqual(seen.localizedHeadline, L10n.string("backup.phase_completed"))
        XCTAssertEqual(seen.localizedSubtitle, L10n.string("counts.backed_up \(L10n.ofTotal(1_200, of: 1_200))"))
        let omitted = BackupStatusPresentation(
            status(.completed, total: 1_200, uploaded: 1_100, dismissedFailures: 1, guide: .completedUnseen))
        XCTAssertEqual(omitted.headlineKey, "backup.phase_completed_with_omissions")
    }

    /// With the photo progress: a pass that runs without a known total reads "Checking", never the completion. After a
    /// relaunch, before a scan knows the total again, an unseen completion keeps its headline but names no count: "All N
    /// files" would claim a total the app does not know. Once a scan knows the total, the count returns.
    func testTheCompletionHeadlineFollowsThePhotoProgressKnowledge() {
        var running = status(.completed, total: 1_200, uploaded: 1_200, guide: .completedUnseen)
        running.photoDisplayProgress = BackupPhotoDisplayProgress(isTotalKnown: false, isChecking: true, fraction: nil)
        let checking = BackupStatusPresentation(running)
        XCTAssertEqual(checking.headlineKey, "backup.phase_checking")
        XCTAssertNil(checking.localizedSubtitle)

        var relaunched = status(.completed, total: 1_200, uploaded: 1_200, guide: .completedUnseen)
        relaunched.photoDisplayProgress = BackupPhotoDisplayProgress(
            isTotalKnown: false, isChecking: false, fraction: nil)
        let unseen = BackupStatusPresentation(relaunched)
        XCTAssertEqual(unseen.headlineKey, "backup.phase_first_completed")
        XCTAssertNil(unseen.localizedSubtitle, "no count while the total is unknown")
        XCTAssertNil(unseen.progressFraction)

        var scanned = status(.completed, total: 1_200, uploaded: 1_200, guide: .completedUnseen)
        scanned.photoDisplayProgress = BackupPhotoDisplayProgress(isTotalKnown: true, isChecking: false, fraction: nil)
        let known = BackupStatusPresentation(scanned)
        XCTAssertEqual(known.headlineKey, "backup.phase_first_completed")
        XCTAssertEqual(known.localizedSubtitle, L10n.string("backup.detail_first_completed \(1_200)"))
    }

    /// While the photo total is unknown, a running guided backup still shows its hint: under "Checking" while the pass
    /// runs, and, as accepted for #275, also while it is paused or needs attention.
    func testTheHintFollowsTheGuideWhileThePhotoTotalIsUnknown() {
        var running = status(.uploading, total: 1_200, uploaded: 10, guide: .running)
        running.photoDisplayProgress = BackupPhotoDisplayProgress(isTotalKnown: false, isChecking: true, fraction: nil)
        let checking = BackupStatusPresentation(running)
        XCTAssertEqual(checking.headlineKey, "backup.phase_checking")
        XCTAssertTrue(checking.showsLargeBackupHint)
        XCTAssertNil(checking.progressFraction)

        for (phase, headlineKey) in [
            (BackupStatus.Phase.paused, "backup.phase_paused"), (.needsAttention, "backup.phase_attention"),
        ] {
            var held = status(phase, total: 1_200, uploaded: 10, guide: .running)
            held.photoDisplayProgress = BackupPhotoDisplayProgress(
                isTotalKnown: false, isChecking: false, fraction: nil)
            let display = BackupStatusPresentation(held)
            XCTAssertEqual(display.headlineKey, headlineKey, "\(phase)")
            // A status that asks the person shows no hint about speed.
            XCTAssertEqual(display.showsLargeBackupHint, phase != .needsAttention, "\(phase)")
            XCTAssertNil(display.localizedSubtitle, "\(phase)")
        }
    }

    func testTheHostHintFollowsThePlatform() {
        let hint = BackupStatusPresentation(status(.uploading, total: 1_200, guide: .running))
            .localizedLargeBackupHint
        #if os(macOS)
            XCTAssertEqual(hint, L10n.string("backup.hint_large_backup_mac"))
        #else
            XCTAssertEqual(hint, L10n.string("backup.hint_large_backup"))
        #endif
        XCTAssertNil(BackupStatusPresentation(status(.uploading, total: 1_200)).localizedLargeBackupHint)
    }

    // MARK: - Store and row model

    func testTheStoreKeepsTheStepInOneGlobalKey() {
        let store = BackupFirstBackupGuideStore(defaults: defaults)
        XCTAssertEqual(store.update(with: status(.scanning, total: 0)), .candidate)
        XCTAssertEqual(store.update(with: status(.uploading, total: 2_000)), .running)
        XCTAssertEqual(defaults.string(forKey: "photoBackup.firstBackupGuide.v1"), "running")
        XCTAssertEqual(BackupFirstBackupGuideStore(defaults: defaults).state, .running, "a restart keeps the step")
        store.update(with: status(.completed, total: 2_000, uploaded: 2_000))
        XCTAssertTrue(store.screenSeen())
        XCTAssertFalse(store.screenSeen(), "a second visit changes nothing")
        XCTAssertEqual(store.state, .done)
    }

    /// Sign-out removes the app's preferences once its purge is armed; no status may write the key back after that.
    func testNoStepIsWrittenWhileASignOutPurgeIsPending() {
        let store = BackupFirstBackupGuideStore(defaults: defaults)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)

        XCTAssertNil(store.update(with: status(.uploading, total: 2_000)))
        XCTAssertNil(defaults.string(forKey: BackupFirstBackupGuide.defaultsKey))
    }

    /// Leaving the backup settings while the purge is armed writes nothing either.
    func testLeavingTheSettingsWritesNothingWhileASignOutPurgeIsPending() {
        defaults.set(BackupFirstBackupGuide.State.completedUnseen.rawValue, forKey: BackupFirstBackupGuide.defaultsKey)
        let store = BackupFirstBackupGuideStore(defaults: defaults)
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)

        XCTAssertFalse(store.screenSeen())
        XCTAssertEqual(defaults.string(forKey: BackupFirstBackupGuide.defaultsKey), "completedUnseen")
    }
}
