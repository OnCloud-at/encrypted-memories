import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@Suite struct PhotoLibraryContinuedBackupGoalTests {
    private static let scale = PhotoLibraryContinuedBackupGoal.scale

    private func status(
        phase: BackupStatus.Phase = .uploading, total: Int? = 100, remaining: Int, settled: Int,
        backedUp: Int = 0, failed: Int = 0, active: Double = 0
    ) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.totalConsidered = total
        status.remainingCount = remaining
        status.settled = settled
        status.uploaded = backedUp
        status.failed = failed
        status.activeExecutionItemEquivalents = active
        return status
    }

    private func catalog(_ completed: Int64, of total: Int64) -> PhotoLibraryCatalogProgress {
        PhotoLibraryCatalogProgress(executionCompletedUnitCount: completed, executionTotalUnitCount: total)
    }

    @Test func theGoalIsTheWorkLeftWhenTheFirstAssessmentEnds() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(phase: .scanning, total: nil, remaining: 0, settled: 0), catalog: nil)
        #expect(goal.total == nil)

        let first = goal.update(status: status(remaining: 40, settled: 60, backedUp: 60), catalog: nil)
        #expect(goal.total == 40)
        #expect(first.total == 40)
        #expect(first.backedUp == 0)

        // Photos that arrive later do not raise the goal; the normal windows or the next tap handle them.
        let later = goal.update(status: status(total: 150, remaining: 80, settled: 70, backedUp: 70), catalog: nil)
        #expect(goal.total == 40)
        #expect(later.total == 40)
        #expect(later.backedUp == 10)
    }

    @Test func theBackedUpCountNeverPassesTheGoal() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 5, settled: 0), catalog: nil)
        let progress = goal.update(status: status(total: 120, remaining: 9, settled: 20, backedUp: 20), catalog: nil)
        #expect(progress.backedUp == 5)
        #expect(progress.units.completedUnitCount == Self.scale)
    }

    @Test func aTapDuringTheAssessmentShowsTheScanAsTheFirstQuarter() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let scanning = goal.update(
            status: status(phase: .scanning, total: nil, remaining: 0, settled: 0), catalog: catalog(50, of: 100))
        #expect(scanning.units.totalUnitCount == Self.scale)
        #expect(scanning.units.completedUnitCount == Self.scale / 8)
        #expect(scanning.total == nil)

        // The assessment ended: its quarter is complete, and the goal's work fills the rest.
        let assessed = goal.update(status: status(remaining: 10, settled: 0), catalog: nil)
        #expect(assessed.units.completedUnitCount == Self.scale / 4)
        let half = goal.update(status: status(remaining: 5, settled: 5, backedUp: 5), catalog: nil)
        #expect(half.units.completedUnitCount == Self.scale / 4 + Self.scale * 3 / 8)
    }

    @Test func aTapAfterTheAssessmentShowsOnlyTheGoalsWork() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 10, settled: 90, backedUp: 90), catalog: catalog(1, of: 1))
        let progress = goal.update(
            status: status(remaining: 8, settled: 91, backedUp: 91, active: 1.5), catalog: catalog(1, of: 1))
        #expect(progress.units.completedUnitCount == Self.scale * 25 / 100)
        #expect(progress.backedUp == 1)
    }

    @Test func theReportedProgressNeverGoesBack() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let scanned = goal.update(
            status: status(phase: .scanning, total: nil, remaining: 0, settled: 0), catalog: catalog(80, of: 100))
        // A new scan starts its catalog progress again.
        let rescanned = goal.update(
            status: status(phase: .scanning, total: nil, remaining: 0, settled: 0), catalog: catalog(10, of: 100))
        #expect(rescanned.units.completedUnitCount == scanned.units.completedUnitCount)

        _ = goal.update(status: status(remaining: 10, settled: 0), catalog: nil)
        let moved = goal.update(status: status(remaining: 6, settled: 4, backedUp: 4), catalog: nil)
        // A retry makes failed rows due again, so the settled count can drop.
        let requeued = goal.update(status: status(remaining: 8, settled: 2, backedUp: 2), catalog: nil)
        #expect(requeued.units.completedUnitCount == moved.units.completedUnitCount)
    }

    @Test func anEmptyGoalIsReachedAtOnce() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let progress = goal.update(status: status(phase: .completed, remaining: 0, settled: 100), catalog: nil)
        #expect(goal.total == 0)
        #expect(progress.units.completedUnitCount == Self.scale)
        #expect(goal.isReached(by: status(phase: .completed, remaining: 0, settled: 100)))
    }

    // MARK: - Result from the settled state

    @Test func aGoalThatSettledReportsSuccessAlsoWhenTheExpiryCameFirst() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, settled: 0), catalog: nil)
        let settled = status(phase: .completed, remaining: 0, settled: 3, backedUp: 3)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: true, backupRuns: true)
        #expect(end == .completed)
        #expect(end.reportsSuccess)
        #expect(end.windowOutcome == .ran)
    }

    @Test func theGoalCountsAsReachedWhenItsCountSettledWhileNewPhotosWait() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, settled: 0), catalog: nil)
        let settled = status(total: 105, remaining: 2, settled: 3, backedUp: 3)
        #expect(goal.isReached(by: settled))
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: false, backupRuns: true)
                == .completed)
    }

    @Test func anExpiryWithWorkLeftReportsAStop() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, settled: 0), catalog: nil)
        let settled = status(phase: .waiting, remaining: 2, settled: 1, backedUp: 1)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: true, backupRuns: true)
        #expect(end == .stopped)
        #expect(!end.reportsSuccess)
        #expect(end.windowOutcome == .expired)
    }

    @Test func anExpiryBeforeTheAssessmentEndedReportsAStop() {
        let goal = PhotoLibraryContinuedBackupGoal()
        let settled = status(phase: .scanning, total: nil, remaining: 0, settled: 0)
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: true, backupRuns: true)
                == .stopped)
    }

    @Test func newProblemsInTheGoalReportNoSuccess() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, settled: 0, failed: 1), catalog: nil)
        let settled = status(phase: .needsAttention, remaining: 0, settled: 3, backedUp: 2, failed: 2)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: false, backupRuns: true)
        #expect(end == .needsAttention)
        #expect(!end.reportsSuccess)
        #expect(end.windowOutcome == .ran)

        // A problem that existed before the goal does not count against it.
        let clean = status(phase: .needsAttention, remaining: 0, settled: 3, backedUp: 3, failed: 1)
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: clean, didExpire: false, backupRuns: true)
                == .completed)
    }

    @Test func workThatWaitsOrABackupThatStoppedReportsNoSuccess() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, settled: 0), catalog: nil)
        let waiting = status(phase: .waitingForWiFi, remaining: 3, settled: 0)
        let ran = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: waiting, didExpire: false, backupRuns: true)
        #expect(ran == .waiting)
        #expect(!ran.reportsSuccess)
        #expect(ran.windowOutcome == .failed)

        let off = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: waiting, didExpire: false, backupRuns: false)
        #expect(off == .turnedOff)
        #expect(!off.reportsSuccess)
        #expect(off.windowOutcome == .notNeeded)
    }
}
