import Foundation
import PhotosCore
import Testing

@testable import ProtonDriveBackend

@Suite struct TimelineLoadCommitPolicyTests {
    @Test func unchangedCachedTimelineUsesSDKEnumeration() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .sdkCache)
    }

    @Test func changedServerRevisionUsesAuthoritativePhotosList() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-5",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
    }

    @Test func pendingLocalUploadBypassesSDKCacheBeforeEventAdvances() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: true,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
    }

    @Test func persistedUploadEvidenceRepairsAPreviouslyCommittedStaleTimeline() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: "event-4",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: true
            ) == .authoritativePhotosList)
    }

    @Test func firstLoadWithoutCacheKeepsSDKBootstrapPath() {
        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: nil,
                currentEventToken: "event-1",
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .sdkCache)
    }

    @Test func inventoryTokenContractForcesOneAuthoritativeRefreshForLegacyCaches() {
        let current = TimelineInventoryValidationTokenPolicy.persistedToken(remoteEventToken: "event-4")

        #expect(
            TimelineInventorySourcePolicy.decide(
                cachedEventToken: "event-4",
                currentEventToken: current,
                hasPendingLocalUploads: false,
                hasUnmaterializedLocalEvidence: false
            ) == .authoritativePhotosList)
        #expect(TimelineInventoryValidationTokenPolicy.remoteEventToken(from: current) == "event-4")
    }

    @Test func stableCompleteEnumerationPublishesCurrentToken() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-4",
            enrichmentComplete: true
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: "event-4",
                    monitorBaseline: "event-4"
                ))
    }

    @Test func concurrentMutationKeepsUsableInventoryButForcesConvergence() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-5",
            enrichmentComplete: true
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: "event-4",
                    monitorBaseline: "event-4"
                ))
    }

    @Test func incompleteOptionalEnrichmentStaysMemoryOnlyAndForcesRetry() {
        let decision = TimelineLoadCommitPolicy.decide(
            startEventToken: "event-4",
            endEventToken: "event-4",
            enrichmentComplete: false
        )

        #expect(
            decision
                == TimelineLoadCommitDecision(
                    persistedValidationToken: nil,
                    monitorBaseline: ""
                ))
    }

    @Test func remoteEventEvidenceTracksOnlyActiveFilesInThePhotosShare() throws {
        let data = Data(
            #"""
            {
              "Events": [
                {"EventType": 1, "ContextShareID": "photos", "Link": {"LinkID": "new-photo", "Type": 2, "State": 1}},
                {"EventType": 1, "ContextShareID": "other", "Link": {"LinkID": "other-file", "Type": 2, "State": 1}},
                {"EventType": 0, "Link": {"LinkID": "removed", "Type": 2, "State": 0}}
              ],
              "EventID": "event-5", "More": 0, "Refresh": 0
            }
            """#.utf8)
        let page = try JSONDecoder().decode(VolumeEventPage.self, from: data)
        var active = Set(["removed"])

        TimelineRemoteEventVisibilityPolicy.apply(page.events, photosShareID: "photos", to: &active)

        #expect(active == Set(["new-photo"]))
    }

    @Test func remoteVisibilityFailureUsesTheSharedConvergenceMarker() {
        let error: any Error = TimelineInventoryVisibilityError.remoteChangesNotVisible(1)
        #expect(error is any TimelineInventoryConvergenceError)
    }
}
