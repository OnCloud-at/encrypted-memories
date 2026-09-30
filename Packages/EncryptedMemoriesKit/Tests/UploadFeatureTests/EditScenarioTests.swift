import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// End-to-end edit scenarios share server truth across every production seam.
final class EditScenarioTests: XCTestCase {
    private var harness: EditScenarioHarness!

    override func tearDownWithError() throws {
        try harness?.cleanup()
        harness = nil
    }

    @discardableResult
    private func firstBackup(live: Bool = false, basename: String = "IMG_1") async throws -> PhotoUID {
        harness = try EditScenarioHarness(live: live, basename: basename)
        try await harness.enqueue()
        await harness.drain()
        let main = try harness.liveMain()
        harness.server.decorate(main)
        harness.assertSafety()
        return main
    }

    @discardableResult
    private func edit(_ bytes: String, omitOriginal: Bool = false) async throws -> UploadBackupSyncQueueEntry {
        harness.library.edit(bytes, omitOriginal: omitOriginal, at: harness.clock.now)
        let entry = try await harness.enqueue()
        harness.assertSafety()
        return entry
    }

    @discardableResult
    private func undo() async throws -> UploadBackupSyncQueueEntry {
        harness.library.undo(at: harness.clock.now)
        let entry = try await harness.enqueue()
        harness.assertSafety()
        return entry
    }

    func testFirstEditOfABackedUpPhoto() async throws {
        let earlier = try await firstBackup()
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: earlier.nodeID)
        XCTAssertTrue(related.isEmpty, "An existing main without related files answers with an empty set")
        let entry = try await edit("render-one")
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
    }

    func testFirstEditAfterRelaunch() async throws {
        try await firstBackup()
        try harness.relaunch()
        try await edit("render-one")
        await harness.drain()
    }

    func testSecondEdit() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try await edit("render-two")
        await harness.drain()
    }

    func testSecondEditAfterRelaunch() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try await edit("render-two")
        await harness.drain()
    }

    func testUndoAfterOneEdit() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        let entry = try await undo()
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
    }

    func testUndoAfterOneEditAndRelaunch() async throws {
        try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try await undo()
        await harness.drain()
    }

    /// Mirrors the IMG_7380 device case from September 30, 2026.
    func testUndoWithATrashedOriginalOutsideRetired() async throws {
        let original = try await firstBackup(basename: "IMG_7380")
        try await edit("render-one")
        await harness.drain()
        let edited = try harness.liveMain()
        let originalLink = try XCTUnwrap(harness.server.links.first { $0.uid == original })
        XCTAssertTrue(
            harness.server.links.contains {
                $0.mainLinkID == edited.nodeID && $0.state == .active && $0.contentHash == originalLink.contentHash
                    && $0.nameHash == originalLink.nameHash
            }, "The edited main must hold the original as an active related file before undo")
        try harness.server.addHistoricalTrashedCopy(of: original)
        harness.assertSafety()
        let historical = try XCTUnwrap(harness.server.links.first { $0.generation == 0 })
        XCTAssertEqual(historical.state, .trashed)
        XCTAssertNil(historical.mainLinkID)
        XCTAssertEqual(historical.nameHash, originalLink.nameHash)
        XCTAssertEqual(historical.contentHash, originalLink.contentHash)
        let source = try harness.library.candidate().snapshot.source
        XCTAssertFalse(harness.journal.entry(for: source).retired.contains(historical.linkID))
        let entry = try await undo()
        await harness.drain()
        harness.check(harness.state(of: entry) != .skippedRemoteDeletion, "an undo is not the person's deletion")
        harness.check(
            harness.activeMains.contains { $0.contentHash == originalLink.contentHash },
            "an undo must make the original the main again")
    }

    func testThreeRapidEdits() async throws {
        try await firstBackup()
        try await edit("render-one")
        try await edit("render-two")
        try await edit("render-three")
        // No sleeps or scheduling race: all three discoveries exist before the runner resolves current bytes.
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "U3 rapid edits must converge to one main")
        XCTAssertEqual(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, 4,
            "Only the original main, final render main, original secondary, and current adjustment data should upload")
    }

    func testLivePhotoEditThenUndo() async throws {
        try await firstBackup(live: true)
        try await edit("render-one")
        await harness.drain()
        try await undo()
        await harness.drain()
    }

    func testPersonTrashesLiveMainThenEditsNothingUploads() async throws {
        let main = try await firstBackup()
        harness.server.personTrash(main)
        harness.assertSafety()
        let uploads = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        harness.knownDefect =
            "Defect F1 (#194): an edit after the person trashed the photo uploads again. Without a marker on the "
            + "server, nothing proves who trashed the photo."
        try await edit("render-after-person-deletion")
        await harness.drain()
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploads,
            "S5 an edit after the person's deletion uploads nothing until restore")
        harness.expectKnownDefect(signature: "S5", consequences: [])
    }

    func testPersonRestoresReplacedMainThenUndoesWithoutAnIdenticalMain() async throws {
        let original = try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        harness.server.personRestore(original)
        harness.assertSafety()
        try await undo()
        await harness.drain()
        harness.check(harness.activeMains.count == 1, "Restore plus undo must not create another identical main")
        harness.check(try harness.liveMain() == original, "The restored original already holds the current version")
    }

    func testPersonTrashesTheEditRestoresTheEarlierVersionThenEditsAgain() async throws {
        let original = try await firstBackup()
        try await edit("render-one")
        await harness.drain()
        let edited = try harness.liveMain()
        harness.server.personTrash(edited)
        harness.server.personRestore(original)
        harness.assertSafety()
        try await edit("render-two")
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "the new edit replaces the restored earlier version")
        XCTAssertEqual(harness.server.links.first { $0.uid == edited }?.state, .trashed, "the person's trash stays")
    }

    func testEditWhoseCompoundLacksTheOriginal() async throws {
        let original = try await firstBackup()
        harness.knownDefect =
            "Defect 5b (#194): the queue completes while the earlier main waits for its original, and two active "
            + "mains remain."
        let entry = try await edit("render-without-original", omitOriginal: true)
        await harness.drain()
        // Defect 5b candidate: completion must not conceal an earlier main still waiting for its original.
        let source = try harness.library.candidate().snapshot.source
        harness.check(
            !(harness.state(of: entry)?.isTerminalSuccess == true
                && harness.journal.entry(for: source).superseded.contains(original)),
            "defect 5b: the queue completes while the earlier main waits and two active mains remain")
        harness.expectKnownDefect(
            signature: "defect 5b",
            consequences: [
                "S1/U3 mains:", "S1 the main must hold the current version",
                "S3 the edited main lacks its active original",
            ])
    }

    func testFailedTrashThenRelaunch() async throws {
        let earlier = try await firstBackup(live: true)
        let entry = try await edit("render-one")
        harness.server.failNextTrash()
        harness.knownDefect =
            "Defect 5b (#194): related links join retired before the trash succeeds."
        harness.clock.advance(by: 5)
        await harness.pass()
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .active)
        XCTAssertFalse(harness.state(of: entry)?.isTerminalSuccess == true)
        XCTAssertEqual(harness.server.steps.filter { $0.action == "failed backup trash" }.count, 1)
        // Defect 5b-retired candidate: a failed write cannot authorize retirement of still-active links.
        harness.assertRetired()
        let uploadedBeforeRetry = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        try harness.relaunch()
        harness.clock.advance(by: 8)
        await harness.pass()
        harness.assertQuiescent()
        harness.check(harness.activeMains.count == 1, "U3 one main after the retry")
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadedBeforeRetry,
            "A trash retry must not upload the compound again")
        harness.expectKnownDefect(signature: "U4 retired names a link that is still in the library", consequences: [])
    }

    func testLocalDeletionKeepsTheRemoteBackup() async throws {
        let original = try await firstBackup()
        harness.library.delete()
        let entry = try harness.enqueueStaleRemovedAsset()
        harness.assertSafety()
        await harness.drain()
        XCTAssertNotEqual(harness.state(of: entry), .completed, "a deleted asset uploads nothing")
        XCTAssertEqual(try harness.liveMain(), original, "a local deletion keeps the backup")
    }

    func testRemoteProofOnSecondDeviceThenFirstEdit() async throws {
        harness = try EditScenarioHarness()
        try await harness.enqueue()
        await harness.drain()
        let original = try harness.liveMain()
        let deviceB = try EditScenarioHarness(server: harness.server, library: harness.library)
        defer { try? deviceB.cleanup() }
        let candidate = try deviceB.library.candidate()
        let identity = try XCTUnwrap(candidate.snapshot.externalIdentity)
        let proof = try await deviceB.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(proof[identity]?.resourceCount, candidate.snapshot.resourceCount)
        XCTAssertEqual(proof[identity]?.remoteLinkIDs, [original.nodeID])
        let uploadsBeforeDiscovery = deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let lookupsBeforeDiscovery = deviceB.server.remoteProofLookups.count
        let discovered = try await deviceB.enqueue()
        XCTAssertEqual(deviceB.server.remoteProofLookups.count, lookupsBeforeDiscovery + 1)
        XCTAssertEqual(deviceB.lastScan.alreadyBackedUp, 1)
        XCTAssertEqual(deviceB.state(of: discovered), .alreadyBackedUp)
        XCTAssertNil(deviceB.identities.record(for: candidate.snapshot.source))
        XCTAssertTrue(deviceB.journal.entry(for: candidate.snapshot.source).isEmpty)
        await deviceB.pass()
        XCTAssertEqual(
            deviceB.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploadsBeforeDiscovery,
            "The remote compound proof must avoid resolving or uploading bytes")

        deviceB.knownDefect = "N1 (#194): remote proof creates no source manifest for replacement discovery."
        deviceB.library.edit("device-b-edit", at: deviceB.clock.now)
        try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        deviceB.check(deviceB.activeMains.count == 1, "S1/U3 mains: the second device's edit must replace the original")
        deviceB.check(
            deviceB.server.links.first { $0.uid == original }?.state == .trashed,
            "N1 the remotely proven original must move to trash")
        await deviceB.drain()
        deviceB.expectKnownDefect(
            signature: "S1/U3 mains",
            consequences: [
                "N1 the remotely proven original", "S1 the main must hold the current version",
                "S3 the edited main lacks its active original",
            ])
    }

    func testTwoDevicesReplaceAnEditOutsideTheSecondDevicesJournal() async throws {
        harness = try EditScenarioHarness()
        let deviceB = try EditScenarioHarness(server: harness.server, library: harness.library)
        defer { try? deviceB.cleanup() }
        // Both discover before either uploads, so both run the real pipeline and acquire a manifest for O.
        try await harness.enqueue()
        try await deviceB.enqueue()
        await harness.drain()
        await deviceB.drain()
        let source = try harness.library.candidate().snapshot.source
        let original = try harness.liveMain()
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertNotEqual(deviceB.directory, harness.directory)

        try await edit("device-a-edit-e")
        await harness.drain()
        let editE = try harness.liveMain()
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        XCTAssertEqual(deviceB.identities.record(for: source)?.remoteLinkID, original.nodeID)
        XCTAssertFalse(deviceB.journal.entry(for: source).retired.contains(original.nodeID))
        deviceB.knownDefect =
            "N2 (#194): a device replaces only photos of its own manifest, so another device's edit stays active. "
            + "Needs the replacement marker on the server."
        deviceB.library.edit("device-b-edit-f", at: deviceB.clock.now)
        let editF = try await deviceB.enqueue()
        deviceB.clock.advance(by: 5)
        await deviceB.pass()
        // These hard assertions cannot be collected as consequences of the known replacement defect.
        XCTAssertEqual(deviceB.state(of: editF), .completed, "Edit F must finish before checking replacement of E")
        let editFHash = EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: Data("device-b-edit-f".utf8))))
        XCTAssertTrue(
            deviceB.activeMains.contains { $0.contentHash == editFHash },
            "Edit F's bytes must exist in an active main before checking replacement of E")
        deviceB.check(
            deviceB.state(of: editF) != .skippedRemoteDeletion, "U2 another device's trash is not person deletion")
        deviceB.check(
            deviceB.server.links.first { $0.uid == editE }?.state == .trashed,
            "N2 the second device must trash the first device's edit E")
        XCTAssertFalse(deviceB.server.links.contains { $0.personDeleted })
        await deviceB.drain()
        deviceB.expectKnownDefect(
            signature: "N2 the second device must trash the first device's edit E",
            consequences: ["S1/U3 mains:", "S1 the main must hold the current version"])
    }

    func testUndoRestoresTheExactEarlierRevision() async throws {
        let original = try await firstBackup()
        let earlierCandidate = try harness.library.candidate()
        let originalHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        try await edit("render-before-exact-undo")
        await harness.drain()
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)

        harness.knownDefect = "N3 (#194): a terminal queue row cannot reopen when undo restores its exact revision."
        harness.library.undo(at: harness.clock.now, restoreEarlierDate: true)
        let undoCandidate = try harness.library.candidate()
        XCTAssertEqual(undoCandidate.snapshot.revision, earlierCandidate.snapshot.revision)
        XCTAssertEqual(undoCandidate.snapshot.externalIdentity, earlierCandidate.snapshot.externalIdentity)
        XCTAssertEqual(undoCandidate.snapshot.editRevision, earlierCandidate.snapshot.editRevision)
        try await harness.enqueue()
        await harness.pass()
        harness.check(
            harness.activeMains.contains { $0.contentHash == originalHash },
            "S1 the main must hold the current version after exact-revision undo")
        await harness.drain()
        harness.expectKnownDefect(signature: "S1 the main must hold the current version", consequences: [])
    }

    func testMissingRenderBeyondTheReadinessDeadline() async throws {
        try await missingRender(timestampPresent: true)
    }

    func testMissingRenderWithoutAnAdjustmentTimestamp() async throws {
        try await missingRender(timestampPresent: false)
    }

    private func missingRender(timestampPresent: Bool) async throws {
        harness = try EditScenarioHarness()
        harness.library.edit(
            "late-render", at: harness.clock.now, renderPresent: false, timestampPresent: timestampPresent)
        try await harness.enqueue()
        let uploadsBeforeEdit = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        if timestampPresent {
            await harness.pass()
            XCTAssertEqual(harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, uploadsBeforeEdit)
        }
        harness.knownDefect =
            "K6 (#194): a missing render falls through to the original after 120 seconds or without a timestamp."
        if timestampPresent { harness.clock.advance(by: 121) }
        await harness.pass()
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadsBeforeEdit,
            "K6 missing render must not upload any resource of the edit")
        // A duplicate original is also wrong: it must not be counted as the completed current edit.
        let missingRender = try harness.library.candidate()
        let entry = try XCTUnwrap(
            harness.queue.entry(for: missingRender.snapshot.source, revision: missingRender.snapshot.revision))
        harness.check(
            harness.state(of: entry)?.isTerminalSuccess != true,
            "K6 missing render must not count the original as the current version")
        harness.library.publishRender("late-render")
        try await harness.enqueue()
        harness.clock.advance(by: 15)
        await harness.pass()
        harness.assertQuiescent()
        harness.expectKnownDefect(
            signature: "K6 missing render",
            consequences: [
                "S1 the main must hold the current version", "S3 the edited main lacks its active original",
                "S3 the edited main lacks its current adjustment data",
            ])
    }

    func testWaitingOriginalThenPersonDeletesTheEditAndMetadataDrifts() async throws {
        let original = try await firstBackup()
        try await edit("deleted-edit-with-waiting-original", omitOriginal: true)
        harness.clock.advance(by: 5)
        await harness.pass()
        let source = try harness.library.candidate().snapshot.source
        let deletedEdit = try XCTUnwrap(harness.activeMains.first { $0.generation == 2 }).uid
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
        XCTAssertTrue(harness.journal.entry(for: source).superseded.contains(original))
        harness.server.personTrash(deletedEdit)
        harness.assertSafety()
        let uploadsBeforeDrift = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        let bytesBeforeDrift = try XCTUnwrap(harness.library.snapshot.first).current
        let revisionBeforeDrift = try harness.library.candidate().snapshot.revision
        harness.library.changeModificationDate()
        XCTAssertEqual(try XCTUnwrap(harness.library.snapshot.first).current, bytesBeforeDrift)
        XCTAssertNotEqual(try harness.library.candidate().snapshot.revision, revisionBeforeDrift)
        let drifted = try await harness.enqueue()
        XCTAssertEqual(drifted.state, .checking, "Metadata drift must require a backend check during discovery")
        let decision = try await harness.primaryDecision(for: drifted)
        XCTAssertEqual(decision, .skip(.knownFromManifest, remoteLinkID: deletedEdit.nodeID))
        await harness.pass()
        // The unchanged digest and capture date reuse the manifest; this path does not revalidate the deleted main.
        XCTAssertEqual(harness.state(of: drifted), .alreadyBackedUp)
        let settled = try XCTUnwrap(harness.queue.entry(for: drifted.source, revision: drifted.revision))
        XCTAssertEqual(settled.attempts, 0)
        XCTAssertNil(settled.remoteCommitReconciliation)
        // The intentionally waiting original can remain. Only a new upload after deletion violates this scenario.
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadsBeforeDrift,
            "S5 metadata drift after the person's deletion must upload nothing")
        harness.check(
            harness.server.links.first { $0.uid == deletedEdit }?.state == .trashed,
            "S5 metadata drift must preserve the person's deletion")
    }

    func testThreeEditsWithTheFirstUploadInFlight() async throws {
        let original = try await firstBackup()
        let firstEdit = try await edit("in-flight-edit-one")
        harness.clock.advance(by: 5)
        await harness.server.uploadGate.arm(generation: 2)
        let runningPass = harness.startPass()
        await harness.server.uploadGate.waitUntilSuspended()
        // The first render's descriptor and bytes are already resolved. Two newer revisions arrive before commit.
        do {
            try await edit("in-flight-edit-two")
            try await edit("in-flight-edit-three")
            harness.clock.advance(by: 5)
        } catch {
            await harness.server.uploadGate.release()
            _ = await runningPass.value
            throw error
        }
        await harness.server.uploadGate.release()
        _ = await runningPass.value
        await harness.pass()
        await harness.drain()
        XCTAssertTrue(
            harness.library.materializations.contains {
                $0.resolvedGeneration == 2 && $0.currentGeneration == 4 && $0.digestChanged
            }, "The first compound must materialize changed secondary bytes after its primary upload")
        XCTAssertTrue(
            harness.library.resolutions.contains {
                $0.revision == firstEdit.revision && $0.state == .queuedForUpload && $0.attempts == 0
            }, "The changed secondary must requeue the first revision without completing it or spending a retry")
        let firstMain = try XCTUnwrap(harness.server.links.first { $0.mainLinkID == nil && $0.generation == 2 })
        XCTAssertFalse(
            harness.server.links.contains { $0.mainLinkID == firstMain.linkID && $0.generation == 2 },
            "The first main must not receive eagerly exported stale secondaries")
        harness.assertCurrentManifest()
        XCTAssertEqual(harness.activeMains.count, 1)
        XCTAssertEqual(harness.activeMains.first?.generation, 4, "The third edit must hold the sole active main")
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .trashed)
        XCTAssertTrue(
            harness.server.links.filter { $0.mainLinkID == nil && $0.generation < 4 }.allSatisfy {
                $0.state == .trashed
            },
            "Every earlier uploaded main must leave the library")
    }

    func testSecondEditWhenRelatedLookupRejectsTrashedMains() async throws {
        let original = try await firstBackup(live: true)
        try await edit("first-edit-with-strict-related-endpoint")
        await harness.drain()
        let edited = try harness.liveMain()
        let originalHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        XCTAssertTrue(
            harness.server.links.contains {
                $0.mainLinkID == edited.nodeID && $0.state == .active && $0.contentHash == originalHash
            }, "An active original-content row must remain under the edit before undo")
        harness.server.personTrash(edited)
        harness.server.relatedLookupFailsForTrashedMain = true
        harness.knownDefect =
            "Defect F1 (#194): an undo after the person trashed the photo uploads again. Without a marker on the "
            + "server, nothing proves who trashed the photo."
        let undone = try await undo()
        for _ in 0..<6 {
            harness.clock.advance(by: 8)
            await harness.pass()
        }
        let row = try XCTUnwrap(harness.queue.entry(for: undone.source, revision: undone.revision))
        XCTAssertTrue(
            harness.server.rejectedTrashedMainLookupIDs.isEmpty,
            "the check must not ask for the related photos of a trashed main")
        XCTAssertTrue(row.state.isTerminalSuccess, "the row must settle: \(row.state)")
        harness.expectKnownDefect(signature: "S5 uploaded", consequences: ["S5"])
    }

    func testServerTrashRestoreAndEmptyTrashRules() async throws {
        let original = try await firstBackup(live: true)
        let contentHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: original.nodeID)
        XCTAssertEqual(related.count, 1)
        let identity = try XCTUnwrap(harness.library.candidate().snapshot.externalIdentity)
        let compoundProof = try await harness.server.findRemoteAssetProofs(for: [identity])
        XCTAssertEqual(compoundProof[identity]?.resourceCount, 2)
        XCTAssertEqual(Set(compoundProof[identity]?.remoteLinkIDs ?? []), related.union([original.nodeID]))
        let albums = try await harness.server.albums(containing: original)
        for albumID in ["shared-album", "unknown-album"] {
            do {
                try await harness.server.addPhotos([original], toOwnAlbum: albumID)
                XCTFail("An album outside the known own-volume albums must fail")
            } catch {}
        }
        let unchangedAlbums = try await harness.server.albums(containing: original)
        XCTAssertEqual(unchangedAlbums, albums, "A rejected album write must not invent a membership")
        harness.server.personTrash(original)
        harness.assertSafety()
        let trashedContent = try await harness.server.findDuplicate(contentHash: contentHash)
        XCTAssertNil(trashedContent, "Content lookup returns only active records")
        let trashedProof = try await harness.server.findRemoteAssetProofs(for: [identity])
        XCTAssertNil(trashedProof[identity], "An orphan under a trashed main cannot prove an active compound")
        let trashedRelated = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: original.nodeID)
        XCTAssertEqual(trashedRelated, related, "A trashed main still answers with its related files")
        let trashed = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(trashed.first?.linkState, .trashed)
        let orphan = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.MOV)"])
        XCTAssertEqual(orphan.first?.linkState, .active)
        harness.server.personRestore(original)
        harness.assertSafety()
        let active = try await harness.server.activeUIDs(among: [original])
        XCTAssertEqual(active, [original])
        let activeContent = try await harness.server.findDuplicate(contentHash: contentHash)
        XCTAssertEqual(activeContent?.linkID, original.nodeID)
        XCTAssertEqual(activeContent?.linkState, .active)
        harness.server.personTrash(original)
        harness.assertSafety()
        harness.server.personEmptyTrash()
        harness.assertSafety()
        XCTAssertTrue(harness.server.links.allSatisfy { $0.state == .deleted })
        let removed = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)", "nh(IMG_1.MOV)"])
        XCTAssertTrue(removed.isEmpty)
        for mainLinkID in [original.nodeID, "unknown-main"] {
            do {
                _ = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: mainLinkID)
                XCTFail("An unknown or permanently deleted main must not answer with an empty set")
            } catch {}
        }
    }
}
