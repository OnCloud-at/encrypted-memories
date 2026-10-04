import Foundation
import Testing

@testable import TimelineCore

@Suite struct LibraryRefreshBannerStateTests {
    @Test func failedManualRefreshDisappearsAfterLaterRemoteRefreshSucceeds() throws {
        var state = LibraryRefreshBannerState()
        let result1 = state.beginManualRefresh()
        #expect(result1)
        let finished = state.finishManualRefresh(succeeded: false)
        let dismissal = try #require(finished)
        #expect(state.message == .refreshFailed)

        let result2 = state.beginRemoteRefresh()
        #expect(result2)
        state.dismiss(dismissal)
        #expect(state.isBusy)
        state.finishRemoteRefresh(succeeded: true)

        #expect(!state.isBusy)
        #expect(state.message == nil)
    }

    @Test func remoteRefreshSuccessRemovesRefreshFailureBeforeDismissal() {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        _ = state.finishManualRefresh(succeeded: false)

        let result3 = state.beginRemoteRefresh()
        #expect(result3)
        state.finishRemoteRefresh(succeeded: true)

        #expect(state.message == nil)
    }

    @Test func dismissalDuringRefreshAppliesWhenRefreshEnds() throws {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        let finished = state.finishManualRefresh(succeeded: false)
        let dismissal = try #require(finished)

        let result4 = state.beginRemoteRefresh()
        #expect(result4)
        state.dismiss(dismissal)
        #expect(state.message == .refreshFailed)
        state.finishRemoteRefresh(succeeded: false)

        #expect(state.message == nil)
    }

    @Test func failedRemoteRefreshKeepsRefreshFailureUntilDismissal() throws {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        let finished = state.finishManualRefresh(succeeded: false)
        let dismissal = try #require(finished)

        _ = state.beginRemoteRefresh()
        state.finishRemoteRefresh(succeeded: false)
        #expect(state.message == .refreshFailed)

        state.dismiss(dismissal)
        #expect(state.message == nil)
    }

    @Test func indexingWarningSurvivesRemoteRefreshSuccess() {
        var state = LibraryRefreshBannerState()
        state.beginUploadRefresh()
        state.waitForUploadRefresh()
        let result5 = state.finishUploadRefresh(found: false)
        #expect(result5 == nil)
        #expect(state.message == .notYetIndexed)

        let result6 = state.beginRemoteRefresh()
        #expect(result6)
        state.finishRemoteRefresh(succeeded: true)

        #expect(state.message == .notYetIndexed)
        #expect(state.message?.tone == .failure)
    }

    @Test func backupIndexingWarningSurvivesRemoteRefreshSuccess() {
        var state = LibraryRefreshBannerState()
        state.beginBackupUploadRefresh()
        #expect(state.applyBackupUploadRefresh(.notYetVisible) == nil)

        _ = state.beginRemoteRefresh()
        state.finishRemoteRefresh(succeeded: true)

        #expect(state.message == .notYetIndexed)
    }

    @Test func earlierDismissalKeepsLaterIndexingWarning() throws {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        let finished = state.finishManualRefresh(succeeded: true)
        let dismissal = try #require(finished)

        state.beginBackupUploadRefresh()
        _ = state.applyBackupUploadRefresh(.notYetVisible)
        state.dismiss(dismissal)

        #expect(state.message == .notYetIndexed)
    }

    @Test func refreshRoutesWaitForRunningRefresh() {
        var state = LibraryRefreshBannerState()
        let result7 = state.beginRemoteRefresh()
        #expect(result7)
        let result8 = state.beginManualRefresh()
        #expect(!result8)
        let result9 = state.beginRemoteRefresh()
        #expect(!result9)
        #expect(state.message == nil)

        state.finishRemoteRefresh(succeeded: true)
        let result10 = state.beginManualRefresh()
        #expect(result10)
        let result11 = state.beginRemoteRefresh()
        #expect(!result11)
        #expect(state.message == .refreshing)
    }

    @Test func manualRefreshShowsResultAndDismissesWhenIdle() throws {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        #expect(state.message?.tone == .working)
        let finished = state.finishManualRefresh(succeeded: true)
        let dismissal = try #require(finished)
        #expect(dismissal.delay == LibraryRefreshBannerState.dismissalDelay)
        #expect(state.message == .refreshed)
        #expect(state.message?.tone == .success)

        state.dismiss(dismissal)
        #expect(state.message == nil)
    }

    @Test func uploadRefreshShowsUploadedPhoto() throws {
        var state = LibraryRefreshBannerState()
        state.beginUploadRefresh()
        #expect(state.isBusy)
        #expect(state.message == .refreshingAfterUpload)
        let finished = state.finishUploadRefresh(found: true)
        let dismissal = try #require(finished)
        #expect(!state.isBusy)
        #expect(state.message == .uploaded)

        state.dismiss(dismissal)
        #expect(state.message == nil)
    }

    @Test func backupDecisionsSetMessageAndGate() {
        var state = LibraryRefreshBannerState()
        state.beginBackupUploadRefresh()
        #expect(state.isBusy)
        #expect(state.message == .refreshing)

        #expect(state.applyBackupUploadRefresh(.retry(after: .zero)) == nil)
        #expect(state.isBusy)
        #expect(state.message == .waitingForRefresh)

        #expect(state.applyBackupUploadRefresh(.succeeded) != nil)
        #expect(!state.isBusy)
        #expect(state.message == .refreshed)

        state.beginBackupUploadRefresh()
        #expect(state.applyBackupUploadRefresh(.failed) != nil)
        #expect(!state.isBusy)
        #expect(state.message == .refreshFailed)

        state.beginBackupUploadRefresh()
        #expect(state.applyBackupUploadRefresh(.cancelled) == nil)
        #expect(!state.isBusy)
        #expect(state.message == nil)
    }

    @Test func scopeLossClearsBannerAndGate() {
        var state = LibraryRefreshBannerState()
        _ = state.beginManualRefresh()
        state.loseScopeAccess()

        #expect(!state.isBusy)
        #expect(state.message == nil)
    }
}
