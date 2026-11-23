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
    /// The list section. A queue row takes it from its outcome; a row without a queue row takes its category's.
    public let section: BackupIssueSection
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
        technicalDetail: String? = nil,
        section: BackupIssueSection? = nil
    ) {
        let outcome = BackupItemOutcome(issue: issue)
        self.category = category ?? outcome.category
        self.section = section ?? self.category.section
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
            category: outcome.category, technicalDetail: record?.detail ?? entry.lastError, section: outcome.section)
    }

    /// A manual retry makes a row due before the date that its reason names; the row's own date then wins.
    public static func effectiveNextAttempt(_ record: BackupIssueRecord?, entry: UploadBackupSyncQueueEntry) -> Date? {
        guard let next = record?.nextAttemptAt else { return nil }
        guard entry.state == .discovered || entry.state == .queuedForUpload || entry.state == .blockedByDraft
        else { return next }
        return min(next, entry.updatedAt)
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
    /// The list offers Try again while it shows a photo that a retry can help.
    public var offersUserRetry: Bool { contains { $0.category == .userResolvable } }
}
