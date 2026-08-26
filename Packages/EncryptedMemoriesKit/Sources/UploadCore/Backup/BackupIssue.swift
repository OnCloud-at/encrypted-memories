import Foundation

/// Stable, platform-neutral reason why a backup item is not complete. The queue persists this code
/// alongside the human-readable backend detail so scheduling and UI never have to parse localized
/// text to decide whether work is retryable or needs the user.
public enum BackupIssueKind: String, Codable, Sendable, Equatable {
    case network
    case deviceStorage
    case remoteDraft
    case remoteDraftStale
    case sourceMissing
    case permission
    case unsupported
    case remoteService
    case localState
    case remoteDeletion
    case unknown

    public var isRetryable: Bool {
        switch self {
        case .remoteDraftStale, .sourceMissing, .permission, .unsupported, .remoteDeletion:
            false
        default:
            true
        }
    }

    public var requiresUserAction: Bool {
        switch self {
        case .deviceStorage, .remoteDraftStale, .sourceMissing, .permission, .unsupported, .localState:
            true
        default:
            false
        }
    }
}

/// Versioned payload stored in the queue's `last_error` column. `nextAttemptAt` is explicit so
/// presentation code never has to infer retry eligibility from an audit timestamp.
public struct BackupIssueRecord: Codable, Sendable, Equatable {
    public static let storagePrefix = "encryptedmemories-backup-issue-v1:"

    public var kind: BackupIssueKind
    public var detail: String
    public var nextAttemptAt: Date?
    /// Persisted ordinal for environmental retries. It is deliberately separate from the queue row's
    /// finite item-failure attempts, so a long outage gets capped backoff without stranding valid media.
    public var automaticRetryAttempt: Int

    public init(
        kind: BackupIssueKind,
        detail: String,
        nextAttemptAt: Date? = nil,
        automaticRetryAttempt: Int = 0
    ) {
        self.kind = kind
        self.detail = detail
        self.nextAttemptAt = nextAttemptAt
        self.automaticRetryAttempt = max(0, automaticRetryAttempt)
    }

    public var persistedValue: String {
        let payload = (try? JSONEncoder().encode(self))?.base64EncodedString() ?? ""
        return Self.storagePrefix + payload
    }

    public static func decode(_ value: String?) -> BackupIssueRecord? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix(storagePrefix) else { return nil }
        let payload = String(value.dropFirst(storagePrefix.count))
        guard let data = Data(base64Encoded: payload),
            let record = try? JSONDecoder().decode(BackupIssueRecord.self, from: data)
        else {
            return BackupIssueRecord(kind: .unknown, detail: value)
        }
        return record
    }
}

/// Durable rest-state projection shared by every platform. It is deliberately small: aggregate
/// counts remain an indexed SQL summary, while only the earliest retry and dominant reason are
/// needed to schedule the next pass and tell the truth in UI.
public struct BackupOutstandingSnapshot: Sendable, Equatable {
    public var count: Int
    public var issue: BackupIssueKind?
    public var nextAttemptAt: Date?

    public init(count: Int = 0, issue: BackupIssueKind? = nil, nextAttemptAt: Date? = nil) {
        self.count = max(0, count)
        self.issue = issue
        self.nextAttemptAt = nextAttemptAt
    }
}

/// Pure retry-date policy used by the shared controller. A future queue eligibility wins; a stale
/// or missing date receives an exponentially increasing no-progress fallback with a 30-second floor.
/// This prevents both permanent stalls and millisecond/45-second empty-run loops.
public enum BackupAutomaticRetryPlanner {
    public static func nextAttempt(
        outstandingCount: Int,
        queueDate: Date?,
        consecutiveNoProgressRuns: Int,
        now: Date,
        retryPolicy: BackupRetryPolicy
    ) -> Date? {
        guard outstandingCount > 0 else { return nil }
        let fallbackDelay = max(
            30,
            retryPolicy.delay(afterAttempts: max(1, consecutiveNoProgressRuns))
        )
        let fallbackDate = now.addingTimeInterval(fallbackDelay)
        guard let queueDate, queueDate > now else { return fallbackDate }
        // The queue owns retry eligibility. Never postpone a precise future date behind a generic
        // no-progress fallback merely because the user reopened the app or tapped retry early.
        return queueDate
    }
}
