import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@Suite struct PhotoLibraryContinuedBackupPromptTests {
    private typealias Prompt = PhotoLibraryContinuedBackupPrompt
    private typealias Volume = PhotoLibraryContinuedBackupVolume

    private func status(_ phase: BackupStatus.Phase = .uploading, remaining: Int) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.totalConsidered = 1_000
        status.remainingCount = remaining
        status.hasOutstandingWork = remaining > 0
        return status
    }

    private func entry(
        _ kind: PhotoLibraryCatalogMediaKind = .image, width: Int = 4_032, height: Int = 3_024, seconds: Double = 0,
        live: Bool = false
    ) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: UUID().uuidString, cloudIdentifier: nil, creationDate: nil, modificationDate: nil,
            pixelWidth: width, pixelHeight: height, durationSeconds: seconds, mediaKind: kind, isLivePhoto: live,
            livePlaybackOff: false, resources: [], contentFingerprint: 0, metadataRevision: 0, firstSeenAt: Date(),
            lastSeenAt: Date(), isRemoved: false, removedAt: nil)
    }

    // MARK: - Estimated time

    @Test func manySmallPhotosAskFromTheirCountAlone() {
        let tiny = Volume.bytes(of: Array(repeating: entry(width: 100, height: 100), count: 99))
        #expect(!Prompt.isWorthAsking(status(remaining: 99), estimatedBytes: tiny))
        #expect(Prompt.itemsThatAlwaysAsk == 100)
        #expect(Prompt.isWorthAsking(status(remaining: 100), estimatedBytes: nil))
        #expect(!Prompt.needsVolume(status(remaining: 100)), "no catalog read when the count decides")
        #expect(Prompt.needsVolume(status(remaining: 99)))
        #expect(!Prompt.needsVolume(status(remaining: 0)))
    }

    @Test func fewLargeVideosAskFromTheirVolume() {
        let videos = Array(repeating: entry(.video, width: 3_840, height: 2_160, seconds: 150), count: 10)
        let bytes = Volume.bytes(of: videos)
        #expect(bytes >= 10 * 1_000_000_000, "ten 4K videos of 150 s are about 1 GB each")
        #expect(Prompt.isWorthAsking(status(remaining: 10), estimatedBytes: bytes))
        #expect(Prompt.isWorthAsking(status(remaining: 1), estimatedBytes: 600_000_000), "600 MB take 5 minutes")
        #expect(!Prompt.isWorthAsking(status(remaining: 1), estimatedBytes: 590_000_000))
    }

    @Test func aFailedVolumeReadFallsBackToTheCount() {
        #expect(!Prompt.isWorthAsking(status(remaining: 50), estimatedBytes: nil))
        #expect(Prompt.isWorthAsking(status(remaining: 100), estimatedBytes: nil))
    }

    @Test func onlyAPassThatChecksOrUploadsAsks() {
        for phase: BackupStatus.Phase in [
            .idle, .scanning, .paused, .waitingForWiFi, .waiting, .completed, .needsAttention,
        ] {
            #expect(!Prompt.isWorthAsking(status(phase, remaining: 500), estimatedBytes: nil), "\(phase)")
        }
        #expect(Prompt.isWorthAsking(status(.checking, remaining: 500), estimatedBytes: nil))
    }

    @Test func theSituationMustAllowTheQuestion() {
        let busy = status(remaining: 500)
        #expect(Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isTaskActive: false, wasAsked: false)))
        #expect(!Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isTaskActive: true, wasAsked: false)))
        #expect(!Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isTaskActive: false, wasAsked: true)))
    }

    @Test func theMarkerResetsOnlyWhenASettledBackupOwesNothing() {
        #expect(Prompt.backlogDrained(status(.completed, remaining: 0), isSyncing: false))
        #expect(!Prompt.backlogDrained(status(.uploading, remaining: 0), isSyncing: true), "a pass still runs")
        var waitingForRetry = status(.waiting, remaining: 0)
        waitingForRetry.hasOutstandingWork = true
        #expect(!Prompt.backlogDrained(waitingForRetry, isSyncing: false), "rows wait for a retry")
        // A controller that has not projected its queue yet, at a cold start, shows an empty status.
        #expect(!Prompt.backlogDrained(BackupStatus(), isSyncing: false), "an unprojected status says nothing")
    }

    // MARK: - Volume estimate

    @Test func photosCountByTheirPixelsAndLivePhotosAddTheirVideo() {
        #expect(Volume.bytes(of: entry(width: 4_000, height: 3_000)) == 6_000_000)
        #expect(Volume.bytes(of: entry(width: 4_000, height: 3_000, live: true)) == 10_000_000)
    }

    @Test func videosCountByTheirDurationInTheirSizeClass() {
        #expect(Volume.bytes(of: entry(.video, width: 2_160, height: 3_840, seconds: 60)) == 402_000_000)
        #expect(Volume.bytes(of: entry(.video, width: 1_920, height: 1_080, seconds: 60)) == 90_000_000)
        #expect(Volume.bytes(of: entry(.video, width: 1_280, height: 720, seconds: 60)) == 42_000_000)
    }

    @Test func anUnknownItemCountsAsAPhoto() {
        #expect(Volume.bytes(of: nil) == 6_000_000)
        #expect(Volume.bytes(of: [nil, nil]) == 12_000_000)
    }

    @Test func theEstimateNeverUnderflowsOrOverflows() {
        #expect(Volume.bytes(of: entry(width: -5, height: 10)) == 0)
        #expect(Volume.bytes(of: entry(.video, width: 3_840, height: 2_160, seconds: -3)) == 0)
        #expect(Volume.bytes(of: entry(.video, width: 3_840, height: 2_160, seconds: .infinity)) == Int64.max)
        let huge = entry(.video, width: 3_840, height: 2_160, seconds: 1e15)
        #expect(Volume.bytes(of: [huge, huge, huge]) == Int64.max)
        #expect(Prompt.isWorthAsking(status(remaining: 3), estimatedBytes: Int64.max))
    }
}

@MainActor @Suite struct PhotoLibraryContinuedBackupPromptClaimTests {
    private final class Place {}

    @Test func onePlaceShowsThePromptAtATime() {
        let claim = PhotoLibraryContinuedBackupPrompt.Claim()
        let root = Place()
        let backupScreen = Place()

        #expect(claim.claim(backupScreen))
        #expect(claim.claim(backupScreen), "the holder keeps its claim")
        #expect(!claim.claim(root), "a second place waits, also in another window")

        claim.release(root)
        #expect(!claim.claim(root), "only the holder releases")
        claim.release(backupScreen)
        #expect(claim.claim(root))
    }

    /// A place that goes away without releasing, as a scene that ends without a last phase, must not block the others.
    @Test func aPlaceThatIsGoneHoldsNoClaim() {
        let claim = PhotoLibraryContinuedBackupPrompt.Claim()
        var gone: Place? = Place()
        #expect(claim.claim(gone!))
        gone = nil
        #expect(claim.claim(Place()))
    }
}

/// The rules of one place that shows the question: the marker, the calm time and the cover (#1108).
@MainActor @Suite struct PhotoLibraryContinuedBackupPromptAskerTests {
    private typealias Asker = PhotoLibraryContinuedBackupPrompt.Asker

    @MainActor private final class MarkerBox {
        var value = false
        var marker: Asker.Marker { Asker.Marker(isSet: { self.value }, set: { self.value = $0 }) }
    }

    private let start = ContinuousClock.now

    private func busy(remaining: Int = 500) -> BackupStatus {
        var status = BackupStatus()
        status.phase = .uploading
        status.totalConsidered = 1_000
        status.remainingCount = remaining
        status.hasOutstandingWork = remaining > 0
        return status
    }

    private func askerAfterTheCalmTime(
        _ marker: MarkerBox, claim: PhotoLibraryContinuedBackupPrompt.Claim = .init()
    )
        -> Asker
    {
        let asker = Asker(claim: claim, marker: marker.marker)
        asker.sceneBecameActive(at: start)
        return asker
    }

    @Test func itAsksOnlyAfterTheSceneWasActiveForTheCalmTime() {
        let asker = askerAfterTheCalmTime(MarkerBox())
        #expect(
            asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(1)) == .wait(.seconds(1)))
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(2)) == .ask)
        #expect(asker.isPresenting)
    }

    @Test func withoutAnActiveSceneItDoesNotAsk() {
        let asker = Asker(claim: .init(), marker: MarkerBox().marker)
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(60)) == .none)

        let left = askerAfterTheCalmTime(MarkerBox())
        left.sceneEnteredBackground()
        #expect(left.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(60)) == .none)
    }

    @Test func eitherAnswerSetsTheMarkerAndOnlyContinueStartsTheTask() {
        for accepted in [false, true] {
            let marker = MarkerBox()
            let asker = askerAfterTheCalmTime(marker)
            #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3)) == .ask)
            #expect(asker.answered(accepted: accepted) == accepted)
            #expect(marker.value, "the answer closes the question for this backlog")
            #expect(!asker.isPresenting)
            #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(9)) == .none)
        }
    }

    @Test func goingToTheBackgroundWhileItAsksCountsAsNotNow() {
        let marker = MarkerBox()
        let asker = askerAfterTheCalmTime(marker)
        _ = asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3))

        asker.sceneEnteredBackground()

        #expect(marker.value)
        #expect(!asker.isPresenting)
    }

    @Test func aCoverHoldsTheQuestionAndItsEndStartsTheCalmTimeAgain() {
        let asker = askerAfterTheCalmTime(MarkerBox())
        asker.coverChanged(isCovered: true, at: start + .seconds(1))
        #expect(
            asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(5)) == .held,
            "the place looks at the cover again")

        asker.coverChanged(isCovered: false, at: start + .seconds(6))
        #expect(
            asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(7)) == .wait(.seconds(1)))
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(8)) == .ask)
    }

    @Test func aCoverOverTheQuestionClosesItWithoutTheMarker() {
        let marker = MarkerBox()
        let claim = PhotoLibraryContinuedBackupPrompt.Claim()
        let asker = askerAfterTheCalmTime(marker, claim: claim)
        _ = asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3))

        asker.coverChanged(isCovered: true, at: start + .seconds(4))

        #expect(!asker.isPresenting)
        #expect(!marker.value, "the person did not answer")
        #expect(claim.claim(Asker(claim: claim, marker: marker.marker)), "the claim is free for another place")
    }

    @Test func onlyOnePlaceAsksAtATime() {
        let claim = PhotoLibraryContinuedBackupPrompt.Claim()
        let marker = MarkerBox()
        let first = askerAfterTheCalmTime(marker, claim: claim)
        let second = askerAfterTheCalmTime(marker, claim: claim)
        #expect(first.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3)) == .ask)
        #expect(
            second.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3)) == .held,
            "the second place looks again when the first one's question closes")
    }

    /// A place stops looking when only a change of the backup or the scene can let it ask: it keeps looking only while a
    /// cover or another place's question holds it.
    @Test func aBacklogThatTakesTooLittleTimeHoldsNothing() {
        let asker = askerAfterTheCalmTime(MarkerBox())
        let short = busy(remaining: 30)
        #expect(asker.isWaitingToAsk(short, isTaskActive: false), "the volume may still decide")
        #expect(asker.next(short, estimatedBytes: 30_000_000, isTaskActive: false, at: start + .seconds(3)) == .none)

        asker.coverChanged(isCovered: true, at: start + .seconds(4))
        #expect(
            asker.next(short, estimatedBytes: 30_000_000, isTaskActive: false, at: start + .seconds(5)) == .none,
            "a cover holds only a place that could ask")
        #expect(
            asker.next(short, estimatedBytes: 600_000_000, isTaskActive: false, at: start + .seconds(5)) == .held)

        asker.sceneBecameInactive()
        #expect(
            asker.next(short, estimatedBytes: 600_000_000, isTaskActive: false, at: start + .seconds(6)) == .none,
            "an inactive scene waits for its next phase")
    }

    /// A place that stopped looking does not know what covered it meanwhile: its next look starts the calm time again.
    @Test func aPlaceThatStoppedLookingStartsTheCalmTimeAgain() {
        let asker = askerAfterTheCalmTime(MarkerBox())
        asker.coverChanged(isCovered: false, at: start)
        asker.stoppedLooking()

        // A sheet opened and closed while the place did not look; the backlog grew, and the place looks again.
        asker.coverChanged(isCovered: false, at: start + .seconds(60))
        let lookedAgain = start + .seconds(60)
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: lookedAgain) == .wait(.seconds(2)))
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(62)) == .ask)

        let returned = askerAfterTheCalmTime(MarkerBox())
        returned.stoppedLooking()
        returned.sceneBecameActive(at: start + .seconds(70))
        #expect(
            returned.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(75)) == .held,
            "the place looks at its cover before the calm time starts")
    }

    @Test func anInactiveSceneDoesNotAskAndClosesNothing() {
        let marker = MarkerBox()
        let asker = askerAfterTheCalmTime(marker)
        asker.sceneBecameInactive()
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(5)) == .none)
        #expect(!asker.isWaitingToAsk(busy(), isTaskActive: false))

        // Back to active: the calm time starts again.
        asker.sceneBecameActive(at: start + .seconds(6))
        #expect(
            asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(7)) == .wait(.seconds(1)))

        // A question that shows stays, and the inactive scene sets no marker.
        #expect(asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(8)) == .ask)
        asker.sceneBecameInactive()
        #expect(asker.isPresenting)
        #expect(!marker.value)
    }

    @Test func aQuestionThatClosedWithoutAnAnswerFreesTheClaimWithoutTheMarker() {
        let marker = MarkerBox()
        let claim = PhotoLibraryContinuedBackupPrompt.Claim()
        let asker = askerAfterTheCalmTime(marker, claim: claim)
        _ = asker.next(busy(), estimatedBytes: nil, isTaskActive: false, at: start + .seconds(3))

        asker.questionClosed()

        #expect(!asker.isPresenting)
        #expect(!marker.value)
        #expect(claim.claim(Asker(claim: claim, marker: marker.marker)))
    }

    /// The view reads the catalog and the screen only while the cheap conditions let the place ask.
    @Test func itWaitsToAskOnlyWhileTheCheapConditionsHold() {
        let marker = MarkerBox()
        let asker = askerAfterTheCalmTime(marker)
        #expect(asker.isWaitingToAsk(busy(), isTaskActive: false))
        #expect(asker.isWaitingToAsk(busy(remaining: 50), isTaskActive: false), "the volume may still decide")
        #expect(!asker.isWaitingToAsk(busy(), isTaskActive: true))
        var idle = busy()
        idle.phase = .idle
        #expect(!asker.isWaitingToAsk(idle, isTaskActive: false))
        marker.value = true
        #expect(!asker.isWaitingToAsk(busy(), isTaskActive: false))
        #expect(!Asker(claim: .init(), marker: MarkerBox().marker).isWaitingToAsk(busy(), isTaskActive: false))
    }

    @Test func aDrainedBacklogTouchesTheMarkerOnlyWhenItIsSet() {
        var writes = 0
        let asker = Asker(claim: .init(), marker: .init(isSet: { false }, set: { _ in writes += 1 }))
        var drained = busy(remaining: 0)
        drained.phase = .completed
        asker.backupChanged(drained, isSyncing: false)
        asker.backupChanged(drained, isSyncing: false)
        #expect(writes == 0)
    }

    @Test func theMarkerResetsWhenTheProjectedBacklogDrained() {
        let marker = MarkerBox()
        marker.value = true
        let asker = askerAfterTheCalmTime(marker)

        asker.backupChanged(BackupStatus(), isSyncing: false)
        #expect(marker.value, "a cold start's empty status keeps the answer")

        var drained = busy(remaining: 0)
        drained.phase = .completed
        asker.backupChanged(drained, isSyncing: false)
        #expect(!marker.value)
    }
}
