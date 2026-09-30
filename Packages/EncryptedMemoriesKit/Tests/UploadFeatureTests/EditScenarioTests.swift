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
        try harness.enqueue()
        await harness.drain()
        let main = try harness.liveMain()
        harness.server.decorate(main)
        harness.assertSafety()
        return main
    }

    @discardableResult
    private func edit(_ bytes: String, omitOriginal: Bool = false) throws -> UploadBackupSyncQueueEntry {
        harness.library.edit(bytes, omitOriginal: omitOriginal)
        let entry = try harness.enqueue()
        harness.assertSafety()
        return entry
    }

    @discardableResult
    private func undo() throws -> UploadBackupSyncQueueEntry {
        harness.library.undo()
        let entry = try harness.enqueue()
        harness.assertSafety()
        return entry
    }

    func testFirstEditOfABackedUpPhoto() async throws {
        let earlier = try await firstBackup()
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: earlier.nodeID)
        XCTAssertTrue(related.isEmpty, "An existing main without related files answers with an empty set")
        let entry = try edit("render-one")
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .trashed)
    }

    func testFirstEditAfterRelaunch() async throws {
        try await firstBackup()
        try harness.relaunch()
        try edit("render-one")
        await harness.drain()
    }

    func testSecondEdit() async throws {
        try await firstBackup()
        try edit("render-one")
        await harness.drain()
        try edit("render-two")
        await harness.drain()
    }

    func testSecondEditAfterRelaunch() async throws {
        try await firstBackup()
        try edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try edit("render-two")
        await harness.drain()
    }

    func testUndoAfterOneEdit() async throws {
        try await firstBackup()
        try edit("render-one")
        await harness.drain()
        let entry = try undo()
        await harness.drain()
        XCTAssertEqual(harness.state(of: entry), .completed)
    }

    func testUndoAfterOneEditAndRelaunch() async throws {
        try await firstBackup()
        try edit("render-one")
        await harness.drain()
        try harness.relaunch()
        try undo()
        await harness.drain()
    }

    /// Mirrors the IMG_7380 device case from September 30, 2026.
    func testUndoWithATrashedOriginalOutsideRetired() async throws {
        let original = try await firstBackup(basename: "IMG_7380")
        try edit("render-one")
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
        let entry = try undo()
        await harness.drain()
        harness.check(harness.state(of: entry) != .skippedRemoteDeletion, "an undo is not the person's deletion")
        harness.check(
            harness.activeMains.contains { $0.contentHash == originalLink.contentHash },
            "an undo must make the original the main again")
    }

    func testThreeRapidEdits() async throws {
        try await firstBackup()
        try edit("render-one")
        try edit("render-two")
        try edit("render-three")
        // No sleeps or scheduling race: all three discoveries exist before the runner resolves current bytes.
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "U3 rapid edits must converge to one main")
        XCTAssertEqual(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count, 4,
            "Only the original main, final render main, original secondary, and current adjustment data should upload")
    }

    func testLivePhotoEditThenUndo() async throws {
        try await firstBackup(live: true)
        try edit("render-one")
        await harness.drain()
        try undo()
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
        try edit("render-after-person-deletion")
        await harness.drain()
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploads,
            "S5 an edit after the person's deletion uploads nothing until restore")
        harness.expectKnownDefect(signature: "S5", consequences: [])
    }

    func testPersonRestoresReplacedMainThenUndoesWithoutAnIdenticalMain() async throws {
        let original = try await firstBackup()
        try edit("render-one")
        await harness.drain()
        harness.server.personRestore(original)
        harness.assertSafety()
        try undo()
        await harness.drain()
        harness.check(harness.activeMains.count == 1, "Restore plus undo must not create another identical main")
        harness.check(try harness.liveMain() == original, "The restored original already holds the current version")
    }

    func testPersonTrashesTheEditRestoresTheEarlierVersionThenEditsAgain() async throws {
        let original = try await firstBackup()
        try edit("render-one")
        await harness.drain()
        let edited = try harness.liveMain()
        harness.server.personTrash(edited)
        harness.server.personRestore(original)
        harness.assertSafety()
        try edit("render-two")
        await harness.drain()
        XCTAssertEqual(harness.activeMains.count, 1, "the new edit replaces the restored earlier version")
        XCTAssertEqual(harness.server.links.first { $0.uid == edited }?.state, .trashed, "the person's trash stays")
    }

    func testEditWhoseCompoundLacksTheOriginal() async throws {
        let original = try await firstBackup()
        harness.knownDefect =
            "Defect 5b (#194): the queue completes while the earlier main waits for its original, and two active "
            + "mains remain."
        let entry = try edit("render-without-original", omitOriginal: true)
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
        let entry = try edit("render-one")
        harness.server.failNextTrash()
        harness.knownDefect =
            "Defect 5b (#194): related links join retired before the trash succeeds."
        await harness.drain(eligibleOnly: true)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlier }?.state, .active)
        XCTAssertFalse(harness.state(of: entry)?.isTerminalSuccess == true)
        XCTAssertEqual(harness.server.steps.filter { $0.action == "failed backup trash" }.count, 1)
        // Defect 5b-retired candidate: a failed write cannot authorize retirement of still-active links.
        harness.assertRetired()
        let uploadedBeforeRetry = harness.server.steps.filter { $0.action.hasPrefix("upload") }.count
        try harness.relaunch()
        await harness.drain()
        harness.check(harness.activeMains.count == 1, "U3 one main after the retry")
        harness.check(
            harness.server.steps.filter { $0.action.hasPrefix("upload") }.count == uploadedBeforeRetry,
            "A trash retry must not upload the compound again")
        harness.expectKnownDefect(signature: "U4 retired names a link that is still in the library", consequences: [])
    }

    func testLocalDeletionKeepsTheRemoteBackup() async throws {
        let original = try await firstBackup()
        harness.library.delete()
        let entry = try harness.enqueue()
        harness.assertSafety()
        await harness.drain()
        XCTAssertNotEqual(harness.state(of: entry), .completed, "a deleted asset uploads nothing")
        XCTAssertEqual(try harness.liveMain(), original, "a local deletion keeps the backup")
    }

    func testServerTrashRestoreAndEmptyTrashRules() async throws {
        let original = try await firstBackup(live: true)
        let contentHash = try XCTUnwrap(harness.server.links.first { $0.uid == original }?.contentHash)
        let related = try await harness.server.relatedPhotoLinkIDs(ofMainLinkID: original.nodeID)
        XCTAssertEqual(related.count, 1)
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
