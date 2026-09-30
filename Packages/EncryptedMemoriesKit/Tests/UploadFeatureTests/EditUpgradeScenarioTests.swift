import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Upgrade scenarios start with persisted v1.0.5 values, without running today's upload path to seed them.
final class EditUpgradeScenarioTests: XCTestCase {
    private var harness: EditScenarioHarness!

    override func tearDownWithError() throws {
        try harness?.cleanup()
        harness = nil
    }

    private var uploads: Int { harness.server.steps.filter { $0.action.hasPrefix("upload") }.count }
    private var trashed: [String] { harness.server.steps.flatMap(\.trashedByBackup) }
    private var activeMains: Set<PhotoUID> {
        Set(harness.server.links.filter { $0.mainLinkID == nil && $0.state == .active }.map(\.uid))
    }

    func testFirstFullRescanAfterV105ReopensNothingAndWritesNoJournal() async throws {
        harness = try EditScenarioHarness(v105: .unchanged, assetCount: 256)
        let before = activeMains
        XCTAssertEqual(before.count, 256)
        XCTAssertFalse(harness.journalFileExists)
        for asset in harness.library.snapshot {
            XCTAssertEqual(harness.identities.record(for: asset.source)?.outcome, "uploaded")
            XCTAssertTrue(harness.journal.entry(for: asset.source).isEmpty)
        }

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.scanned, 256)
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertEqual(scan.changed, 0, "An unchanged library must not re-open on upgrade")
        XCTAssertEqual(scan.removed, 0)
        XCTAssertTrue(harness.queue.unsettledRows().isEmpty)
        await harness.drain()

        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, before)
        XCTAssertTrue(harness.library.resolutions.isEmpty, "No photo bytes should be requested")
        XCTAssertFalse(harness.journalFileExists)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testNewEditAfterV105TrashesOnlyTheManifestMainAndKeepsTheOriginalMain() async throws {
        harness = try EditScenarioHarness(v105: .edited)
        let original = try XCTUnwrap(harness.activeMains.first { $0.generation == 1 }).uid
        let earlierEdit = try XCTUnwrap(harness.activeMains.first { $0.generation == 2 }).uid
        let source = try harness.library.candidate().snapshot.source
        XCTAssertEqual(harness.identities.record(for: source)?.remoteLinkID, earlierEdit.nodeID)
        XCTAssertTrue(
            harness.server.links.filter { $0.mainLinkID == earlierEdit.nodeID }.allSatisfy { !$0.isOriginal },
            "v1.0.5 deduped the original against L0 instead of attaching a new copy to E")
        XCTAssertFalse(harness.journalFileExists)
        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        await harness.pass()
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.edit("new-render-after-upgrade", at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertEqual(trashed, [earlierEdit.nodeID])
        XCTAssertEqual(harness.server.links.first { $0.uid == original }?.state, .active)
        XCTAssertEqual(harness.server.links.first { $0.uid == earlierEdit }?.state, .trashed)
        XCTAssertEqual(activeMains.count, 2, "The unrelated legacy original stays beside the new edit")
        XCTAssertFalse(harness.journal.entry(for: source).retired.contains(original.nodeID))
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testUndoOfAV105EditKeepsBothLegacyMainsAndTrashesNothing() async throws {
        harness = try EditScenarioHarness(v105: .edited)
        let before = activeMains
        XCTAssertEqual(before.count, 2)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.undo(at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(activeMains, before)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(harness.journal.entry(for: entry.source).superseded.isEmpty)
        XCTAssertFalse(harness.journalFileExists)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testEditingOneOfTwoV105AssetsWithIdenticalBytesKeepsTheirSharedMain() async throws {
        harness = try EditScenarioHarness(v105: .identicalBytes)
        let first = try harness.library.candidate().snapshot.source
        let second = try harness.library.candidate("asset-2").snapshot.source
        let shared = try XCTUnwrap(harness.identities.record(for: first)?.remoteLinkID)
        XCTAssertEqual(harness.identities.record(for: second)?.remoteLinkID, shared)
        XCTAssertEqual(activeMains.count, 1)
        XCTAssertFalse(harness.journalFileExists)

        harness.library.edit("only-the-first-asset-is-edited", at: harness.clock.now)
        let entry = try await harness.enqueue()
        await harness.drain()

        XCTAssertEqual(harness.state(of: entry), .completed)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(harness.server.links.first { $0.linkID == shared }?.state, .active)
        XCTAssertEqual(harness.identities.record(for: second)?.remoteLinkID, shared)
        XCTAssertNotEqual(harness.identities.record(for: first)?.remoteLinkID, shared)
        XCTAssertEqual(activeMains.count, 2)
        XCTAssertTrue(harness.journal.entry(for: first).superseded.isEmpty)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105MissingRenderReopensOnceWithoutUploadingOrSupersedingAnything() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let candidate = try harness.library.candidate()
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let oldRevision = UploadBackupRevision(date: asset.modificationDate)
        XCTAssertNotEqual(candidate.snapshot.revision, oldRevision)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: oldRevision)?.state, .completed)
        XCTAssertNil(harness.queue.entry(for: asset.source, revision: candidate.snapshot.revision))
        XCTAssertFalse(harness.journalFileExists)
        let before = activeMains

        let firstScan = try await harness.fullRescan()
        XCTAssertEqual(firstScan.scanned, 1)
        XCTAssertEqual(firstScan.changed, 1, "Only the missing-render marker re-opens the legacy row")
        XCTAssertEqual(firstScan.discovered, 0)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(reopened.state, .checking)
        await harness.drain()
        XCTAssertEqual(harness.state(of: reopened), .alreadyBackedUp)
        XCTAssertEqual(harness.library.resolutions.count, 1)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(harness.journal.entry(for: asset.source).superseded.isEmpty)

        // Reopen the files again so an in-memory scan result cannot hide a repeated migration.
        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.scanned, 1)
        XCTAssertEqual(secondScan.changed, 0)
        XCTAssertEqual(secondScan.discovered, 0)
        await harness.drain()
        XCTAssertEqual(harness.library.resolutions.count, 1)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(activeMains, before)
        XCTAssertTrue(harness.journal.entry(for: asset.source).superseded.isEmpty)
        harness.assertSafety()
        harness.assertQuiescent()
    }
}
