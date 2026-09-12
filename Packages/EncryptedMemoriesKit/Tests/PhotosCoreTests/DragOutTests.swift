import Foundation
import XCTest
import os

@testable import PhotosCore

final class DragOutTests: XCTestCase {
    // MARK: - Fixtures

    private func uid(_ n: Int) -> PhotoUID {
        PhotoUID(volumeID: "vol", nodeID: "node-\(n)")
    }

    private func item(_ n: Int) -> PhotoItem {
        PhotoItem(
            uid: uid(n),
            captureTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
            mediaType: "image/jpeg"
        )
    }

    private var stagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DragOutTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Fake `OriginalFileProvider`: writes a temp file at the given destination, records
    /// concurrent-write peaks, and reports progress in bounded chunks.
    private final class FakeFileProvider: OriginalFileProvider, @unchecked Sendable {
        let bytes: Int
        let chunkDelay: UInt64
        private let peak = PeakCounter()

        init(bytes: Int, chunkDelay: UInt64 = 0) {
            self.bytes = bytes
            self.chunkDelay = chunkDelay
        }

        var peakConcurrent: Int { peak.value }

        func writeOriginal(
            for uid: PhotoUID,
            to destination: URL,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            peak.enter()
            defer { peak.leave() }

            FileManager.default.createFile(atPath: destination.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: destination) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { try? handle.close() }

            let chunk = 4 * 1024
            let payload = Data(repeating: 0xAB, count: chunk)
            var written = 0
            while written < bytes {
                try Task.checkCancellation()
                try handle.write(contentsOf: payload)
                written += payload.count
                onProgress(Double(min(written, bytes)) / Double(bytes))
                if chunkDelay > 0 {
                    try? await Task.sleep(nanoseconds: chunkDelay)
                }
            }
        }
    }

    /// Synchronous atomic counter (no NSLock inside async contexts).
    private final class PeakCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: CounterState())

        var value: Int { lock.withLock { $0.peak } }

        func enter() {
            lock.withLock { $0.enter() }
        }

        func leave() {
            lock.withLock { $0.leave() }
        }

        private struct CounterState {
            var current = 0
            var peak = 0

            mutating func enter() {
                current += 1
                peak = max(peak, current)
            }

            mutating func leave() {
                current -= 1
            }
        }
    }

    private func stagedFiles(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    override func tearDown() {
        super.tearDown()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragOutTests", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Preflight policy

    func testPreflightAllowsWhenSizePlusMarginFits() {
        let decision = DragOutPolicy.preflight(totalKnownBytes: 1000, freeDiskBytes: 10_000, safetyMarginBytes: 500)
        XCTAssertTrue(decision.isAllowed)
        XCTAssertNil(decision.blockReason)
        XCTAssertEqual(decision.totalKnownBytes, 1000)
    }

    func testPreflightBlocksWhenSizePlusMarginExceedsFree() {
        let decision = DragOutPolicy.preflight(totalKnownBytes: 10_000, freeDiskBytes: 10_000, safetyMarginBytes: 1)
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.blockReason, .insufficientDiskSpace(requiredIncludingMargin: 10_001, available: 10_000))
    }

    func testPreflightAllowsUnknownSizesRegardlessOfFreeDisk() {
        let decision = DragOutPolicy.preflight(totalKnownBytes: nil, freeDiskBytes: 0, safetyMarginBytes: 500)
        XCTAssertTrue(decision.isAllowed)
        XCTAssertNil(decision.blockReason)
        XCTAssertNil(decision.totalKnownBytes)
    }

    // MARK: - Staging success

    func testBeginPreflightStagesFilesWithUniqueNamesAndNoDownloadSuffix() async throws {
        let directory = stagingDirectory
        let provider = FakeFileProvider(bytes: 32)
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 0)

        let decision = await stager.beginPrefetch(items: [item(1), item(2)])
        XCTAssertTrue(decision.isAllowed)

        let first = try await stager.awaitStaged(uid: uid(1)).get()
        let second = try await stager.awaitStaged(uid: uid(2)).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertFalse(first.pathExtension == "download")
        XCTAssertFalse(second.pathExtension == "download")
        XCTAssertTrue(first.path.hasPrefix(directory.path))

        await stager.finishAndCleanup()
    }

    func testProgressHandlerReachesOneMonotonically() async throws {
        let directory = stagingDirectory
        let provider = FakeFileProvider(bytes: 64 * 1024)
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 0)

        let recorder = ProgressRecorder()
        await stager.setProgressHandler(recorder.handler)
        _ = await stager.beginPrefetch(items: [item(3)])
        _ = try await stager.awaitStaged(uid: uid(3)).get()
        await stager.setProgressHandler(nil)
        await stager.finishAndCleanup()

        let fractions = await recorder.fractions()
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last, 1.0)
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b + 1e-9, "progress must be non-decreasing")
        }
    }

    // MARK: - Disk-space failure

    func testBeginPreflightSurfacesDiskSpaceFailureForKnownOversizedItems() async throws {
        let directory = stagingDirectory
        // 512 MiB fake size vs a 128 KiB safety margin: preflight must refuse and never write.
        let provider = OversizedFakeProvider(sizeBytes: 512 * 1024 * 1024)
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 128 * 1024)

        let decision = await stager.beginPrefetch(items: [item(4)])
        XCTAssertFalse(decision.isAllowed)
        let result = await stager.awaitStaged(uid: uid(4))
        guard case .failure(.diskSpaceInsufficient(let required, let available)) = result else {
            return XCTFail("expected .diskSpaceInsufficient, got \(result)")
        }
        XCTAssertEqual(required, 512 * 1024 * 1024 + 128 * 1024)
        XCTAssertGreaterThanOrEqual(available, 0, "real staging-volume free space (0 possible on exotic volumes)")
        XCTAssertEqual(stagedFiles(in: directory), [])
        await stager.finishAndCleanup()
    }

    /// Fakes the size seam (so preflight sees a huge known size); free space comes from the
    /// real staging volume, which is many orders of magnitude below the fake 512 MiB size.
    private final class OversizedFakeProvider: OriginalFileProvider, SizedOriginalFileProvider,
        @unchecked Sendable
    {
        let sizeBytes: Int

        init(sizeBytes: Int) { self.sizeBytes = sizeBytes }

        func size(of uid: PhotoUID) -> Int? { sizeBytes }

        func writeOriginal(
            for uid: PhotoUID,
            to destination: URL,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - Cancellation

    func testCancelAllFailsAwaitStagedWithCancelled() async throws {
        let directory = stagingDirectory
        let provider = SlowFileProvider()
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 0)

        _ = await stager.beginPrefetch(items: [item(5)])

        // Wait until the write actually started, then cancel everything.
        _ = await provider.started.first { _ in true }
        await stager.cancelAll()

        let result = await stager.awaitStaged(uid: uid(5))
        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testFinishAndCleanupSparesDeliveredAndDeletesOthers() async throws {
        let directory = stagingDirectory
        let provider = FakeFileProvider(bytes: 32)
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 0)

        _ = await stager.beginPrefetch(items: [item(6), item(7)])
        let deliveredURL = try await stager.awaitStaged(uid: uid(6)).get()
        _ = try await stager.awaitStaged(uid: uid(7)).get()

        await stager.markDelivered(uid: uid(6))
        await stager.finishAndCleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: deliveredURL.path), "marked-delivered file must survive")
        let remaining = stagedFiles(in: directory)
        XCTAssertEqual(remaining, [deliveredURL.lastPathComponent])
    }

    // MARK: - Concurrency cap

    func testPeakConcurrentWritesRespectCap() async throws {
        let directory = stagingDirectory
        let provider = FakeFileProvider(bytes: 8 * 1024, chunkDelay: 5_000_000)
        let stager = DragOutStager(fileProvider: provider, stagingDirectory: directory, safetyMarginBytes: 0)

        let items = (1...6).map { item($0 + 10) }
        _ = await stager.beginPrefetch(items: items)
        for entry in items {
            _ = try await stager.awaitStaged(uid: entry.uid).get()
        }
        await stager.finishAndCleanup()

        XCTAssertLessThanOrEqual(provider.peakConcurrent, 2, "peak writes must respect maxConcurrentWrites=2")
    }
}

// MARK: - Test helpers

/// Records progress callbacks thread-safely.
private actor ProgressRecorder {
    private var recorded: [Double] = []

    var handler: @Sendable (PhotoUID, Double) -> Void {
        { [weak self] _, fraction in
            Task { await self?.append(fraction) }
        }
    }

    private func append(_ fraction: Double) {
        recorded.append(fraction)
    }

    func fractions() -> [Double] {
        recorded
    }
}

/// Signals once its write started, then sleeps until cancelled.
private final class SlowFileProvider: OriginalFileProvider, @unchecked Sendable {
    private let startedContinuation: AsyncStream<Void>.Continuation
    let started: AsyncStream<Void>

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { c in continuation = c }
        self.startedContinuation = continuation
        self.started = stream
    }

    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        startedContinuation.yield(())
        startedContinuation.finish()
        try await Task.sleep(nanoseconds: 60_000_000_000)  // hangs until cancelled
        throw CocoaError(.fileWriteUnknown)
    }
}
