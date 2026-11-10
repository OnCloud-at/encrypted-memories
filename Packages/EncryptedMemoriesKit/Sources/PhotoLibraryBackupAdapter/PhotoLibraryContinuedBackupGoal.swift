import Foundation
import PhotosCore
import UploadCore

/// The finite goal of one continued backup task (#1108): the photos that its first assessment left to do. Photos that
/// arrive later are not part of it; the normal background windows or the next tap handle them.
///
/// The progress for the system card uses a fixed scale. A task that starts before the assessment ended shows the scan as
/// the first quarter (`PhotoLibraryBackupExecutionProgress`). The reported progress never goes back: a new scan or a
/// retry that makes failed rows due again can lower the underlying counts.
public struct PhotoLibraryContinuedBackupGoal: Sendable, Equatable {
    public struct Progress: Sendable, Equatable {
        /// Units on the fixed scale `PhotoLibraryContinuedBackupGoal.scale`.
        public let units: BackupExecutionProgress
        /// Photos of the goal that are backed up; nil until the first assessment ended.
        public let backedUp: Int?
        /// The photos of the goal; nil until the first assessment ended.
        public let total: Int?
    }

    public static let scale: Int64 = 1_000_000
    private static let unitsPerItem = 1_000.0

    /// The photos that the first assessment left to do; nil until it ended.
    public private(set) var total: Int?
    /// The task started before the assessment ended, so its progress includes the scan.
    private var includesAssessment: Bool?
    private var settledAtGoal = 0
    private var itemEquivalentsAtGoal = 0.0
    private var backedUpAtGoal = 0
    private var attentionAtGoal = 0
    private var reportedUnits: Int64 = 0

    public init() {}

    /// Takes the newest status. The first status after the assessment fixes the goal.
    public mutating func update(status: BackupStatus, catalog: PhotoLibraryCatalogProgress?) -> Progress {
        if total == nil, status.totalConsidered != nil, status.phase != .scanning {
            total = status.remainingCount
            settledAtGoal = status.settled
            itemEquivalentsAtGoal = Self.itemEquivalents(status)
            backedUpAtGoal = status.backedUp
            attentionAtGoal = status.needsAttentionCount
        }
        if includesAssessment == nil { includesAssessment = total == nil }
        let complete = BackupExecutionProgress(completedUnitCount: 1, totalUnitCount: 1)
        let assessment = includesAssessment == true ? (total == nil ? catalog?.executionProgress : complete) : nil
        let work = total.map { goal -> BackupExecutionProgress in
            guard goal > 0 else { return complete }
            let done = max(0, Self.itemEquivalents(status) - itemEquivalentsAtGoal)
            return BackupExecutionProgress(
                completedUnitCount: Int64((done * Self.unitsPerItem).rounded(.down)),
                totalUnitCount: Int64(goal) * Int64(Self.unitsPerItem))
        }
        let combined = PhotoLibraryBackupExecutionProgress.combined(
            catalog: assessment, queue: work, isScanning: total == nil)
        reportedUnits = max(reportedUnits, combined?.completedUnitCount ?? 0)
        return Progress(
            units: BackupExecutionProgress(completedUnitCount: reportedUnits, totalUnitCount: Self.scale),
            backedUp: total.map { min($0, max(0, status.backedUp - backedUpAtGoal)) },
            total: total)
    }

    /// The goal's work settled: nothing remains, or as many rows settled as the goal holds while newer photos wait.
    public func isReached(by status: BackupStatus) -> Bool {
        guard let total else { return false }
        return status.remainingCount == 0 || status.settled - settledAtGoal >= total
    }

    /// Photos that need attention appeared after the goal was fixed.
    func hasNewProblems(in status: BackupStatus) -> Bool {
        status.needsAttentionCount > attentionAtGoal
    }

    private static func itemEquivalents(_ status: BackupStatus) -> Double {
        Double(status.settled) + status.activeExecutionItemEquivalents
    }
}

/// How a continued backup task ended. The settled durable state decides first and the expiry second, so a task whose
/// goal settled reports success also when its expiry came first (#1108; the removed first attempt reported a failure for
/// a completed backup).
public enum PhotoLibraryContinuedBackupEnd: String, Sendable, BackgroundLogName {
    /// The goal settled without new problems.
    case completed
    /// The goal settled, and photos of it need attention.
    case needsAttention
    /// The person stopped the task on the system card, or iOS expired it, before the goal settled.
    case stopped
    /// The work waits: for Wi-Fi, a retry date, or a pass without progress.
    case waiting
    /// The backup is paused, turned off, or has no photo access.
    case turnedOff

    /// iOS hears success only for a settled goal without new problems.
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
        if goal.isReached(by: settled) { return goal.hasNewProblems(in: settled) ? .needsAttention : .completed }
        if didExpire { return .stopped }
        return backupRuns ? .waiting : .turnedOff
    }
}
