import Foundation
import PhotosCore
import SQLite3
import UploadCore
import XCTest

final class ManualUploadRetryEligibilityTests: XCTestCase {
    func testLibraryTerminalWriteFailureHidesRetryAndRecoversAfterRestart() async throws {
        try await terminalWriteFailure(destination: .library)
    }

    func testAlbumTerminalWriteFailureHidesRetryAndRecoversAfterRestart() async throws {
        try await terminalWriteFailure(
            destination: UploadDestination(target: .existingAlbum(id: "album", title: "Album")))
    }

    func testPendingManifestSettlementKeepsRetry() async throws {
        try await pendingFailure(failsAlbum: false)
    }

    func testPendingAlbumSettlementKeepsRetry() async throws {
        try await pendingFailure(failsAlbum: true)
    }

    private func pendingFailure(failsAlbum: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let store = try XCTUnwrap(
            UploadManualSettlementStore(
                url: directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)))
        defer { store.close() }
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        if !failsAlbum { resolver.recordErrorsByFilename["photo.jpg"] = UploadError.backend("Manifest unavailable") }
        let destination: UploadDestination =
            failsAlbum ? .init(target: .existingAlbum(id: "album", title: "Album")) : .library
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(failAdd: failsAlbum), identityResolver: resolver,
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(files, destination: destination)
        let items = await waitForAllTerminal(manager)
        let item = try XCTUnwrap(items.first)
        guard case .failed = item.state else {
            await manager.shutdown()
            return XCTFail("The remaining settlement step must fail before checking Retry")
        }
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [.retry])
        XCTAssertTrue(try XCTUnwrap(store.record(for: try XCTUnwrap(ids.first))).isPending)
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(uploader.requests.count, 1)
        await manager.shutdown()
    }

    private func terminalWriteFailure(destination: UploadDestination) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeTempFiles(["photo.jpg"], in: directory)
        let databaseURL = directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        let store = try XCTUnwrap(UploadManualSettlementStore(url: databaseURL))
        defer { store.close() }
        try execute(
            """
            CREATE TRIGGER refuse_terminal_update
            BEFORE UPDATE ON manual_upload_settlement WHEN NEW.stage = 'terminal'
            BEGIN SELECT RAISE(FAIL, 'terminal write refused'); END;
            """, at: databaseURL)
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: resolver,
            settlementStore: store, requiresDurableSettlement: true, maxConcurrent: 1)
        let coordinator = await MainActor.run {
            UploadCoordinator(
                manager: manager, uploadCapabilities: uploader.capabilities,
                canCreateAlbum: false, canAddToAlbum: true, canSetAlbumCover: false)
        }
        await coordinator.start()
        let ids = await manager.enqueueFiles(files, destination: destination)
        let id = try XCTUnwrap(ids.first)
        let message: String
        if case .library = destination.target {
            message = "Manual upload settlement could not be persisted."
        } else {
            message = try XCTUnwrap(
                UploadError.albumStep("Manual album settlement could not be persisted.").errorDescription)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var items = await manager.snapshot()
        while items.first?.state != .failed(message: message), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            items = await manager.snapshot()
        }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.state, .failed(message: message), "Wait for the exact terminal-write failure")
        XCTAssertNotNil(item.uploadedUID)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.recordedUploads.count, 1)
        XCTAssertFalse(store.isOperational())
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [])
        let deliveryDeadline = ContinuousClock.now + .seconds(5)
        while await coordinator.items.first?.state != item.state, ContinuousClock.now < deliveryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let published = await coordinator.items
        XCTAssertEqual(published, items, "The upload list receives the failed snapshot")

        // Removing the injected fault restores SQLite writes, but not this store's failed connection.
        try execute("DROP TRIGGER refuse_terminal_update;", at: databaseURL)
        for _ in 0..<3 {
            await manager.resumeAll()
            try await Task.sleep(for: .milliseconds(20))
        }
        await manager.retry(id)

        let afterRetry = await manager.snapshot()
        XCTAssertEqual(afterRetry, items, "The existing Retry returns without changing the failed row")
        XCTAssertEqual(uploader.requests.count, 1, "Committed bytes must never upload again")
        XCTAssertEqual(resolver.recordedUploads.count, 1)
        await manager.shutdown()

        let reopened = try XCTUnwrap(UploadManualSettlementStore(url: databaseURL))
        defer { reopened.close() }
        let saved = try XCTUnwrap(reopened.record(for: id))
        XCTAssertTrue(saved.isPending, "The last successful write on disk still carries the pending receipt")
        XCTAssertNil(saved.terminalState)
        XCTAssertEqual(saved.uploadedUID, item.uploadedUID)
        let replay = UploadManager(
            uploader: uploader, albums: MockAlbumAttaching(), identityResolver: FakeIdentityResolver(),
            settlementStore: reopened, requiresDurableSettlement: true, maxConcurrent: 1)
        let started = ContinuousClock.now
        var recovered = await replay.snapshot()
        XCTAssertEqual(recovered.first?.state, .finalizing)
        let recoveryDeadline = started + .seconds(5)
        while recovered.first?.state != .completed, ContinuousClock.now < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(5))
            recovered = await replay.snapshot()
        }
        XCTAssertEqual(recovered.first?.state, .completed)
        XCTAssertEqual(recovered.first?.uploadedUID, item.uploadedUID)
        XCTAssertEqual(reopened.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requests.count, 1, "Restart recovery settles only the receipt")
        print("Terminal-write recovery: \(destination.target); elapsed \(started.duration(to: .now)); uploads 1")
        await replay.shutdown()
    }

    private func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open(url.path, &handle)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(opened, SQLITE_OK)
        guard opened == SQLITE_OK else { throw UploadError.backend("Test database did not open") }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK)
        guard result == SQLITE_OK else { throw UploadError.backend("Test database setup failed") }
    }
}
