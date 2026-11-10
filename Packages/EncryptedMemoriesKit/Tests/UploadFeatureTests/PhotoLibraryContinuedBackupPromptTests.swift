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

    private let calm = Prompt.Situation(isCalm: true, isTaskActive: false, wasAsked: false)

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
        for phase: BackupStatus.Phase in [.idle, .scanning, .paused, .waitingForWiFi, .waiting, .completed, .needsAttention] {
            #expect(!Prompt.isWorthAsking(status(phase, remaining: 500), estimatedBytes: nil), "\(phase)")
        }
        #expect(Prompt.isWorthAsking(status(.checking, remaining: 500), estimatedBytes: nil))
    }

    @Test func theSituationMustAllowTheQuestion() {
        let busy = status(remaining: 500)
        #expect(Prompt.shouldAsk(busy, estimatedBytes: nil, in: calm))
        #expect(!Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isCalm: false, isTaskActive: false, wasAsked: false)))
        #expect(!Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isCalm: true, isTaskActive: true, wasAsked: false)))
        #expect(!Prompt.shouldAsk(busy, estimatedBytes: nil, in: .init(isCalm: true, isTaskActive: false, wasAsked: true)))
    }

    @Test func theMarkerResetsOnlyWhenASettledBackupOwesNothing() {
        #expect(Prompt.backlogDrained(status(.completed, remaining: 0), isSyncing: false))
        #expect(!Prompt.backlogDrained(status(.uploading, remaining: 0), isSyncing: true), "a pass still runs")
        var waitingForRetry = status(.waiting, remaining: 0)
        waitingForRetry.hasOutstandingWork = true
        #expect(!Prompt.backlogDrained(waitingForRetry, isSyncing: false), "rows wait for a retry")
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
