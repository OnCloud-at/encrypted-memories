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
    public init(state: UploadBackupSyncQueueState, record: BackupIssueRecord?) {
        let issue = record?.kind ?? Self.defaultIssue(for: state)
        let detail = record?.detail
        let waitsForOriginal = BackupFailedItem.isWaitingForOriginal(detail)
        let waitsForPhotos = BackupFailedItem.isWaitingForPhotos(detail)
        let isSourceWait =
            issue == .unknown && (detail == BackupFailedItem.sourceNotReadyDetail || waitsForOriginal || waitsForPhotos)
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
