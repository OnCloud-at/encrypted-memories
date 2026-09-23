import Foundation
import Testing

@testable import PhotosCore

@Suite struct LibraryRuntimeActivityTests {
    @Test func independentActivitiesCannotClearEachOthersDemand() {
        let state = LibraryRuntimeState()
        let first = state.beginActivity(.videoPlayback)
        let second = state.beginActivity(.videoPlayback)
        let transfer = state.beginActivity(.userTransfer)
        state.update { $0.hasVisibleMediaDemand = false }
        #expect(state.snapshot().activeVideoPlaybackCount == 2)
        #expect(state.snapshot().activeUserTransferCount == 1)
        first.end()
        first.end()
        #expect(state.snapshot().activeVideoPlaybackCount == 1)
        second.end()
        #expect(state.snapshot().activeVideoPlaybackCount == 0)
        #expect(state.snapshot().activeUserTransferCount == 1)
        transfer.end()
        #expect(state.snapshot().activeUserTransferCount == 0)
    }

    @Test func oldAccountActivityCannotEndNewAccountDemand() {
        let state = LibraryRuntimeState()
        let old = state.beginActivity(.videoPlayback)
        #expect(old.isActive)
        state.beginNewGeneration()
        #expect(!old.isActive)
        let current = state.beginActivity(.videoPlayback)
        #expect(current.isActive)
        old.end()
        #expect(state.snapshot().activeVideoPlaybackCount == 1)
        current.end()
        #expect(!current.isActive)
        #expect(state.snapshot().activeVideoPlaybackCount == 0)
    }

    @Test func activePlaybackAndTransfersYieldAutomaticWorkButAllowInteractiveSearch() {
        for activity in [LibraryRuntimeActivity.videoPlayback, .userTransfer, .search] {
            let state = LibraryRuntimeState()
            let registration = state.beginActivity(activity)
            let policy = LibraryResourcePolicy()
            let automatic = LibraryWorkRequest(workload: .mlInference, intent: .automatic, memoryClass: .small)
            let interactive = LibraryWorkRequest(workload: .mlInference, intent: .interactive, memoryClass: .small)
            #expect(!policy.budget(for: automatic, snapshot: state.snapshot()).isAdmitted)
            #expect(policy.budget(for: interactive, snapshot: state.snapshot()).isAdmitted)
            registration.end()
            #expect(policy.budget(for: automatic, snapshot: state.snapshot()).isAdmitted)
        }
    }

    @Test func releasingAnOwnerReleasesItsActivity() {
        let state = LibraryRuntimeState()
        var owner: LibraryRuntimeActivityRegistration? = state.beginActivity(.search)
        #expect(owner != nil)
        #expect(state.snapshot().activeSearchCount == 1)
        owner = nil
        #expect(state.snapshot().activeSearchCount == 0)
    }
}
