import AlbumSyncCore
import Foundation
import Photos
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class AlbumSyncPhotoRecoveryControllerTests: XCTestCase {
    func testExplicitRestoreUsesTheControllerAndLeavesSettlementToNextSync() async throws {
        try await withFixture { fixture in
            let before = fixture.device.server.uploadRequestCount
            let journal = fixture.device.journal.entry(for: fixture.problem.source!)
            let result = try await fixture.restore()
            XCTAssertEqual(result, .restored)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .active)
            let related = fixture.device.server.links.filter { $0.mainLinkID == fixture.original.nodeID }
            XCTAssertEqual(related.count, 1)
            XCTAssertTrue(related.allSatisfy { $0.state == .active })
            let restored = try await fixture.device.syncAlbum(["asset-1"], backup: fixture.backup)
            XCTAssertTrue(restored.isFullySynced)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertTrue(restored.problems.isEmpty)
        }
    }

    func testStopCancelsHeldEvidenceAndRejectsRepeatedActionUntilItEnds() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                let repeatedFinished = XCTestExpectation(description: "Repeated action refused")
                let repeated = Task {
                    do {
                        _ = try await fixture.restore()
                        XCTFail("A second action must not start")
                    } catch {}
                    repeatedFinished.fulfill()
                }
                await fulfillment(of: [repeatedFinished], timeout: 5)
                fixture.controller.stopSync()
                await fulfillment(of: [gate.cancelled], timeout: 5)
                let stoppedFinished = XCTestExpectation(description: "Stopped action refused")
                let stopped = Task {
                    do {
                        _ = try await fixture.restore()
                        XCTFail("Stop must keep ownership until the lookup ends")
                    } catch {}
                    stoppedFinished.fulfill()
                }
                await fulfillment(of: [stoppedFinished], timeout: 5)
                await gate.release()
                await repeated.value
                await stopped.value
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testSourceChangeDuringEvidenceRejectsTheOldVersion() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.device.library.changeModificationDate()
                await gate.release()
                do {
                    _ = try await task.value
                    XCTFail("Changed source must not restore")
                } catch {}
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testNewProblemGenerationCancelsAnOldActionEvenForTheSameRows() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.recordFinishedRun(
                    fixture.report.problems, albumID: "local-album",
                    recoveryContext: fixture.remote.context)
                await gate.release()
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testDeselectCancelsAnOldAction() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.removeFromSelection("local-album")
                await gate.release()
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testShutdownCancelsAndWaitsForHeldEvidence() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "Shutdown must join the held operation")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                await shutdown.value
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testResponseLossDoesNotSettleAndRetryReadsFreshActiveState() async throws {
        try await withFixture { fixture in
            fixture.device.server.applyNextRestoreThenFail()
            do {
                _ = try await fixture.restore()
                XCTFail("Response loss must remain an error")
            } catch {}
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
            let before = fixture.device.server.uploadRequestCount
            let result = try await fixture.restore()
            XCTAssertEqual(result, .alreadyActive)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
        }
    }

    func testCachedProblemWithoutThisSessionContextCannotRestore() async throws {
        try await withFixture { fixture in
            fixture.controller.recordFinishedRun(fixture.report.problems, albumID: "local-album")
            do {
                _ = try await fixture.restore()
                XCTFail("Cached presentation is not authority")
            } catch {}
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testStopDuringProblemContextReadDoesNotStartSync() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.stopSync()
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while fixture.controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
                XCTAssertFalse(fixture.controller.isSyncing)
                XCTAssertEqual(source.reads, 0, "Stop must fence the new context await before the runner starts")
            })
    }

    func testContextReadCancellationDoesNotStartSync() async throws {
        let errors: [any Error] = [
            CancellationError(), UploadError.cancelled,
            URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled"),
        ]
        for error in errors {
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: { throw error }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await waitForSync(fixture.controller)
                    XCTAssertEqual(source.reads, 0, "Context cancellation must not become optional evidence")
                })
        }
    }

    func testOrdinaryContextReadFailureAllowsSyncButCannotAuthorizeRestore() async throws {
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { throw URLError(.notConnectedToInternet) }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await waitForSync(fixture.controller)
                XCTAssertEqual(source.reads, 1, "An optional recovery context must not prevent normal sync")
                do {
                    _ = try await fixture.restore()
                    XCTFail("Failed context cannot authorize Restore")
                } catch {}
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testShutdownJoinsHeldProblemContextRead() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "Shutdown must join the context read")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                XCTAssertTrue(fixture.controller.isSyncing, "The batch owns the context read until it returns")
                await gate.release()
                await shutdown.value
                XCTAssertEqual(source.reads, 0)
            })
    }

    func testNonDeletionProblemCannotAuthorizeRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: "Unknown",
                isPermanent: false, issue: .unknown, source: fixture.problem.source,
                revision: fixture.problem.revision)
            fixture.controller.recordFinishedRun(
                [item], albumID: "local-album", recoveryContext: fixture.remote.context)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("Only a current deletion problem can authorize Restore")
            } catch {}
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testChangedProblemCannotAuthorizeRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: "Changed",
                isPermanent: false, issue: .remoteDeletion, source: fixture.problem.source,
                revision: fixture.problem.revision)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("An old problem must not authorize Restore")
            } catch {}
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    private func waitForSync(_ controller: AlbumSyncController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(controller.isSyncing)
    }

    private func assertCancelled(_ task: Task<AlbumSyncPhotoRecovery.Result, any Error>) async {
        switch await task.result {
        case .success: XCTFail("Cancelled action must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError || UploadError.isCancellation(error))
        }
    }

    private func withFixture(
        onEvidence: @escaping @Sendable () async -> Void = {},
        onContext: @escaping @Sendable () async throws -> Void = {},
        localSource: any AlbumSyncLocalAlbumSource = EditScenarioAlbumSource(identifiers: ["asset-1"]),
        body: (RecoveryControllerFixture) async throws -> Void
    ) async throws {
        let fixture = try await RecoveryControllerFixture(
            onEvidence: onEvidence, onContext: onContext, localSource: localSource)
        defer { try? fixture.device.cleanup() }
        do { try await body(fixture) } catch {
            await fixture.controller.shutdown()
            throw error
        }
        await fixture.controller.shutdown()
    }
}

struct RecoveryScenarioResolver: BackupResourceResolving {
    let library: EditScenarioLibrary
    let now: Date
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await library.resolve(entry, now: now)
    }
}

struct RecoveryScenarioRemote: AlbumSyncRemoteAlbumOps {
    let server: EditScenarioServer
    let context = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "vol", hashKeyEpoch: "scenario-epoch")
    var onEvidence: @Sendable () async -> Void = {}
    var onContext: @Sendable () async throws -> Void = {}
    func photoRecoveryContext() async throws -> AlbumSyncPhotoRecovery.Context? {
        try await onContext()
        return context
    }
    func photoRecoveryState(for record: UploadIdentityRecord) async throws -> AlbumSyncPhotoRecovery.RemoteState {
        await onEvidence()
        guard let link = record.remoteLinkID else { return .unavailable }
        let snapshot = try await server.linkStateSnapshot(of: [link])
        guard snapshot.complete else { return .unavailable }
        switch snapshot.states[link] {
        case 2: return .trashed
        case 1: return .active
        default: return .unavailable
        }
    }
    func restorePhoto(
        _ uid: PhotoUID, context: AlbumSyncPhotoRecovery.Context,
        validate: @Sendable () async throws -> Void
    ) async throws {
        try await validate()
        try await server.restoreDuplicates([uid])
    }
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { try await server.listAlbums() }
    func createAlbum(name: String) async throws -> String { try await server.createAlbum(name: name) }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await server.childMainLinkIDs(albumID: albumID)
    }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        try await server.attach(photos, albumID: albumID)
    }
}

@MainActor
private struct RecoveryControllerFixture {
    // The fixture calls this harness sequentially, before or after the owned Restore task.
    nonisolated(unsafe) let device: EditScenarioHarness
    let original: PhotoUID
    let backup: EditScenarioAlbumBackup
    let report: AlbumSyncReport
    let problem: BackupFailedItem
    let controller: AlbumSyncController
    let remote: RecoveryScenarioRemote

    init(
        onEvidence: @escaping @Sendable () async -> Void,
        onContext: @escaping @Sendable () async throws -> Void,
        localSource: any AlbumSyncLocalAlbumSource
    ) async throws {
        device = try EditScenarioHarness(live: true)
        try await device.enqueue()
        await device.drain()
        original = try device.liveMain()
        device.server.personTrash(original)
        backup = EditScenarioAlbumBackup(device: device)
        report = try await device.syncAlbum(["asset-1"], backup: backup)
        problem = try XCTUnwrap(report.problems.first)
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(
                url: device.directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        XCTAssertTrue(mapping.addSelection(.init(localAlbumID: "local-album", title: "Album", addedAt: .distantPast)))
        mapping.close()
        remote = RecoveryScenarioRemote(server: device.server, onEvidence: onEvidence, onContext: onContext)
        var configuration = AlbumSyncController.Configuration(
            accountDataDirectory: device.directory, databasePolicy: .conservative)
        configuration.currentAccessState = { .full }
        configuration.localSource = localSource
        let library = device.library
        configuration.recoveryCatalog = { _ in library }
        configuration.makeChangeMonitor = { url in
            PhotoLibraryChangeMonitor(
                tokenURL: url,
                operations: .init(
                    fetch: { PHFetchResult<PHAsset>() }, register: { _ in }, unregister: { _ in }))
        }
        configuration.recoveryResourceResolver = RecoveryScenarioResolver(
            library: device.library, now: device.clock.now)
        configuration.changeSleep = { _ in try await Task.sleep(nanoseconds: UInt64.max) }
        controller = AlbumSyncController(
            configuration: configuration, identityResolver: device.identityResolver,
            uploader: device.deviceRemote, remoteOps: remote)
        controller.recordFinishedRun(report.problems, albumID: "local-album", recoveryContext: remote.context)
    }

    func restore() async throws -> AlbumSyncPhotoRecovery.Result {
        try await controller.restorePhoto(problem, albumID: "local-album")
    }
}

private actor RecoveryGate {
    nonisolated let entered = XCTestExpectation(description: "Evidence started")
    nonisolated let cancelled = XCTestExpectation(description: "Evidence cancelled")
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var finished = false
    func wait() async {
        entered.fulfill()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if open { continuation.resume() } else { self.continuations.append(continuation) }
            }
        } onCancel: {
            cancelled.fulfill()
        }
        finished = true
    }
    func release() {
        open = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

private final class RecoveryCountingSource: AlbumSyncLocalAlbumSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        lock.withLock { count += 1 }
        throw CancellationError()
    }
}
