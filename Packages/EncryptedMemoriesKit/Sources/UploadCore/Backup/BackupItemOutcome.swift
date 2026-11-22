import Foundation
import PhotosCore

/// What a person sees for one stored queue row: its section, its reason, and whether a retry can help. For a reason
/// without a row it supplies the category and retry fallback; Album Sync applies its own context rule on top
/// (`AlbumSyncProblemList.albumItem`). The category also selects the rows that Try again reopens; it never changes
/// automatic retry policy.
public struct BackupItemOutcome: Sendable, Equatable {
    public let issue: BackupIssueKind
    public let category: BackupIssueCategory
    /// A localized sentence that names the cause, never a raw error code.
    public let reason: String
    /// Retrying cannot help: the item is in a final state or its cause never changes.
    public let isPermanent: Bool
    public let isRetryable: Bool
    /// The list section of the row. A decision asks the person; a final row gets no further attempt; a cause that the
    /// person can fix asks the person; every other row runs again in a later pass or after the next launch.
    public let section: BackupIssueSection
    /// The row counts toward the orange attention line of the status: a parked row that waits for the person's
    /// decision or for a cause only the person can fix. Every other row that is not backed up stays calm.
    public let raisesAttention: Bool

    /// Causes that only the person can fix: access to the photos and the Proton account storage. A failure of the app's
    /// own state is not one of them; a restart does not reliably fix it, so its row stays calm.
    private static let personFixableIssues: Set<BackupIssueKind> = [.permission, .accountStorage]

    /// A reason without a queue row.
    public init(issue: BackupIssueKind) {
        let category = Self.category(of: issue)
        self.init(
            issue: issue, category: category, reason: Self.reason(of: issue), isPermanent: false,
            section: category.section, raisesAttention: false)
    }

    /// A stored queue row.
    public init(state: UploadBackupSyncQueueState, record: BackupIssueRecord?, now: Date = Date()) {
        let issue = record?.kind ?? Self.defaultIssue(for: state)
        let detail = record?.detail
        let waitsForOriginal = Self.isWaitingForOriginal(detail)
        let waitsForPhotos = Self.isWaitingForPhotos(detail)
        let isSourceWait =
            issue == .unknown && (detail == Self.sourceNotReadyDetail || waitsForOriginal || waitsForPhotos)
        // A failed row is no longer planned by the app: whatever its cause, only the person's retry runs it again.
        let isManualRetry = state == .failed && (Self.category(of: issue) == .automatic || issue == .unknown)
        let isPermanentState = state == .sourceMissing || state == .failedPermanent
        let category: BackupIssueCategory
        if isPermanentState {
            category = issue == .deletedElsewhere ? .decision : .permanent
        } else if isSourceWait || (issue == .unknown && state != .failed) {
            category = .automatic
        } else if isManualRetry {
            category = .userResolvable
        } else {
            category = Self.category(of: issue)
        }
        let reason: String
        if category == .permanent && Self.category(of: issue) != .permanent {
            // Only a photo that stopped after proven refusals names Proton as the cause.
            reason =
                state == .failedPermanent && record?.serviceRejection?.stopsRetrying == true
                ? L10n.string("backup.issue_service_rejected") : L10n.string("backup.issue_after_several_tries")
        } else if state == .failed && category == .userResolvable && (issue == .remoteService || issue == .unknown) {
            // The stored kind of a parked row also covers local and sign-in errors; it proves no Proton cause.
            reason = L10n.string("backup.issue_after_several_tries")
        } else if Self.isLongWait(state: state, record: record, now: now) {
            // The retries continue; after a week the specific reason no longer helps the person.
            reason = L10n.string("backup.issue_unknown_waiting")
        } else if isSourceWait {
            reason =
                waitsForOriginal
                ? L10n.string("backup.issue_waiting_original")
                : waitsForPhotos
                    ? L10n.string("backup.issue_source_unavailable") : L10n.string("backup.issue_source_not_ready")
        } else if issue == .unknown && category == .automatic {
            reason = L10n.string("backup.issue_unknown_waiting")
        } else if record?.isUnprovenServiceWait == true {
            reason = L10n.string("backup.issue_unknown_waiting")
        } else {
            reason = Self.reason(of: issue)
        }
        let isFinal = isPermanentState || category == .permanent
        let section: BackupIssueSection =
            if category == .decision {
                .actionNeeded
            } else if isFinal {
                .notPossible
            } else if Self.personFixableIssues.contains(issue) {
                .actionNeeded
            } else {
                .continuesByItself
            }
        self.init(
            issue: issue, category: category, reason: reason, isPermanent: isPermanentState, section: section,
            raisesAttention: Self.raisesAttention(state: state, record: record))
    }

    // MARK: - Long waits

    /// After this long, a wait that does not end by itself shows "Not finished yet." and counts in the calm line.
    static let longWaitThreshold: TimeInterval = 7 * 24 * 3600

    /// The waits that a week bounds: Photos cannot hand out the file, an edit waits for its original, or Proton is
    /// temporarily unavailable. A lost connection has its own waiting line and does not count.
    static func tracksWaitStart(_ record: BackupIssueRecord) -> Bool {
        record.detail == sourceUnavailableDetail || isWaitingForOriginal(record.detail)
            || (record.kind == .remoteService && !record.isUnprovenServiceWait)
    }

    /// The start of a wait: the stored start while the same wait continues, otherwise now.
    static func waitStart(continuing earlier: BackupIssueRecord?, sameWait: Bool, now: Date) -> Date {
        sameWait ? earlier?.waitingSince ?? now : now
    }

    /// Whether a row that waits for its next retry has waited at least `longWaitThreshold` in one bounded wait. Only
    /// `discovered` rows count, because the problem list reads the same rows: a row being checked is not listed, and a
    /// parked or finished row has its own line.
    public static func isLongWait(state: UploadBackupSyncQueueState, record: BackupIssueRecord?, now: Date) -> Bool {
        guard state == .discovered, let record, tracksWaitStart(record),
            let since = record.waitingSince
        else { return false }
        return now.timeIntervalSince(since) >= longWaitThreshold
    }

    // MARK: - Stored wait details

    // The runner stores these details in a row's record, and the outcome reads them back: they are a stored format.

    /// The detail of a row whose file Photos cannot hand out yet (iCloud, an offline library volume, an interrupted
    /// read), and of a row whose file Photos reports as missing. The runner counts the waits of each separately.
    static let sourceUnavailableDetail = "backup.issue_source_unavailable"
    static let sourceReportedMissingDetail = "backup.issue_source_unavailable.reported_missing"
    /// The detail of a row whose photo the camera still processes.
    static let sourceNotReadyDetail = "error.upload_source_not_ready"

    static func isWaitingForPhotos(_ detail: String?) -> Bool {
        detail == sourceUnavailableDetail || detail == sourceReportedMissingDetail
    }

    static func isWaitingForOriginal(_ detail: String?) -> Bool {
        // The runner persists the key. Earlier builds persisted these sentences; their waits keep their count.
        [
            "backup.issue_waiting_original",
            "The edited photo is waiting for its original resources. Backup will retry automatically.",
            "Das bearbeitete Foto wartet auf seine Originalressourcen. "
                + "Das Backup versucht es automatisch erneut.",
        ].contains(detail ?? "")
    }

    /// Whether a stored row raises attention. It builds no localized text, so the queue summary can ask it for every
    /// parked row. A final or missing row asks the person only for its deletion decision; a failed row for a decision
    /// or for a cause that only the person can fix; a row that still runs never asks.
    public static func raisesAttention(state: UploadBackupSyncQueueState, record: BackupIssueRecord?) -> Bool {
        let issue = record?.kind ?? defaultIssue(for: state)
        return switch state {
        case .failedPermanent, .sourceMissing: issue == .deletedElsewhere
        case .failed: category(of: issue) == .decision || personFixableIssues.contains(issue)
        default: false
        }
    }

    private init(
        issue: BackupIssueKind, category: BackupIssueCategory, reason: String, isPermanent: Bool,
        section: BackupIssueSection, raisesAttention: Bool
    ) {
        self.issue = issue
        self.category = category
        self.reason = reason
        self.isPermanent = isPermanent || category == .permanent
        self.isRetryable = !self.isPermanent && Self.isRetryable(issue)
        self.section = section
        self.raisesAttention = raisesAttention
    }

    private static func category(of issue: BackupIssueKind) -> BackupIssueCategory {
        switch issue {
        case .network, .deviceStorage, .remoteDraft, .remoteService: .automatic
        case .accountStorage, .permission, .localState, .unknown: .userResolvable
        case .remoteDeletion, .deletedElsewhere: .decision
        case .remoteDraftStale, .sourceMissing, .unsupported: .permanent
        }
    }

    private static func isRetryable(_ issue: BackupIssueKind) -> Bool {
        switch issue {
        case .remoteDraftStale, .sourceMissing, .permission, .unsupported, .remoteDeletion, .deletedElsewhere: false
        case .network, .deviceStorage, .remoteDraft, .remoteService, .localState, .accountStorage, .unknown: true
        }
    }

    private static func reason(of issue: BackupIssueKind) -> String {
        switch issue {
        case .network: L10n.string("backup.issue_network")
        case .deviceStorage: L10n.string("backup.issue_device_storage")
        case .remoteDraft: L10n.string("backup.issue_remote_draft")
        case .remoteDraftStale: L10n.string("backup.issue_remote_draft_stale")
        case .sourceMissing: L10n.string("backup.issue_source_missing")
        case .permission: L10n.string("backup.issue_permission")
        case .unsupported: L10n.string("backup.issue_unsupported")
        case .remoteService: L10n.string("backup.issue_remote_service")
        case .localState: UploadError.InternalFailure.localStateMessage
        case .remoteDeletion: L10n.string("backup.state_skipped_remote_deletion")
        case .deletedElsewhere: L10n.string("backup.issue_deleted_elsewhere")
        case .accountStorage: L10n.string("backup.issue_account_storage")
        case .unknown: L10n.string("backup.fail_reason_generic")
        }
    }

    private static func defaultIssue(for state: UploadBackupSyncQueueState) -> BackupIssueKind {
        switch state {
        case .sourceMissing: .sourceMissing
        case .blockedByDraft: .remoteDraft
        case .failedPermanent: .remoteDraftStale
        case .skippedRemoteDeletion: .remoteDeletion
        default: .unknown
        }
    }
}
