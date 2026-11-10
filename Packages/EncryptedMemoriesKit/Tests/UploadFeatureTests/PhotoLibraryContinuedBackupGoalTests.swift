import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@Suite struct PhotoLibraryContinuedBackupGoalTests {
    private static let scale = PhotoLibraryContinuedBackupGoal.scale

    private func status(
        phase: BackupStatus.Phase = .uploading, total: Int? = 100, remaining: Int, backedUp: Int = 0,
        failed: Int = 0, active: Double = 0
    ) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.totalConsidered = total
        status.remainingCount = remaining
        status.uploaded = backedUp
        status.failed = failed
        status.activeExecutionItemEquivalents = active
        status.hasOutstandingWork = remaining > 0
        return status
    }

    private func scanning(backedUp: Int = 0) -> BackupStatus {
        status(phase: .scanning, total: nil, remaining: 0, backedUp: backedUp)
    }

    /// Equal up to one unit: the fraction is computed in floating point.
    private func near(_ value: Int64, _ expected: Int64) -> Bool { abs(value - expected) <= 1 }

    private func catalog(_ completed: Int64, of total: Int64) -> PhotoLibraryCatalogProgress {
        PhotoLibraryCatalogProgress(executionCompletedUnitCount: completed, executionTotalUnitCount: total)
    }

    // MARK: - n and m

    @Test func theGoalIsWhatRemainsWhenTheScanEndsPlusWhatTheSessionBackedUpBefore() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: scanning(backedUp: 60), catalog: nil)
        #expect(goal.total == nil)

        let fixed = goal.update(status: status(remaining: 40, backedUp: 65), catalog: nil)
        #expect(goal.total == 45)
        #expect(fixed.total == 45)
        #expect(fixed.backedUp == 5)

        // Photos that arrive later do not raise the goal.
        let later = goal.update(status: status(total: 150, remaining: 80, backedUp: 70), catalog: nil)
        #expect(later.total == 45)
        #expect(later.backedUp == 10)
    }

    @Test func settledRowsOfOtherOutcomesAreNotBackedUp() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 10), catalog: nil)
        var failedOnly = status(remaining: 8, failed: 2)
        failedOnly.settled = 2
        let progress = goal.update(status: failedOnly, catalog: nil)
        #expect(progress.backedUp == 0)
        #expect(progress.units.completedUnitCount == Self.scale * 5 / 100, "only the preparing share")
    }

    @Test func theBackedUpCountNeverPassesTheGoal() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 5), catalog: nil)
        let progress = goal.update(status: status(total: 120, remaining: 9, backedUp: 20), catalog: nil)
        #expect(progress.backedUp == 5)
        #expect(progress.units.completedUnitCount == Self.scale)
    }

    // MARK: - Progress units

    @Test func theScanBeforeTheGoalFillsOnlyThePreparingShare() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let scan = goal.update(status: scanning(), catalog: catalog(50, of: 100))
        #expect(scan.units.totalUnitCount == Self.scale)
        #expect(scan.units.completedUnitCount == Self.scale / 40)
        #expect(scan.total == nil)

        let fixed = goal.update(status: status(remaining: 10), catalog: nil)
        #expect(fixed.units.completedUnitCount == Self.scale / 20)
        let half = goal.update(status: status(remaining: 5, backedUp: 5), catalog: nil)
        #expect(near(half.units.completedUnitCount, Self.scale * 525 / 1000))
    }

    @Test func theProgressDoesNotDependOnTheSizeOfTheLibrary() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let start = goal.update(status: status(total: 10_000, remaining: 300, backedUp: 9_700), catalog: catalog(1, of: 1))
        #expect(start.units.completedUnitCount == Self.scale / 20, "300 of 10,000 left starts near the beginning")
        #expect(start.total == 300)
    }

    @Test func theItemInFlightMovesTheProgressButNeverReachesTheNextWholeItem() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 10), catalog: nil)
        let half = goal.update(status: status(remaining: 9, backedUp: 1, active: 0.5), catalog: nil)
        #expect(near(half.units.completedUnitCount, Self.scale * 1925 / 10_000))
        let many = goal.update(status: status(remaining: 9, backedUp: 1, active: 3), catalog: nil)
        #expect(many.units.completedUnitCount > half.units.completedUnitCount)
        #expect(many.units.completedUnitCount < Self.scale * 24 / 100, "below 2 of 10 items")
    }

    @Test func theReportedProgressNeverGoesBack() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let scanned = goal.update(status: scanning(), catalog: catalog(80, of: 100))
        // A new scan starts its catalog progress again.
        let rescanned = goal.update(status: scanning(), catalog: catalog(10, of: 100))
        #expect(rescanned.units.completedUnitCount == scanned.units.completedUnitCount)

        _ = goal.update(status: status(remaining: 10), catalog: nil)
        let moving = goal.update(status: status(remaining: 6, backedUp: 4, active: 0.9), catalog: nil)
        // The item in flight failed and its share went away.
        let failed = goal.update(status: status(remaining: 6, backedUp: 4, failed: 1), catalog: nil)
        #expect(failed.units.completedUnitCount == moving.units.completedUnitCount)
    }

    @Test func anEmptyGoalIsReachedAtOnce() {
        var goal = PhotoLibraryContinuedBackupGoal()
        let settled = status(phase: .completed, remaining: 0, backedUp: 100)
        let progress = goal.update(status: settled, catalog: nil)
        #expect(goal.total == 0)
        #expect(progress.units.completedUnitCount == Self.scale)
        #expect(goal.isReached(by: settled))
    }

    // MARK: - Result from the settled state

    @Test func aGoalThatSettledReportsSuccessAlsoWhenTheExpiryCameFirst() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3), catalog: nil)
        let settled = status(phase: .completed, remaining: 0, backedUp: 3)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: true, backupRuns: true)
        #expect(end == .completed)
        #expect(end.reportsSuccess)
        #expect(end.windowOutcome == .ran)
    }

    @Test func aGoalIsReachedOnlyWhenNothingRemains() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3), catalog: nil)
        // The goal's count is backed up, but photos that arrived later still wait.
        var newerWait = status(total: 105, remaining: 2, backedUp: 3)
        newerWait.settled = 3
        #expect(!goal.isReached(by: newerWait))
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: newerWait, didExpire: false, backupRuns: true)
                == .waiting)
    }

    @Test func rowsThatWaitForARetryKeepTheGoalOpen() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3), catalog: nil)
        var blocked = status(phase: .waiting, remaining: 0, backedUp: 3)
        blocked.waitingRetry = 1
        blocked.hasOutstandingWork = true
        #expect(!goal.isReached(by: blocked))
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: blocked, didExpire: false, backupRuns: true)
                == .waiting)
    }

    @Test func anExpiryWithWorkLeftReportsAStop() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3), catalog: nil)
        let settled = status(phase: .waiting, remaining: 2, backedUp: 1)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: true, backupRuns: true)
        #expect(end == .stopped)
        #expect(!end.reportsSuccess)
        #expect(end.windowOutcome == .expired)
    }

    @Test func anExpiryBeforeTheScanEndedReportsAStop() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: scanning(), catalog: nil)
        #expect(
            PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: scanning(), didExpire: true, backupRuns: true)
                == .stopped)
    }

    @Test func photosThatNeedAttentionReportNoSuccess() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3, failed: 1), catalog: nil)
        // The app shows the problem too, also one from before the start; the card agrees with it.
        let settled = status(phase: .needsAttention, remaining: 0, backedUp: 3, failed: 1)
        let end = PhotoLibraryContinuedBackupEnd.after(goal: goal, settled: settled, didExpire: false, backupRuns: true)
        #expect(end == .needsAttention)
        #expect(!end.reportsSuccess)
        #expect(end.windowOutcome == .ran)
    }

    @Test func workThatWaitsOrABackupThatStoppedReportsNoSuccess() {
        var goal = PhotoLibraryContinuedBackupGoal()
        _ = goal.update(status: status(remaining: 3), catalog: nil)
        let waiting = status(phase: .waitingForWiFi, remaining: 3)
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
