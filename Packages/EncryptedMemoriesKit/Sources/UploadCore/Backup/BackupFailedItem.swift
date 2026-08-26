import Foundation
import PhotosCore

/// One item the backup could not save, projected for a user-facing list. `reason` is always a clear,
/// already-localized sentence (never a raw error code); `isPermanent` marks the ones where retrying
/// cannot help (the local file is gone) so the UI can say so honestly and not offer a pointless retry.
public struct BackupFailedItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let reason: String
    public let isPermanent: Bool
    public let issue: BackupIssueKind
    public let nextAttemptAt: Date?
    public let isRetryable: Bool
    public let source: UploadSourceIdentity?
    public let revision: UploadBackupRevision?

    /// Shared localized retry copy used by both native settings shells.
    public var retryDescription: String? {
        BackupRetryPresentation.localizedDescription(for: nextAttemptAt)
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
        revision: UploadBackupRevision? = nil
    ) {
        self.id = id
        self.filename = filename
        self.reason = reason
        self.isPermanent = isPermanent
        self.issue = issue
        self.nextAttemptAt = nextAttemptAt
        self.isRetryable = isRetryable ?? (!isPermanent && issue.isRetryable)
        self.source = source
        self.revision = revision
    }
}
