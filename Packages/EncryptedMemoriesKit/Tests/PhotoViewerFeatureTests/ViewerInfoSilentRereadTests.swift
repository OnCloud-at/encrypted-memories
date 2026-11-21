import PhotosCore
import XCTest

@testable import PhotoViewerCore

/// The Info panel reads the details of the shown photo. A failed read is repeated once without a message, because
/// the read changes nothing and a new attempt often succeeds. The titles of the neighbors that the viewer prefetches
/// never repeat a read, so browsing adds no request.
@MainActor
final class ViewerInfoSilentRereadTests: XCTestCase {
    private let item = PhotoItem(
        uid: PhotoUID(volumeID: "v", nodeID: "n0"), captureTime: .distantPast, mediaType: "image/jpeg")

    private func makeCoordinator(
        failing failures: Int, error: any Error = URLError(.networkConnectionLost), prefetchRadius: Int = 2
    ) -> (ViewerTitleMetadataCoordinator, FlakyMetadataProvider, Pause) {
        let provider = FlakyMetadataProvider(failures: failures, error: error)
        let pause = Pause()
        let coordinator = ViewerTitleMetadataCoordinator(
            metadataProvider: provider, placeNameResolver: nil, prefetchRadius: prefetchRadius,
            infoRereadPause: { await pause.wait($0) })
        return (coordinator, provider, pause)
    }

    func testAFailedReadIsRepeatedOnceBeforeTheInfoReportsFailure() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)

        let resolution = await coordinator.resolveForInfo(item)

        XCTAssertEqual(resolution.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(pause.waits, [ViewerTitleMetadataCoordinator.infoRereadDelay])
    }

    func testTheInfoReportsFailureOnlyAfterTheOneRepeatFailedToo() async {
        let (coordinator, provider, _) = makeCoordinator(failing: 5)

        let resolution = await coordinator.resolveForInfo(item)

        XCTAssertEqual(resolution.metadataLoadState, .failed)
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2, "one repeat, never a loop")
    }

    func testASuccessfulReadNeedsNoRepeatAndNoPause() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 0)

        let resolution = await coordinator.resolveForInfo(item)

        XCTAssertEqual(resolution.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(pause.waits.isEmpty)
    }

    func testAFailureThatTheTitleAlreadyCachedIsStillRepeatedWhenTheInfoOpens() async {
        let (coordinator, provider, _) = makeCoordinator(failing: 1)
        let title = await coordinator.resolve(item)
        XCTAssertEqual(title.metadataLoadState, .failed)

        let info = await coordinator.resolveForInfo(item)

        XCTAssertEqual(info.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2)
    }

    func testBrowsingTitlesNeverRepeatAFailedRead() async {
        let items = (0..<5).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\($0)"), captureTime: .distantPast, mediaType: "image/jpeg")
        }
        let (coordinator, provider, pause) = makeCoordinator(failing: 100, prefetchRadius: 1)

        coordinator.prepare(items: items, around: 2)
        // The viewer asks for a title again whenever the person swipes back to the photo.
        for _ in 0..<2 {
            for entry in items[1...3] { _ = await coordinator.resolve(entry) }
        }

        let reads = await provider.reads.count
        XCTAssertEqual(reads, 3, "the current photo and its two neighbors read once each, whatever is asked again")
        XCTAssertTrue(pause.waits.isEmpty)
    }

    func testTryAgainAfterTheSilentRepeatReadsOnceWithoutAnotherSilentRepeat() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 3)
        let failed = await coordinator.resolveForInfo(item)
        XCTAssertEqual(failed.metadataLoadState, .failed)

        coordinator.invalidate(item.uid)
        let failedAgain = await coordinator.resolveForInfo(item)

        XCTAssertEqual(failedAgain.metadataLoadState, .failed, "the person's own attempt shows its result")
        var reads = await provider.reads.count
        XCTAssertEqual(reads, 3, "two reads for the first open, one for the person's Try again")
        XCTAssertEqual(pause.waits.count, 1, "no second silent repeat behind the person's Try again")

        coordinator.invalidate(item.uid)
        let recovered = await coordinator.resolveForInfo(item)

        XCTAssertEqual(recovered.metadataLoadState, .loaded(PhotoMetadata()))
        reads = await provider.reads.count
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(pause.waits.count, 1)
    }

    func testLeavingThePhotoGrantsANewSilentRepeatWhenItOpensAgain() async {
        let items = [
            item,
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "n9"), captureTime: .distantPast, mediaType: "image/jpeg"),
        ]
        let (coordinator, provider, pause) = makeCoordinator(failing: 4, prefetchRadius: 0)
        coordinator.prepare(items: items, around: 0)
        let first = await coordinator.resolveForInfo(item)
        XCTAssertEqual(first.metadataLoadState, .failed)
        coordinator.prepare(items: items, around: 1)
        coordinator.prepare(items: items, around: 0)

        let second = await coordinator.resolveForInfo(item)

        XCTAssertEqual(second.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 5, "two for the first open, one prefetch of each photo, one silent repeat")
        XCTAssertEqual(pause.waits.count, 2, "each time the photo opens with a failed read, one silent repeat")
    }

    func testAResetOfTheViewerGrantsANewSilentRepeat() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 3)
        let first = await coordinator.resolveForInfo(item)
        XCTAssertEqual(first.metadataLoadState, .failed)

        coordinator.cancelAll()
        let second = await coordinator.resolveForInfo(item)

        XCTAssertEqual(second.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 4, "two for the first open, then the read and the silent repeat after the reset")
        XCTAssertEqual(pause.waits.count, 2)
    }

    // MARK: - The Info must still be there when the pause ends

    func testATitleReadThatFailsWhileTheInfoIsClosedIsNotRepeated() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)

        let resolution = await coordinator.resolveForInfo(item, infoIsOpen: { false })

        XCTAssertEqual(resolution.metadataLoadState, .failed)
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(pause.waits.isEmpty)
        XCTAssertTrue(coordinator.canRereadForInfo(item.uid), "the repeat stays available for the Info that opens")
    }

    func testAFailureWhileTheInfoWasClosedIsRepeatedWhenTheInfoOpensLater() async {
        let (coordinator, provider, _) = makeCoordinator(failing: 1)
        let flag = OpenFlag(false)
        let closed = await coordinator.resolveForInfo(item, infoIsOpen: { flag.isOpen })
        XCTAssertEqual(closed.metadataLoadState, .failed, "closed when the read ended: no repeat")

        flag.isOpen = true
        let opened = await coordinator.resolveForInfo(item, infoIsOpen: { flag.isOpen })

        XCTAssertEqual(opened.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2)
    }

    /// The person taps Info while the title read of a slow connection is still running: the read decides when it
    /// ends, so the failure that follows is repeated before the Info shows it.
    func testAnInfoThatOpensWhileTheFirstReadRunsRepeatsWhenThatReadFails() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)
        let flag = OpenFlag(false)
        await provider.setBeforeRead { await MainActor.run { flag.isOpen = true } }

        let resolution = await coordinator.resolveForInfo(item, infoIsOpen: { flag.isOpen })

        XCTAssertEqual(resolution.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(pause.waits.count, 1)
    }

    func testClosingTheInfoDuringThePauseStartsNoSecondRead() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)
        let flag = OpenFlag(true)
        pause.hook = { flag.isOpen = false }

        let resolution = await coordinator.resolveForInfo(item, infoIsOpen: { flag.isOpen })

        XCTAssertEqual(resolution.metadataLoadState, .failed)
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(coordinator.canRereadForInfo(item.uid), "a closed Info spends no repeat")
    }

    /// The production pause never throws: it returns when the task ends, so only the check after the pause stops a
    /// read for a task that nobody waits for any more.
    func testATaskThatEndsDuringThePauseStartsNoSecondRead() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)
        let holder = TaskHolder()
        pause.hook = { holder.task?.cancel() }
        let item = self.item
        holder.task = Task { await coordinator.resolveForInfo(item) }

        let resolution = await holder.task?.value

        XCTAssertEqual(resolution?.metadataLoadState, .failed)
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(coordinator.canRereadForInfo(item.uid), "an ended task spends no repeat")
    }

    func testLeavingThePhotoDuringThePauseStartsNoReadForIt() async {
        let items = [
            item,
            PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "n9"), captureTime: .distantPast, mediaType: "image/jpeg"),
        ]
        let (coordinator, provider, pause) = makeCoordinator(failing: 1, prefetchRadius: 0)
        pause.hook = { coordinator.prepare(items: items, around: 1) }
        coordinator.prepare(items: items, around: 0)

        _ = await coordinator.resolveForInfo(item)

        let reads = await provider.reads
        XCTAssertEqual(reads.filter { $0 == "n0" }.count, 1, "the photo that the viewer left is not read again")
    }

    // MARK: - A task that ended, a read that a sharer cancelled

    func testATaskThatEndedWhileTheFirstReadRanStartsNoPause() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 1)
        let holder = TaskHolder()
        await provider.setBeforeRead { await MainActor.run { holder.task?.cancel() } }
        let item = self.item
        holder.task = Task { await coordinator.resolveForInfo(item) }

        _ = await holder.task?.value

        XCTAssertTrue(pause.waits.isEmpty, "an ended task waits for nothing")
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
    }

    func testAReadThatASharerCancelledIsNotRepeated() async {
        for error in [CancellationError(), URLError(.cancelled)] as [any Error] {
            let (coordinator, provider, pause) = makeCoordinator(failing: 5, error: error)

            let resolution = await coordinator.resolveForInfo(item)

            XCTAssertEqual(resolution.failureCause, .cancelled, "\(error)")
            let reads = await provider.reads.count
            XCTAssertEqual(reads, 1, "\(error)")
            XCTAssertTrue(pause.waits.isEmpty, "\(error)")
        }
    }

    // MARK: - When an Info that opens reads again

    func testAnInfoThatOpensReadsAgainOnlyForAFailureWithItsRepeatLeft() async {
        let (coordinator, _, _) = makeCoordinator(failing: 2)
        XCTAssertFalse(
            coordinator.shouldReadAgainWhenInfoOpens(item.uid, metadataLoadState: .failed), "no read exists yet")

        _ = await coordinator.resolveForInfo(item, infoIsOpen: { false })
        XCTAssertTrue(coordinator.shouldReadAgainWhenInfoOpens(item.uid, metadataLoadState: .failed))
        for state in [PhotoMetadataLoadState.idle, .loading, .loaded(PhotoMetadata()), .unavailable] {
            XCTAssertFalse(
                coordinator.shouldReadAgainWhenInfoOpens(item.uid, metadataLoadState: state),
                "a read that still runs, or that did not fail, decides by itself: \(state)")
        }

        _ = await coordinator.resolveForInfo(item)
        XCTAssertFalse(
            coordinator.shouldReadAgainWhenInfoOpens(item.uid, metadataLoadState: .failed), "the repeat is spent")
    }

    // MARK: - Classified errors

    func testAFailureThatNamesAFixedCauseIsNotRepeated() async {
        let (coordinator, provider, pause) = makeCoordinator(failing: 5, error: ClassifiedFailure(cause: .permanent))

        let resolution = await coordinator.resolveForInfo(item)

        XCTAssertEqual(resolution.metadataLoadState, .failed)
        XCTAssertEqual(resolution.failureCause, .permanent)
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(pause.waits.isEmpty)
    }

    func testAFailureThatNamesATemporaryCauseIsRepeatedOnce() async {
        let (coordinator, provider, _) = makeCoordinator(failing: 1, error: ClassifiedFailure(cause: .network))

        let resolution = await coordinator.resolveForInfo(item)

        XCTAssertEqual(resolution.metadataLoadState, .loaded(PhotoMetadata()))
        let reads = await provider.reads.count
        XCTAssertEqual(reads, 2)
    }

    func testTheRepeatIsAvailableOnlyWhileTheReadFailedAndNoInfoRepeatedIt() async {
        let (coordinator, _, _) = makeCoordinator(failing: 2)
        XCTAssertFalse(coordinator.canRereadForInfo(item.uid), "nothing was read yet")

        _ = await coordinator.resolveForInfo(item, infoIsOpen: { false })
        XCTAssertTrue(coordinator.canRereadForInfo(item.uid))

        _ = await coordinator.resolveForInfo(item)
        XCTAssertFalse(coordinator.canRereadForInfo(item.uid), "the repeat is spent")
    }
}

@MainActor
private final class Pause {
    private(set) var waits: [Duration] = []
    var hook: (@MainActor () -> Void)?

    func wait(_ duration: Duration) async {
        waits.append(duration)
        hook?()
    }
}

@MainActor
private final class OpenFlag {
    var isOpen: Bool
    init(_ isOpen: Bool) { self.isOpen = isOpen }
}

@MainActor
private final class TaskHolder {
    var task: Task<ViewerTitleMetadataResolution, Never>?
}

private struct ClassifiedFailure: Error, FailureClassifiable {
    let cause: FailureCause
    var failureCause: FailureCause { cause }
}

private actor FlakyMetadataProvider: PhotoMetadataProvider {
    private var remainingFailures: Int
    private let error: any Error
    /// The node IDs that were read, in order.
    private(set) var reads: [String] = []
    private var beforeRead: (@Sendable () async -> Void)?

    init(failures: Int, error: any Error) {
        remainingFailures = failures
        self.error = error
    }

    func setBeforeRead(_ action: @escaping @Sendable () async -> Void) { beforeRead = action }

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        reads.append(uid.nodeID)
        if reads.count == 1 { await beforeRead?() }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw error
        }
        return PhotoMetadata()
    }
}
