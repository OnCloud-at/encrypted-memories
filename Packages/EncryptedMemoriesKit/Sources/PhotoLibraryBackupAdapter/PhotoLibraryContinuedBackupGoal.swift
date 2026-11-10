import Foundation
import PhotosCore
import UploadCore

/// The finite goal of one continued backup task (#1108): the photos that were left when the scan after the session start
/// ended. Photos that arrive later are not part of it; the normal background windows or the next prompt handle them.
///
/// - `total` (m) is fixed once, at the first status after the session start whose scan ended: the photos that remain
///   plus those that the session already backed up.
/// - `backedUp` (n) counts the photos backed up since the session start, never more than m. Settled rows of other
///   outcomes are not backed up and never count.
/// - The progress for the system card has a fixed scale: a short preparing share follows the catalog scan until m is
///   fixed, and the rest follows n and the share of the item in flight. It never goes back and does not depend on the
///   size of the library.
public struct PhotoLibraryContinuedBackupGoal: Sendable, Equatable {
    public struct Progress: Sendable, Equatable {
        /// Units on the fixed scale `PhotoLibraryContinuedBackupGoal.scale`.
        public let units: BackupExecutionProgress
        /// Photos of the goal that are backed up; nil until m is fixed.
        public let backedUp: Int?
        /// The photos of the goal (m); nil until it is fixed.
        public let total: Int?
    }

    public static let scale: Int64 = 1_000_000
    /// The share of the range that the scan before the goal shows.
    static let preparingShare = 0.05
    /// The share of one item that a transfer in flight can show, so the next whole item stays above it.
    private static let largestItemShare = 0.999

    /// The photos of the goal (m); nil until the scan after the session start ended.
    public private(set) var total: Int?
    /// The backed-up count when the session started.
    private var backedUpAtStart: Int?
    private var reportedUnits: Int64 = 0

    public init() {}

    /// Takes the newest status. The first status fixes the session start; the first status after it whose scan ended
    /// fixes m.
    public mutating func update(status: BackupStatus, catalog: PhotoLibraryCatalogProgress?) -> Progress {
        let backedUpAtStart = self.backedUpAtStart ?? status.backedUp
        self.backedUpAtStart = backedUpAtStart
        let backedUpSinceStart = max(0, status.backedUp - backedUpAtStart)
        if total == nil, status.totalConsidered != nil, status.phase != .scanning {
            total = status.remainingCount + backedUpSinceStart
        }
        let fraction: Double
        if let total {
            let done = min(total, backedUpSinceStart)
            let inFlight = done < total ? min(Self.largestItemShare, max(0, status.activeExecutionItemEquivalents)) : 0
            let work = total == 0 ? 1 : (Double(done) + inFlight) / Double(total)
            fraction = Self.preparingShare + (1 - Self.preparingShare) * work
        } else {
            let scan = catalog?.executionProgress.map {
                Double($0.completedUnitCount) / Double(max(1, $0.totalUnitCount))
            } ?? 0
            fraction = Self.preparingShare * min(1, max(0, scan))
        }
        reportedUnits = max(reportedUnits, Int64((fraction * Double(Self.scale)).rounded(.down)))
        return Progress(
            units: BackupExecutionProgress(completedUnitCount: reportedUnits, totalUnitCount: Self.scale),
            backedUp: total.map { min($0, backedUpSinceStart) },
            total: total)
    }

    /// The backup owes no more work, also none for photos that arrived after the session start or rows that wait for a
    /// retry or a Photos re-check.
    public func isReached(by status: BackupStatus) -> Bool {
        total != nil && !status.hasOutstandingWork
    }
}

/// How a continued backup task ended. The settled durable state decides first and the expiry second, so a task whose
/// goal settled reports success also when its expiry came first (#1108; the removed first attempt reported a failure for
/// a completed backup).
public enum PhotoLibraryContinuedBackupEnd: String, Sendable, BackgroundLogName {
    /// The goal settled, and no photo needs attention.
    case completed
    /// The goal settled, and photos need attention; the app shows them too.
    case needsAttention
    /// The person stopped the task on the system card, or iOS expired it, before the goal settled.
    case stopped
    /// The work waits: for Wi-Fi, a retry date, or a pass without progress.
    case waiting
    /// The backup is paused, turned off, or has no photo access.
    case turnedOff

    /// iOS hears success only for a settled goal without photos that need attention.
    public var reportsSuccess: Bool { self == .completed }

    /// The record of the window ledger.
    public var windowOutcome: BackgroundWindowOutcome {
        switch self {
        case .completed, .needsAttention: .ran
        case .stopped: .expired
        case .waiting: .failed
        case .turnedOff: .notNeeded
        }
    }

    /// The end after the last carried pass settled. `backupRuns` is false while the backup is paused, turned off, or has
    /// no photo access.
    public static func after(
        goal: PhotoLibraryContinuedBackupGoal, settled: BackupStatus, didExpire: Bool, backupRuns: Bool
    ) -> Self {
        if goal.isReached(by: settled) { return settled.needsAttentionCount > 0 ? .needsAttention : .completed }
        if didExpire { return .stopped }
        return backupRuns ? .waiting : .turnedOff
    }
}

/// The texts of the system card of a continued backup task. They are the app's own texts, so the card never says
/// something else than the backup screen.
public enum PhotoLibraryContinuedBackupCard {
    public static var title: String { L10n.string("backup.summary_backing_up") }

    /// "Preparing…" until the goal is fixed, then the photos left, the same number as the app's status line.
    public static func subtitle(for status: BackupStatus, goal: PhotoLibraryContinuedBackupGoal) -> String {
        guard goal.total != nil else { return L10n.string("upload.state_preparing") }
        return L10n.string("backup.detail_left \(status.remainingCount)")
    }

    /// The title at the end: the app's own headline for the settled status. After a stop, or with the backup off, the
    /// app would show a resting state, so the card says that the backup is incomplete.
    public static func finalTitle(after end: PhotoLibraryContinuedBackupEnd, settled: BackupStatus) -> String {
        switch end {
        case .stopped, .turnedOff: L10n.string("backup.phase_waiting")
        case .completed, .needsAttention, .waiting: BackupStatusPresentation(settled).localizedHeadline
        }
    }
}
