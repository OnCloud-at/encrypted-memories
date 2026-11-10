import Foundation
import PhotosCore

/// One item the backup could not save, projected for a user-facing list. `reason` is always a clear,
/// already-localized sentence (never a raw error code); `isPermanent` marks the ones where retrying
/// cannot help (the local file is gone) so the UI can say so honestly and not offer a pointless retry.
public struct BackupFailedItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let reason: String
    public let category: BackupIssueCategory
    /// Raw detail is for support reports, never for the list.
    public let technicalDetail: String?
    public let isPermanent: Bool
    public let issue: BackupIssueKind
    public let nextAttemptAt: Date?
    public let isRetryable: Bool
    public let source: UploadSourceIdentity?
    public let revision: UploadBackupRevision?

    /// Shared localized retry copy used by both native settings shells.
    public var retryDescription: String? {
        guard category == .automatic else { return nil }
        return BackupRetryPresentation.localizedDescription(for: nextAttemptAt)
    }

    public init(
        id: String,
        filename: String,
        reason: String,
        isPermanent: Bool,
        issue: BackupIssueKind = .unknown,
        nextAttemptAt: Date? = nil,
        isRetryable: Bool? = nil,
        source: UploadSourceIdentity? = nil,
        revision: UploadBackupRevision? = nil,
        category: BackupIssueCategory? = nil,
        technicalDetail: String? = nil
    ) {
        let outcome = BackupItemOutcome(issue: issue)
        self.category = category ?? outcome.category
        self.technicalDetail = technicalDetail
        self.id = id
        self.filename = filename
        self.reason = reason
        self.isPermanent = isPermanent || self.category == .permanent
        self.issue = issue
        self.nextAttemptAt = nextAttemptAt
        self.isRetryable = isRetryable ?? (!self.isPermanent && outcome.isRetryable)
        self.source = source
        self.revision = revision
    }

    public init(entry: UploadBackupSyncQueueEntry) {
        let record = BackupIssueRecord.decode(entry.lastError)
        let outcome = BackupItemOutcome(state: entry.state, record: record)
        self.init(
            id: "\(entry.source.kind.rawValue)/\(entry.source.identifier)/\(entry.source.resource.rawValue)"
                + "#\(entry.revision.rawValue)",
            filename: entry.originalFilename, reason: outcome.reason, isPermanent: outcome.isPermanent,
            issue: outcome.issue, nextAttemptAt: Self.effectiveNextAttempt(record, entry: entry),
            isRetryable: outcome.isRetryable, source: entry.source, revision: entry.revision,
            category: outcome.category, technicalDetail: record?.detail ?? entry.lastError)
    }

    /// A manual retry makes a row due before the date that its reason names; the row's own date then wins.
    public static func effectiveNextAttempt(_ record: BackupIssueRecord?, entry: UploadBackupSyncQueueEntry) -> Date? {
        guard let next = record?.nextAttemptAt else { return nil }
        guard entry.state == .discovered || entry.state == .queuedForUpload || entry.state == .blockedByDraft
        else { return next }
        return min(next, entry.updatedAt)
    }

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
}

extension BackupIssueSection {
    public var localizedTitle: String {
        switch self {
        case .actionNeeded: L10n.string("backup.section_action_needed")
        case .continuesByItself: L10n.string("backup.section_continues_by_itself")
        case .notPossible: L10n.string("backup.section_not_possible")
        }
    }
}

extension Collection where Element == BackupFailedItem {
    /// The list offers Try again only while it shows a photo whose problem the person can fix.
    public var offersUserRetry: Bool { contains { $0.category == .userResolvable } }
}
