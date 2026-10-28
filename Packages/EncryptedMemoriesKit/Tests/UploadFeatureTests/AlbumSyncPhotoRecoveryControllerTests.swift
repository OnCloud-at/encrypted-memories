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
                    } catch {
                        XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                    }
                    repeatedFinished.fulfill()
                }
                await fulfillment(of: [repeatedFinished], timeout: 5)
                fixture.controller.stopSync()
                XCTAssertTrue(gate.wasCancelled, "Stop must cancel the owned task")
                await fulfillment(of: [gate.cancelled], timeout: 5)
                let stoppedFinished = XCTestExpectation(description: "Stopped action refused")
                let stopped = Task {
                    do {
                        _ = try await fixture.restore()
                        XCTFail("Stop must keep ownership until the lookup ends")
                    } catch {
                        XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                    }
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
                } catch {
                    XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                }
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

    func testShutdownCancelsHeldEvidenceAndRetainsOwnership() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "The released evidence has finished at this observation")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                XCTAssertTrue(gate.wasCancelled, "Shutdown must cancel the owned task")
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
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
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
                XCTAssertTrue(gate.wasCancelled, "Stop must cancel the owned task")
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while fixture.controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
                XCTAssertFalse(fixture.controller.isSyncing)
                XCTAssertEqual(source.reads, 0, "Stop must fence the new context await before the runner starts")
                XCTAssertEqual(fixture.controller.lastMessageStyle, .information)
                XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_stopped"))
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

    func testOrdinaryContextReadFailureFinishesSyncAndClearsRestoreAuthority() async throws {
        let source = RecoveryBatchSource()
        source.includeAsset()
        let contextReads = RecoveryContextReads()
        try await withFixture(
            onContext: { try await contextReads.failFirstRead() }, localSource: source,
            seedPreviousProblem: true,
            configure: { configuration, device in
                configuration.backupExecutorOverride = EditScenarioAlbumBackup(device: device)
            },
            body: { fixture in
                let uploads = fixture.device.server.uploadRequestCount
                let journal = fixture.device.journal.entry(for: fixture.problem.source!)
                fixture.controller.syncNow(albumID: "local-album")
                let item = try await finishedDeletionProblem(fixture)
                XCTAssertNil(fixture.controller.lastMessage, "An ordinary context error must not stop normal sync")
                let reads = await contextReads.count
                XCTAssertEqual(reads, 1, "The completed run must attempt its context read")
                guard await assertUnavailable(fixture, item: item) else { return }
                let readsAfterRefusal = await contextReads.count
                XCTAssertEqual(readsAfterRefusal, reads, "Missing context must refuse before a fresh remote read")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)

                try await assertFreshSyncRestores(fixture)
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
            })
    }

    func testPickerRemovalAndReselectionCannotReuseAnInFlightContext() async throws {
        try await checkRemovalDuringCompletingSync(usePicker: true)
    }

    func testRowRemovalAndReselectionCannotReuseAnInFlightContext() async throws {
        try await checkRemovalDuringCompletingSync(usePicker: false)
    }

    private func checkRemovalDuringCompletingSync(usePicker: Bool) async throws {
        for reselectBeforeCompletion in [true, false] {
            let gate = RecoveryGate()
            let source = RecoveryBatchSource(onFirstRead: { await gate.wait() })
            source.includeAsset()
            try await withFixture(
                localSource: source, automaticBatch: true, seedPreviousProblem: true,
                configure: { configuration, device in
                    configuration.backupExecutorOverride = EditScenarioAlbumBackup(device: device)
                },
                body: { fixture in
                    await fulfillment(of: [gate.entered], timeout: 5)
                    let selection = fixture.controller.selectedAlbumIDs
                    let uploads = fixture.device.server.uploadRequestCount
                    let journal = fixture.device.journal.entry(for: fixture.problem.source!)
                    if usePicker {
                        fixture.controller.applySelection(selection.subtracting(["local-album"]))
                    } else {
                        fixture.controller.removeFromSelection("local-album")
                    }
                    XCTAssertFalse(fixture.controller.selectedAlbumIDs.contains("local-album"))
                    if reselectBeforeCompletion { fixture.controller.applySelection(selection) }
                    await gate.release()
                    await waitForSync(fixture.controller)
                    if !reselectBeforeCompletion { fixture.controller.applySelection(selection) }
                    XCTAssertEqual(fixture.controller.selectedAlbumIDs, selection)
                    let item = try await finishedDeletionProblem(fixture)
                    XCTAssertNil(fixture.controller.lastMessage, "Removal must not interrupt the running sync")
                    guard await assertUnavailable(fixture, item: item) else { return }
                    XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                    XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)

                    try await assertFreshSyncRestores(fixture)
                    XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                    XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
                })
        }
    }

    func testShutdownCancelsHeldProblemContextReadAndKeepsTheBatchOwned() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    XCTAssertFalse(
                        fixture.controller.isSyncing, "Shutdown must wait for the active sync task to finish")
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "The released context read has finished at this observation")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                XCTAssertTrue(fixture.controller.isSyncing, "The batch owns the context read until it returns")
                await gate.release()
                await shutdown.value
                XCTAssertEqual(source.reads, 0)
                XCTAssertNil(
                    fixture.controller.lastMessage,
                    "Shutdown must not turn a late context return into an error")
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
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
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
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testAddingSelectionDuringContextReadKeepsTheRunningBatch() async throws {
        try await checkSelectionDuringContextRead(remove: false)
    }

    func testRemovingSelectionDuringContextReadKeepsTheOtherAlbums() async throws {
        try await checkSelectionDuringContextRead(remove: true)
    }

    private func checkSelectionDuringContextRead(remove: Bool, cancellationAware: Bool = false) async throws {
        let gate = RecoveryGate()
        let source = RecoveryBatchSource()
        try await withFixture(
            onContext: {
                await gate.wait()
                if cancellationAware { try Task.checkCancellation() }
            }, localSource: source, automaticBatch: true,
            body: { fixture in
                await fulfillment(of: [gate.entered], timeout: 5)
                if remove {
                    fixture.controller.removeFromSelection("removed-album")
                } else {
                    fixture.controller.applySelection(["local-album", "next-album", "removed-album", "added-album"])
                    XCTAssertTrue(fixture.controller.selectedAlbumIDs.contains("added-album"))
                }
                XCTAssertFalse(gate.wasCancelled, "Selection changes must not cancel a sync context read")
                await gate.release()
                await waitForSync(fixture.controller)
                XCTAssertEqual(
                    source.readAlbums.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } },
                    remove ? ["local-album", "next-album"] : ["local-album", "next-album", "removed-album"])
                XCTAssertNil(fixture.controller.lastMessage, "Selection changes must not report a sync error")
            })
    }

    func testStopDuringContextTransportCancellationShowsStop() async throws {
        let errors: [any Error] = [URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled")]
        for error in errors {
            let gate = RecoveryGate()
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: {
                    await gate.wait()
                    throw error
                }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await fulfillment(of: [gate.entered], timeout: 5)
                    fixture.controller.stopSync()
                    XCTAssertTrue(gate.wasCancelled, "Stop must cancel the context task synchronously")
                    await gate.release()
                    await waitForSync(fixture.controller)
                    XCTAssertEqual(source.reads, 0)
                    XCTAssertEqual(fixture.controller.lastMessageStyle, .information)
                    XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_stopped"))
                })
        }
    }

    func testSelectionDuringCancellationAwareContextReadKeepsTheBatch() async throws {
        try await checkSelectionDuringContextRead(remove: false, cancellationAware: true)
        try await checkSelectionDuringContextRead(remove: true, cancellationAware: true)
    }

    func testShutdownDuringContextTransportCancellationDoesNotShowAnError() async throws {
        let errors: [any Error] = [URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled")]
        for error in errors {
            let gate = RecoveryGate()
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: {
                    await gate.wait()
                    throw error
                }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await fulfillment(of: [gate.entered], timeout: 5)
                    let shutdown = Task { await fixture.controller.shutdown() }
                    await fulfillment(of: [gate.cancelled], timeout: 5)
                    XCTAssertTrue(gate.wasCancelled)
                    await gate.release()
                    await shutdown.value
                    XCTAssertEqual(source.reads, 0)
                    XCTAssertNil(fixture.controller.lastMessage, "Shutdown cancellation must not become an error line")
                })
        }
    }

    func testControllerInitSweepsAbandonedRestoreOriginals() async throws {
        try await withFixture(seedRestoreTemp: true) { fixture in
            let directory = fixture.device.directory.appendingPathComponent("album-sync-restore-temp")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            XCTAssertNotNil(fixture.device.identities.record(for: fixture.problem.source!))
        }
    }

    func testIdentityRecordChangeDuringEvidenceRejectsRestore() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                var record = try XCTUnwrap(fixture.device.identities.record(for: fixture.problem.source!))
                record.remoteLinkID = "another-link"
                XCTAssertTrue(fixture.device.identities.upsert(record))
                await gate.release()
                do {
                    _ = try await task.value
                    XCTFail("Changed identity must not restore the previous link")
                } catch {
                    XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                }
                assertTrashed(fixture)
            })
    }

    func testAssetOutsideTheAlbumCannotRestore() async throws {
        try await withFixture(localSource: EditScenarioAlbumSource(identifiers: [])) { fixture in
            await assertUnavailable(fixture)
        }
    }

    func testChangedProblemRevisionCannotRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: fixture.problem.reason,
                isPermanent: fixture.problem.isPermanent, issue: .remoteDeletion, source: fixture.problem.source,
                revision: .init(rawValue: -1))
            fixture.controller.recordFinishedRun(
                [item], albumID: "local-album", recoveryContext: fixture.remote.context)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("A different problem revision must not restore")
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            assertTrashed(fixture)
        }
    }

    func testPreparedResourceVersionMustMatchCatalog() async throws {
        try await withFixture(
            configure: { configuration, device in
                configuration.recoveryResourceResolver = RecoveryAlteredResolver(
                    library: device.library, now: device.clock.now)
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testMissingPreparedResourceCannotRestore() async throws {
        try await withFixture(
            configure: { configuration, device in
                configuration.recoveryResourceResolver = RecoveryAlteredResolver(
                    library: device.library, now: device.clock.now, missing: true)
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testMissingIdentityRecordCannotRestore() async throws {
        try await withFixture { fixture in
            fixture.device.identities.close()
            await assertUnavailable(fixture)
        }
    }

    func testDeniedLibraryAccessCannotRestore() async throws {
        try await withFixture(
            configure: { configuration, _ in
                configuration.currentAccessState = { .denied }
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testRestoreCannotStartWhileSyncIsRunning() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let refused = XCTestExpectation(description: "Restore refused during sync")
                let attempt = Task {
                    await assertUnavailable(fixture)
                    refused.fulfill()
                }
                await fulfillment(of: [refused], timeout: 5)
                XCTAssertEqual(
                    source.reads, 0, "Restore must not read the album while sync waits for context")
                fixture.controller.stopSync()
                await gate.release()
                await attempt.value
                await waitForSync(fixture.controller)
            })
    }

    func testRestoreCannotStartAfterShutdown() async throws {
        try await withFixture { fixture in
            await fixture.controller.shutdown()
            await assertUnavailable(fixture)
        }
    }

    func testQueuedSyncDoesNotStartDuringRecovery() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.syncNow(albumID: "local-album")
                XCTAssertFalse(fixture.controller.isSyncing, "Sync cannot start while recovery owns the action")
                fixture.controller.stopSync()
                await gate.release()
                await assertCancelled(task)
                await waitForSync(fixture.controller)
                assertTrashed(fixture)
            })
    }

    func testSelectionRemovalClearsContextBeforeReselection() async throws {
        for usePicker in [true, false] {
            let gate = RecoveryGate()
            let source = RecoveryBatchSource()
            try await withFixture(
                onContext: { await gate.wait() }, localSource: source, automaticBatch: true,
                body: { fixture in
                    await fulfillment(of: [gate.entered], timeout: 5)
                    await gate.release()
                    await waitForSync(fixture.controller)
                    source.includeAsset()
                    fixture.controller.recordFinishedRun(
                        fixture.report.problems, albumID: "local-album", recoveryContext: fixture.remote.context)
                    if usePicker {
                        fixture.controller.applySelection([])
                    } else {
                        fixture.controller.removeFromSelection("local-album")
                    }
                    fixture.controller.applySelection(["local-album"])
                    XCTAssertTrue(fixture.controller.selectedAlbumIDs.contains("local-album"))
                    await assertUnavailable(fixture)
                })
        }
    }

    @discardableResult
    private func assertUnavailable(_ fixture: RecoveryControllerFixture, item: BackupFailedItem? = nil) async -> Bool {
        var unavailable = false
        do {
            let result = try await fixture.controller.restorePhoto(item ?? fixture.problem, albumID: "local-album")
            XCTFail("Unavailable evidence must not report \(result)")
        } catch {
            XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            unavailable = (error as? AlbumSyncPhotoRecovery.Error) == .unavailable
        }
        assertTrashed(fixture)
        return unavailable
            && fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state == .trashed
    }

    private func finishedDeletionProblem(_ fixture: RecoveryControllerFixture) async throws -> BackupFailedItem {
        await waitForSync(fixture.controller)
        _ = try XCTUnwrap(
            fixture.controller.isSyncing ? nil : true, "The real executor must finish before checking Restore")
        let row = try XCTUnwrap(fixture.controller.selectedAlbums.first { $0.id == "local-album" })
        let problems = try XCTUnwrap(
            row.problems.contains(fixture.initialProblem) ? nil : row.problems,
            "A completed run must replace the previous problem")
        return try XCTUnwrap(
            problems.first { $0.issue == .remoteDeletion && $0.source == fixture.problem.source },
            "The completed run must report the current trashed photo")
    }

    private func assertFreshSyncRestores(_ fixture: RecoveryControllerFixture) async throws {
        fixture.controller.syncNow(albumID: "local-album")
        let item = try await finishedDeletionProblem(fixture)
        let result = try await fixture.controller.restorePhoto(item, albumID: "local-album")
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .active)
    }

    private func assertTrashed(_ fixture: RecoveryControllerFixture) {
        XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
    }

    private func waitForSync(_ controller: AlbumSyncController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(controller.isSyncing, "Sync completion deadline exceeded")
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
        automaticBatch: Bool = false, seedRestoreTemp: Bool = false, seedPreviousProblem: Bool = false,
        configure: (inout AlbumSyncController.Configuration, EditScenarioHarness) -> Void = { _, _ in },
        body: (RecoveryControllerFixture) async throws -> Void
    ) async throws {
        let fixture = try await RecoveryControllerFixture(
            onEvidence: onEvidence, onContext: onContext, localSource: localSource,
            automaticBatch: automaticBatch, seedRestoreTemp: seedRestoreTemp,
            seedPreviousProblem: seedPreviousProblem, configure: configure)
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
    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState] {
        try await server.remoteDeletionStates(for: links)
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
    let initialProblem: BackupFailedItem
    let controller: AlbumSyncController
    let remote: RecoveryScenarioRemote

    init(
        onEvidence: @escaping @Sendable () async -> Void,
        onContext: @escaping @Sendable () async throws -> Void,
        localSource: any AlbumSyncLocalAlbumSource, automaticBatch: Bool, seedRestoreTemp: Bool,
        seedPreviousProblem: Bool,
        configure: (inout AlbumSyncController.Configuration, EditScenarioHarness) -> Void
    ) async throws {
        device = try EditScenarioHarness(live: true)
        try await device.enqueue()
        await device.drain()
        original = try device.liveMain()
        device.server.personTrash(original)
        backup = EditScenarioAlbumBackup(device: device)
        report = try await device.syncAlbum(["asset-1"], backup: backup)
        problem = try XCTUnwrap(report.problems.first)
        initialProblem =
            seedPreviousProblem
            ? BackupFailedItem(
                id: "previous-run-problem", filename: problem.filename, reason: "Previous run",
                isPermanent: false, issue: .remoteDeletion, source: problem.source, revision: problem.revision)
            : problem
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(
                url: device.directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        XCTAssertTrue(mapping.addSelection(.init(localAlbumID: "local-album", title: "Album", addedAt: .distantPast)))
        if automaticBatch {
            XCTAssertTrue(
                mapping.addSelection(.init(localAlbumID: "next-album", title: "B next", addedAt: .distantPast)))
            XCTAssertTrue(
                mapping.addSelection(.init(localAlbumID: "removed-album", title: "C removed", addedAt: .distantPast)))
        }
        if automaticBatch {
            for id in ["local-album", "next-album", "removed-album"] {
                XCTAssertTrue(
                    mapping.upsert(
                        .init(
                            localAlbumID: id, remoteAlbumID: "own-album", title: id, createdAt: .distantPast)))
            }
        }
        mapping.close()
        if seedRestoreTemp {
            let directory = device.directory.appendingPathComponent("album-sync-restore-temp")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: directory.appendingPathComponent("abandoned.partial"))
            try Data("original".utf8).write(to: directory.appendingPathComponent("abandoned.heic"))
        }
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
        configuration.changeSleep = { _ in
            if !automaticBatch { try await Task.sleep(nanoseconds: UInt64.max) }
        }
        configure(&configuration, device)
        controller = AlbumSyncController(
            configuration: configuration, identityResolver: device.identityResolver,
            uploader: device.deviceRemote, remoteOps: remote)
        controller.recordFinishedRun(
            seedPreviousProblem ? [initialProblem] : report.problems,
            albumID: "local-album", recoveryContext: remote.context)
    }

    func restore() async throws -> AlbumSyncPhotoRecovery.Result {
        try await controller.restorePhoto(problem, albumID: "local-album")
    }
}

private actor RecoveryGate {
    nonisolated let entered = XCTestExpectation(description: "Evidence started")
    nonisolated let cancelled = XCTestExpectation(description: "Evidence cancelled")
    nonisolated private let cancellation = RecoveryCancellationState()
    nonisolated var wasCancelled: Bool { cancellation.wasCancelled }
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var finished = false
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered.fulfill()
                if open { continuation.resume() } else { self.continuations.append(continuation) }
            }
        } onCancel: {
            cancellation.record()
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

private final class RecoveryCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var wasCancelled: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

private actor RecoveryContextReads {
    private(set) var count = 0
    func failFirstRead() throws {
        count += 1
        if count == 1 { throw URLError(.notConnectedToInternet) }
    }
}

private final class RecoveryBatchSource: AlbumSyncLocalAlbumSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    private var identifiers: [String] = []
    private let onFirstRead: @Sendable () async -> Void
    init(onFirstRead: @escaping @Sendable () async -> Void = {}) {
        self.onFirstRead = onFirstRead
    }
    func includeAsset() { lock.withLock { identifiers = ["asset-1"] } }
    var readAlbums: [String] { lock.withLock { reads } }
    func listAlbums() async throws -> [LocalAlbumSummary] {
        zip(
            ["local-album", "next-album", "removed-album", "added-album"], ["Album", "B next", "C removed", "D added"]
        )
        .map { .init(id: $0.0, title: $0.1, assetCount: 0) }
    }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        let first = lock.withLock {
            reads.append(albumID)
            return reads.count == 1
        }
        if first { await onFirstRead() }
        return .present(lock.withLock { identifiers })
    }
}

private struct RecoveryAlteredResolver: BackupResourceResolving {
    let library: EditScenarioLibrary
    let now: Date
    var missing = false
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard !missing, let original = try await library.resolve(entry, now: now) else { return nil }
        let snapshot = original.candidate.snapshot
        let candidate = UploadBackupAssetCandidate(
            snapshot: .init(
                source: snapshot.source, revision: .init(rawValue: -1),
                editRevision: snapshot.editRevision, resourceCount: snapshot.resourceCount),
            originalFilename: original.candidate.originalFilename, byteCount: original.candidate.byteCount)
        return .init(
            candidate: candidate, descriptor: original.descriptor, mediaType: original.mediaType,
            captureDate: original.captureDate, secondaries: original.secondaries, cleanup: original.cleanup)
    }
}
