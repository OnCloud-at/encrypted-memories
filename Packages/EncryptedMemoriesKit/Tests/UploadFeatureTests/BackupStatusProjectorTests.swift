import Foundation
import XCTest

@testable import UploadCore

final class BackupStatusProjectorTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BackupStatusProjection] = []

        func append(_ projection: BackupStatusProjection) {
            lock.withLock { storage.append(projection) }
        }

        var values: [BackupStatusProjection] {
            lock.withLock { storage }
        }
    }

    private var tempDirectory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-status-projector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDirectory.appendingPathComponent("queue.sqlite")
            ))
    }

    override func tearDownWithError() throws {
        queue?.close()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testStartProjectsDurableQueueTruth() async throws {
        XCTAssertTrue(queue.upsert(entry(id: "durable", state: .discovered)))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext()
        ) { projection in
            recorder.append(projection)
        }

        let projection = try XCTUnwrap(recorder.values.last)
        XCTAssertEqual(projection.generation, generation)
        XCTAssertEqual(projection.progress.total, 1)
        XCTAssertEqual(projection.progress.waiting, 1)
        XCTAssertEqual(projection.status.phase, .waiting)
        await projector.stop()
    }

    func testStaleGenerationIsDiscarded() async throws {
        XCTAssertTrue(queue.upsert(entry(id: "generation", state: .discovered)))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }
        let initialCount = recorder.values.count

        var progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.currentItemName = "current.heic"
        projector.submit(progress, generation: UUID())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.values.count, initialCount)

        projector.submit(progress, generation: generation)
        let accepted = await waitUntil {
            recorder.values.last?.progress.currentItemName == "current.heic"
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(recorder.values.last?.progress.currentItemName, "current.heic")
        await projector.stop()
    }

    func testCountTicksCoalesceButTerminalStatePublishesImmediately() async throws {
        let row = entry(id: "coalesce", state: .discovered)
        XCTAssertTrue(queue.upsert(row))
        let projector = BackupStatusProjector(queue: queue, coalescingInterval: 0.15)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }

        var progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.currentItemName = "tick-0"
        projector.submit(progress, generation: generation)
        let becameActive = await waitUntil {
            recorder.values.last?.progress.currentItemName == "tick-0"
        }
        XCTAssertTrue(becameActive)
        let countAfterPhaseChange = recorder.values.count

        for index in 1...50 {
            progress.currentItemName = "tick-\(index)"
            progress.activeExecutionItemEquivalents = Double(index) / 100
            projector.submit(progress, generation: generation)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let afterTicks = recorder.values
        XCTAssertLessThanOrEqual(afterTicks.count, countAfterPhaseChange + 2)
        XCTAssertEqual(afterTicks.last?.progress.currentItemName, "tick-50")

        XCTAssertTrue(
            queue.updateState(
                source: row.source,
                revision: row.revision,
                state: .completed,
                attempts: 0,
                lastError: nil,
                updatedAt: Date()
            ))
        progress.isRunning = false
        progress.waiting = 0
        progress.uploaded = 1
        projector.submit(progress, generation: generation)
        _ = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: false),
            generation: generation,
            revision: 1
        )
        let becameTerminal = await waitUntil {
            recorder.values.last?.status.phase == .completed
        }
        XCTAssertTrue(becameTerminal)
        XCTAssertEqual(recorder.values.last?.progress.uploaded, 1)
        await projector.stop()
    }

    func testTerminalQueueClearsStaleTransferWhileControllerRunFinishes() async throws {
        let row = entry(id: "terminal-tail", state: .uploading)
        XCTAssertTrue(queue.upsert(row))
        let projector = BackupStatusProjector(queue: queue, coalescingInterval: 0)
        let generation = UUID()
        let recorder = Recorder()

        await projector.start(
            generation: generation,
            context: BackupStatusProjectionContext(isRunning: true)
        ) { projection in
            recorder.append(projection)
        }

        var live = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        live.activeTransfer = BackupActiveTransferProgress(
            activeItemCount: 1,
            completedBytes: 75,
            totalBytes: 100,
            completedItemEquivalents: 0.75
        )
        live.activeExecutionItemEquivalents = 0.75
        projector.submit(live, generation: generation)
        let transferPublished = await waitUntil { recorder.values.last?.progress.activeTransfer != nil }
        XCTAssertTrue(transferPublished)

        XCTAssertTrue(
            queue.updateState(
                source: row.source,
                revision: row.revision,
                state: .completed,
                attempts: 0,
                lastError: nil,
                updatedAt: Date()
            ))
        let projected = await projector.projectNow(
            context: BackupStatusProjectionContext(isRunning: true),
            generation: generation,
            revision: 1
        )
        let terminal = try XCTUnwrap(projected)

        XCTAssertEqual(terminal.progress.uploaded, 1)
        XCTAssertNil(terminal.progress.activeTransfer)
        XCTAssertEqual(terminal.progress.activeExecutionItemEquivalents, 0)
        XCTAssertEqual(terminal.status.phase, .completed)
        XCTAssertFalse(terminal.status.isActive)
        await projector.stop()
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func entry(
        id: String,
        state: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: id,
                resource: .primary
            ),
            revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: 42)),
            originalFilename: "\(id).heic",
            state: state,
            updatedAt: Date()
        )
    }
}
