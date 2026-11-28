import Foundation
import PhotosCore

public enum BackupRetryPresentation {
    public static func localizedDescription(for nextAttemptAt: Date?) -> String? {
        guard let nextAttemptAt else { return nil }
        let time = nextAttemptAt.formatted(date: .omitted, time: .shortened)
        return L10n.string("backup.detail_retry_at \(time)")
    }
}

/// Platform-neutral display projection of `BackupStatus` for the backup status row. Shared mapping
/// keeps iOS and macOS wording and row structure consistent. The row contains an icon, phase headline,
/// subtitle, progress, and an optional attention line; `BackupStatusStabilizer` handles rapid phase changes.
public struct BackupStatusPresentation: Sendable, Equatable {
    /// The single activity treatment for the row's one icon (there is never a second spinner).
    public enum Accessory: String, Sendable, Equatable {
        case idle
        case activity
        case success
        case attention
        case paused
        case waiting
        /// Mobile data is off for backups. Hosts show `BackupStatus.waitingForWiFiSymbolName`, never an offline symbol.
        case waitingForWiFi
        case notice
    }

    /// Stable phase-level geometry for compact platform rows. Per-file transfer changes never alter
    /// this value; only entering or leaving an active known-total pass changes the row height.
    public enum DetailLayout: String, Sendable, Equatable {
        case compact
        case progress
    }

    /// Stable phase key, used both for the headline text and by the stabilizer's dwell.
    public var headlineKey: String
    /// True while a run is active - drives the one spinning icon.
    public var isActive: Bool
    public var accessory: Accessory
    /// Known active or paused photo progress uses the durable-item watermark. Other known phases
    /// retain the raw phase mapping; unknown photo totals hide this fraction.
    public var progressFraction: Double?
    /// Nil for unmanaged consumers. A knowledge transition must bypass active-phase dwell.
    public var photoTotalIsKnown: Bool?

    // Subtitle inputs kept raw so the localized strings are compiler-checked, not built from a
    // dynamic key. `backedUp`/`total` render "<n> of <m>"; `attentionCount` drives the optional
    // attention line.
    public var backedUp: Int
    public var total: Int
    public var attentionCount: Int
    /// Rows that are not backed up although nothing the person can fix is known; never worded as attention.
    public var notBackedUpCount: Int
    /// Retryable work waiting on external state. It may open details, but is never worded as failure.
    public var waitingCount: Int
    /// Exact-content matches deliberately not restored after Proton reported them deleted.
    public var skippedRemoteDeletions: Int
    public var nextAttemptAt: Date?
    /// Rows still to work on (waiting, checking, uploading). See `BackupStatus.remainingCount`.
    public var remainingCount = 0
    /// Smoothed upload speed; only set while the phase checks or uploads.
    public var uploadSpeedBytesPerSecond: Double?
    public var degradedDedupeUnresolvedCount: Int
    public var executionOpportunityIssue: BackupExecutionOpportunityIssue?
    /// True while a large first backup runs: the host shows how to make it faster (#275).
    public var showsLargeBackupHint = false

    public var detailLayout: DetailLayout {
        guard total > 0 else { return .compact }
        switch headlineKey {
        case "backup.phase_checking", "backup.phase_checking_photos", "backup.phase_uploading", "backup.phase_paused":
            return .progress
        default:
            return .compact
        }
    }

    public init(
        headlineKey: String,
        isActive: Bool,
        accessory: Accessory,
        progressFraction: Double?,
        backedUp: Int = 0,
        total: Int = 0,
        attentionCount: Int = 0,
        notBackedUpCount: Int = 0,
        waitingCount: Int = 0,
        skippedRemoteDeletions: Int = 0,
        nextAttemptAt: Date? = nil,
        degradedDedupeUnresolvedCount: Int = 0,
        executionOpportunityIssue: BackupExecutionOpportunityIssue? = nil
    ) {
        self.headlineKey = headlineKey
        self.isActive = isActive
        self.accessory = accessory
        self.progressFraction = progressFraction
        self.backedUp = backedUp
        self.total = total
        self.attentionCount = attentionCount
        self.notBackedUpCount = max(0, notBackedUpCount)
        self.waitingCount = waitingCount
        self.skippedRemoteDeletions = skippedRemoteDeletions
        self.nextAttemptAt = nextAttemptAt
        self.degradedDedupeUnresolvedCount = max(0, degradedDedupeUnresolvedCount)
        self.executionOpportunityIssue = executionOpportunityIssue
    }

    // MARK: - Mapping from the shared status

    public init(_ status: BackupStatus) {
        let backupTarget = status.backupTargetCount ?? 0
        switch status.phase {
        case .scanning:
            self.init(
                headlineKey: "backup.phase_scanning", isActive: true, accessory: .activity,
                progressFraction: nil, backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .checking:
            self.init(
                headlineKey: status.titleKey,
                isActive: true, accessory: .activity,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .uploading:
            self.init(
                headlineKey: "backup.phase_uploading",
                isActive: true, accessory: .activity,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .paused:
            self.init(
                headlineKey: "backup.phase_paused", isActive: false, accessory: .paused,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .waitingForWiFi:
            self.init(
                headlineKey: "backup.phase_waiting_wifi", isActive: false, accessory: .waitingForWiFi,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                attentionCount: status.needsAttentionCount,
                skippedRemoteDeletions: status.skippedRemoteDeletions)

        case .waiting:
            let headlineKey: String
            if status.hasOnlyDismissedSourceRechecks {
                headlineKey = status.titleKey
            } else {
                headlineKey =
                    switch status.outstandingIssue {
                    case .network: "backup.phase_waiting_network"
                    case .remoteService: "backup.phase_waiting_proton"
                    case .deviceStorage: "backup.phase_waiting_storage"
                    case .accountStorage: "backup.phase_waiting_account_storage"
                    case .remoteDraft: "backup.phase_waiting_draft"
                    case .deletedElsewhere: "backup.phase_attention"
                    default: "backup.phase_waiting"
                    }
            }
            // A full Proton storage is the person's to fix, so its wait asks the person.
            self.init(
                headlineKey: headlineKey, isActive: false,
                accessory: headlineKey == "backup.phase_waiting_account_storage" ? .attention : .waiting,
                progressFraction: status.fractionCompleted,
                backedUp: status.backedUp, total: backupTarget,
                waitingCount: status.withoutLongWaits(max(0, status.outstandingCount - status.pendingSourceRechecks)),
                skippedRemoteDeletions: status.skippedRemoteDeletions,
                nextAttemptAt: status.nextAttemptAt)

        case .completed:
            self.init(
                headlineKey: status.hasOmissions
                    ? "backup.phase_completed_with_omissions"
                    : status.skippedRemoteDeletions > 0
                        ? "backup.phase_completed_with_remote_deletions"
                        : "backup.phase_completed",
                isActive: false,
                accessory: status.hasOmissions ? .notice : .success,
                progressFraction: nil,
                backedUp: status.backedUp,
                total: backupTarget,
                skippedRemoteDeletions: status.skippedRemoteDeletions
            )

        case .needsAttention:
            self.init(
                headlineKey: "backup.phase_attention", isActive: false, accessory: .attention,
                progressFraction: nil, backedUp: status.backedUp, total: backupTarget,
                // Only terminal item failures belong under "couldn't be backed up". A
                // queue-wide index/service interruption can leave a large discovered backlog;
                // those rows are still scheduled work, not failed photos.
                attentionCount: status.needsAttentionCount,
                skippedRemoteDeletions: status.skippedRemoteDeletions,
                nextAttemptAt: status.nextAttemptAt)

        case .idle:
            self.init(
                headlineKey: "backup.phase_idle", isActive: false, accessory: .idle,
                progressFraction: nil)
        }
        executionOpportunityIssue = status.executionOpportunityIssue
        remainingCount = status.remainingCount
        // A speed belongs to a sending phase only; a stale value never shows while paused or waiting.
        if status.phase == .checking || status.phase == .uploading {
            uploadSpeedBytesPerSecond = status.uploadSpeedBytesPerSecond
        }
        if status.remoteContentIndexHealth.shouldWarn {
            degradedDedupeUnresolvedCount = status.remoteContentIndexHealth.unresolvedCount
        }
        if let photo = status.photoDisplayProgress {
            photoTotalIsKnown = photo.isTotalKnown
            if photo.isTotalKnown {
                if isActive || accessory == .paused {
                    progressFraction = photo.fraction
                }
            } else {
                progressFraction = nil
                total = 0
                if photo.isChecking {
                    headlineKey = status.phase == .scanning ? "backup.phase_scanning" : "backup.phase_checking"
                    isActive = true
                    accessory = .activity
                }
            }
        }
        // A running pass changes the parked counts before the summary sorts them, so only a resting status shows them.
        // This follows the photo progress, which can make the status active.
        if !isActive && status.phase != .paused {
            notBackedUpCount = status.notBackedUpCount
        }
        // The large first backup guide (#275): its hint while it runs, its headline once after a plain completion.
        let guide = status.firstBackupGuide
        // A status that asks the person (for example a full Proton storage) shows no hint about speed.
        showsLargeBackupHint =
            guide == .running && status.phase != .completed && status.phase != .idle && accessory != .attention
        if guide == .completedUnseen, headlineKey == "backup.phase_completed" {
            headlineKey = "backup.phase_first_completed"
        }
    }

    // MARK: - Localized accessors (finite key sets; no dynamic-key lookups)

    public var localizedHeadline: String {
        switch headlineKey {
        case "backup.phase_scanning": return L10n.string("backup.phase_scanning")
        case "backup.phase_checking": return L10n.string("backup.phase_checking")
        case "backup.phase_checking_photos": return L10n.string("backup.phase_checking_photos")
        case "backup.phase_uploading": return L10n.string("backup.phase_uploading")
        case "backup.phase_paused": return L10n.string("backup.phase_paused")
        case "backup.phase_waiting_wifi": return L10n.string("backup.phase_waiting_wifi")
        case "backup.phase_waiting": return L10n.string("backup.phase_waiting")
        case "backup.phase_waiting_photos": return L10n.string("backup.phase_waiting_photos")
        case "backup.phase_waiting_proton": return L10n.string("backup.phase_waiting_proton")
        case "backup.phase_waiting_network": return L10n.string("backup.phase_waiting_network")
        case "backup.phase_waiting_storage": return L10n.string("backup.phase_waiting_storage")
        case "backup.phase_waiting_account_storage": return L10n.string("backup.phase_waiting_account_storage")
        case "backup.phase_waiting_draft": return L10n.string("backup.phase_waiting_draft")
        case "backup.phase_completed": return L10n.string("backup.phase_completed")
        case "backup.phase_first_completed": return L10n.string("backup.phase_first_completed")
        case "backup.phase_completed_with_remote_deletions":
            return L10n.string("backup.phase_completed_with_remote_deletions")
        case "backup.phase_completed_with_omissions":
            return L10n.string("backup.phase_completed_with_omissions")
        case "backup.phase_attention":
            return attentionCount > 0
                ? L10n.string("backup.phase_not_backed_up \(attentionCount)") : L10n.string("backup.phase_attention")
        default: return L10n.string("backup.phase_idle")
        }
    }

    /// "<n> of <m> backed up", or "All <n> files backed up." after a first backup. Nil when there is no honest total
    /// yet (scanning, idle, or a photo total that no scan has confirmed since launch): "All <n>" also claims a total.
    public var localizedSubtitle: String? {
        guard total > 0 else { return nil }
        if headlineKey == "backup.phase_first_completed" {
            return L10n.string("backup.detail_first_completed \(backedUp)")
        }
        return L10n.string("counts.backed_up \(L10n.ofTotal(backedUp, of: total))")
    }

    /// Shown only when something actually needs the user; nil otherwise.
    public var localizedAttention: String? {
        guard attentionCount > 0 else { return nil }
        return L10n.string("backup.progress_attention \(attentionCount)")
    }

    /// Why the backup waits, where the row has room for a second line.
    public var localizedWaitingForWiFiDetail: String? {
        accessory == .waitingForWiFi ? L10n.string("backup.detail_waiting_wifi") : nil
    }

    /// Calm and tappable: the rows that are not backed up without anything the person can fix. Nil when none.
    public var localizedNotBackedUp: String? {
        guard notBackedUpCount > 0 else { return nil }
        return L10n.string("backup.progress_not_backed_up \(notBackedUpCount)")
    }

    /// Names Proton only while the rows wait for a temporary Proton failure to end.
    public var localizedWaitingDetail: String? {
        guard waitingCount > 0 else { return nil }
        guard headlineKey == "backup.phase_waiting_proton" else {
            return L10n.string("backup.detail_waiting \(waitingCount)")
        }
        return L10n.string("backup.progress_waiting \(waitingCount)")
    }

    /// The one line under the backup status that the person can act on: the two permission cases share one text, and a
    /// failed task registration keeps its restart text. A failed index preparation and the scheduling problems that
    /// iOS and the app retry on their own show no line. The index failure names no cause of its own: a waiting status
    /// and a needs-attention status show its stored retry date, and only a waiting status takes the headline of its
    /// stored kind, when that kind has one. A scheduler issue sets neither; the app submits the work again on the next
    /// background entry, at the end of a task and in the next refresh window.
    public var localizedSystemIssue: String? {
        switch executionOpportunityIssue {
        case .backgroundRefreshUnavailable, .backgroundLaunchNotPermitted:
            return L10n.string("backup.background_unavailable_action")
        case .registrationFailed:
            return L10n.string("backup.error_background_registration")
        case .schedulerCapacity, .immediateRunIneligible, .unknown, nil:
            return nil
        }
    }

    public var localizedDedupeWarning: String? {
        guard degradedDedupeUnresolvedCount > 0 else { return nil }
        return L10n.string("backup.warning_dedupe_degraded \(degradedDedupeUnresolvedCount)")
    }

    /// Informational, never an attention state: Proton proved the exact files existed and were
    /// deleted there, so automatic backup intentionally did not recreate them.
    public var localizedRemoteDeletionDetail: String? {
        guard skippedRemoteDeletions > 0 else { return nil }
        return L10n.string("backup.detail_respected_remote_deletions \(skippedRemoteDeletions)")
    }

    public var localizedRetryDetail: String? {
        BackupRetryPresentation.localizedDescription(for: nextAttemptAt)
    }

    /// "3,766 left · 3.2 MB/s", or "3,766 left" without a speed. Only in the progress layout, so the row reserves
    /// its slot; nil when nothing is left.
    public var localizedLeftLine: String? {
        guard detailLayout == .progress, remainingCount > 0 else { return nil }
        guard let speedText else { return L10n.string("backup.detail_left \(remainingCount)") }
        return L10n.string("backup.detail_left_speed \(remainingCount) \(speedText)")
    }

    /// The same two values as one sentence for VoiceOver: "3,766 left, 3.2 MB per second".
    public var localizedLeftAccessibilityLabel: String? {
        guard detailLayout == .progress, remainingCount > 0 else { return nil }
        guard let speedText else { return L10n.string("backup.detail_left \(remainingCount)") }
        return L10n.string("backup.detail_left_speed_spoken \(remainingCount) \(speedText)")
    }

    /// A line under the headline that keeps its height while its text comes and goes, so a changing count or speed
    /// cannot move the bar below it.
    public struct ReservedLine: Equatable, Sendable {
        /// Stands in for a missing text, so an empty line is as tall as a filled one.
        public static let placeholder = "\u{00a0}"

        public let text: String?
        public var displayText: String { text ?? Self.placeholder }
        /// An empty line is invisible and hidden from VoiceOver.
        public var isEmpty: Bool { text == nil }
    }

    /// The count line of the progress layout: always present there, empty until the first count.
    public var reservedSubtitle: ReservedLine { ReservedLine(text: localizedSubtitle) }

    /// The items-left line of the progress layout: always present there, empty when nothing is left.
    public var reservedLeftLine: ReservedLine { ReservedLine(text: localizedLeftLine) }

    /// The fraction of the bar while a pass is active or paused. Nil hides the bar.
    public var progressBarFraction: Double? {
        guard let progressFraction, isActive || accessory == .paused else { return nil }
        return progressFraction
    }

    private var speedText: String? {
        guard let speed = uploadSpeedBytesPerSecond, speed >= 1 else { return nil }
        return L10n.fileSize(Int64(speed.rounded()))
    }
}
