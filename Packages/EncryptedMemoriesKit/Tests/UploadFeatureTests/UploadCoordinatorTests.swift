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
