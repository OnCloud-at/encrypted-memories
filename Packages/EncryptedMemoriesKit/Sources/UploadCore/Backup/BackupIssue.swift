import Foundation

/// Presentation categories. The category also selects the rows that Try again reopens; it never changes automatic
/// retry policy.
public enum BackupIssueCategory: String, Sendable, Equatable {
    case automatic
    case userResolvable
    case decision
    case permanent

    public var section: BackupIssueSection {
        switch self {
        case .automatic: .continuesByItself
        case .userResolvable, .decision: .actionNeeded
        case .permanent: .notPossible
        }
    }

    public var symbolName: String {
        switch self {
        case .automatic: "clock.arrow.circlepath"
        case .userResolvable: "exclamationmark.circle"
        case .decision: "questionmark.circle"
        case .permanent: "trash.slash"
        }
    }
}

/// Both native hosts use this order and the same membership rules.
public enum BackupIssueSection: String, CaseIterable, Sendable, Identifiable {
    case actionNeeded
    case continuesByItself
    case notPossible

    public var id: String { rawValue }
}

/// Stable, platform-neutral reason why a backup item is not complete. The queue persists this code
/// alongside the human-readable backend detail so scheduling and UI never have to parse localized
/// text to decide whether work is retryable or needs the user, except the two legacy waiting-original sentences of
/// older builds.
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
    case deletedElsewhere
    /// The Proton account has too little storage left for the item.
    case accountStorage
    case unknown

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
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
    /// Proton's repeated refusal of this revision. Older builds ignore the field and keep the row as it is.
    public var serviceRejection: BackupServiceRejection?
    /// When a wait that does not end by itself began: Photos cannot hand out the file, an edit waits for its original,
    /// or Proton is temporarily unavailable. It stays while the same wait continues. Older builds ignore the field.
    public var waitingSince: Date?

    public init(
        kind: BackupIssueKind,
        detail: String,
        nextAttemptAt: Date? = nil,
        automaticRetryAttempt: Int = 0,
        serviceRejection: BackupServiceRejection? = nil,
        waitingSince: Date? = nil
    ) {
        self.kind = kind
        self.detail = detail
        self.nextAttemptAt = nextAttemptAt
        self.automaticRetryAttempt = max(0, automaticRetryAttempt)
        self.serviceRejection = serviceRejection
        self.waitingSince = waitingSince
    }

    /// The kind says remoteService, but nothing proves a temporary Proton wait: only that wait counts automatic
    /// retries. An item retry of a local or sign-in error is stored with the same kind and counts none.
    public var isUnprovenServiceWait: Bool { kind == .remoteService && automaticRetryAttempt == 0 }

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

/// Rounds of Proton refusing one revision. A round is one park after the full attempt budget. A park at least a day
/// after the previous round starts the next one; manual retries within a day add no round. The runner stops retrying
/// after three rounds that span at least three days.
public struct BackupServiceRejection: Codable, Sendable, Equatable {
    public var rounds: Int
    public var firstRoundAt: Date
    public var lastRoundAt: Date

    public init(rounds: Int, firstRoundAt: Date, lastRoundAt: Date) {
        self.rounds = rounds
        self.firstRoundAt = firstRoundAt
        self.lastRoundAt = lastRoundAt
    }

    /// The least time between two rounds, and the least time that the rounds must cover before the runner stops.
    static let roundSpacing: TimeInterval = 24 * 3600
    static let stopSpan: TimeInterval = 72 * 3600
    static let stopRounds = 3

    /// The rounds after one more park at `now`.
    public static func afterPark(_ previous: Self?, at now: Date) -> Self {
        guard var next = previous else { return Self(rounds: 1, firstRoundAt: now, lastRoundAt: now) }
        if now.timeIntervalSince(next.lastRoundAt) >= roundSpacing {
            next.rounds += 1
            next.lastRoundAt = now
        }
        return next
    }

    public var stopsRetrying: Bool {
        rounds >= Self.stopRounds && lastRoundAt.timeIntervalSince(firstRoundAt) >= Self.stopSpan
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
