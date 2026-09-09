import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

private actor UploadCoordinatorGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private actor FolderEnqueueProbe {
    private let firstRelease = UploadCoordinatorGate()
    private var started: [String] = []
    private var activeCount = 0
    private var peakActiveCount = 0
    private var failures: Set<String> = []

    func fail(_ name: String) {
        failures.insert(name)
    }

    func run(url: URL) async throws {
        started.append(url.lastPathComponent)
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        if started.count == 1 {
            await firstRelease.wait()
        }
        activeCount -= 1
        if failures.contains(url.lastPathComponent) {
            throw FolderEnumerationError(
                operation: .readDirectory,
                url: url,
                failureClass: .permissionDenied,
                domain: NSPOSIXErrorDomain,
                code: 13
            )
        }
    }

    func releaseFirst() async {
        await firstRelease.open()
    }

    func snapshot() -> (started: [String], peakActiveCount: Int) {
        (started, peakActiveCount)
    }
}

final class UploadCoordinatorTests: XCTestCase {
    func testSnapshotMailboxIsBoundedAndRejectsLateDelivery() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let mailbox = UploadCallbackMailbox(continuation: continuation)

        for value in 0..<10_000 {
            XCTAssertTrue(mailbox.deliver(value))
        }
        mailbox.finish()
        XCTAssertFalse(mailbox.deliver(10_000))

        var values: [Int] = []
        for await value in stream { values.append(value) }
        XCTAssertEqual(values, [9_999], "pending snapshots must stay bounded to one newest value")
    }

    func testSnapshotMailboxDropsOutOfOrderOldValueBeforeConsumerRuns() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: UInt64.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let mailbox = UploadCallbackMailbox(
            continuation: continuation,
            sequence: { $0 }
        )

        XCTAssertTrue(mailbox.deliver(10))
        XCTAssertTrue(mailbox.deliver(12))
        XCTAssertFalse(mailbox.deliver(11))
        mailbox.finish()

        var values: [UInt64] = []
        for await value in stream { values.append(value) }
        XCTAssertEqual(values, [12])
    }

    @MainActor
    func testOlderDeferredSnapshotCannotOverwriteNewerTerminalPair() {
        let manager = UploadManager(uploader: MockUploader(deliverProgress: false))
        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: .sdkUploader,
            canCreateAlbum: false,
            canAddToAlbum: false,
            canSetAlbumCover: false
        )
        let url = URL(fileURLWithPath: "/terminal.jpg")
        let id = UUID()
        let queued = UploadItem(
            id: id, ordinal: 0, fileURL: url, displayName: "terminal.jpg",
            mediaType: "image/jpeg", byteCount: 1, state: .queued
        )
        var terminal = queued
        terminal.state = .completed
        var terminalStats = UploadQueueStats()
        terminalStats.completed = 1

        coordinator.applySnapshot(.init(sequence: 10, items: [queued], stats: .init()))
        coordinator.applySnapshot(.init(sequence: 11, items: [terminal], stats: terminalStats))
        coordinator.applySnapshot(.init(sequence: 10, items: [queued], stats: .init()))

        XCTAssertEqual(coordinator.items, [terminal])
        XCTAssertEqual(coordinator.stats, terminalStats)
    }

    @MainActor
    func testCompletedEventsRemainLosslessAcrossSeveralTerminalUploadsAndConcurrentStarts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-coordinator-" + UUID().uuidString)
        let urls = try makeTempFiles(["a.jpg", "b.jpg", "c.jpg"], in: dir)
        let manager = UploadManager(
            uploader: MockUploader(workDuration: .milliseconds(1), deliverProgress: false),
            maxConcurrent: 1
        )
        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: .sdkUploader,
            canCreateAlbum: false,
            canAddToAlbum: false,
            canSetAlbumCover: false
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await coordinator.start() } }
        }
        _ = await manager.enqueueFiles(urls, destination: .library)
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.completedUploadRevision < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(coordinator.completedUploadRevision, 3)
        XCTAssertEqual(coordinator.latestCompletedUpload?.displayName, "c.jpg")

        await coordinator.start()
        XCTAssertEqual(coordinator.completedUploadRevision, 3)
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func testFolderConfirmationsAreSerialized() async {
        let probe = FolderEnqueueProbe()
        let manager = UploadManager(uploader: MockUploader(deliverProgress: false))
        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: .sdkUploader,
            canCreateAlbum: false,
            canAddToAlbum: false,
            canSetAlbumCover: false,
            folderEnqueueOperation: { url, _ in
                try await probe.run(url: url)
                return []
            }
        )

        coordinator.chooseDestination(folder: URL(fileURLWithPath: "/first"))
        coordinator.confirm(destination: .library)
        while true {
            let snapshot = await probe.snapshot()
            if snapshot.started.count >= 1 { break }
            await Task.yield()
        }

        coordinator.chooseDestination(folder: URL(fileURLWithPath: "/second"))
        coordinator.confirm(destination: .library)
        for _ in 0..<20 { await Task.yield() }
        let blocked = await probe.snapshot()
        XCTAssertEqual(blocked.started, ["first"])

        await probe.releaseFirst()
        while true {
            let snapshot = await probe.snapshot()
            if snapshot.started.count >= 2 { break }
            await Task.yield()
        }
        let result = await probe.snapshot()
        XCTAssertEqual(result.started, ["first", "second"])
        XCTAssertEqual(result.peakActiveCount, 1)
    }

    @MainActor
    func testLatestFolderConfirmationClearsAnOlderError() async {
        let probe = FolderEnqueueProbe()
        await probe.fail("first")
        let manager = UploadManager(uploader: MockUploader(deliverProgress: false))
        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: .sdkUploader,
            canCreateAlbum: false,
            canAddToAlbum: false,
            canSetAlbumCover: false,
            folderEnqueueOperation: { url, _ in
                try await probe.run(url: url)
                return []
            }
        )

        coordinator.chooseDestination(folder: URL(fileURLWithPath: "/first"))
        coordinator.confirm(destination: .library)
        while true {
            let snapshot = await probe.snapshot()
            if snapshot.started.count >= 1 { break }
            await Task.yield()
        }
        await probe.releaseFirst()
        while coordinator.latestFolderEnumerationError == nil {
            await Task.yield()
        }

        coordinator.chooseDestination(folder: URL(fileURLWithPath: "/second"))
        coordinator.confirm(destination: .library)
        XCTAssertNil(coordinator.latestFolderEnumerationError)
        while true {
            let snapshot = await probe.snapshot()
            if snapshot.started.count >= 2 { break }
            await Task.yield()
        }

        let result = await probe.snapshot()
        XCTAssertEqual(result.started, ["first", "second"])
    }
}
