import Foundation
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
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

    func testV105MissingRenderUploadsTheRenderedFileThatAppearsWithoutANewDate() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderUploadsALateRenderedFileAlsoAfterTheFirstReopen() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        _ = try await harness.fullRescan()
        await harness.drain()
        XCTAssertEqual(uploads, 0)
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderReopensWhenTheOriginalRecordHoldsTheMainBytes() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        var late = try XCTUnwrap(harness.library.snapshot.first)
        let main = try XCTUnwrap(harness.identities.record(for: late.source))
        late.render = Data("late-render".utf8)
        // A record of the original with the bytes of the main file proves that the backup holds no rendered file.
        var original = main
        original.source = try XCTUnwrap(PhotoBackupAssetPlanner.originalSecondarySource(for: late.info))
        XCTAssertTrue(harness.identities.upsert(original))
        try await assertLateRenderUploads()
    }

    func testV105MissingRenderUploadsTheRenderedFileThatAppearsWhenThePairedVideoDisappears() async throws {
        harness = try EditScenarioHarness(v105: .missingRender, live: true)
        let legacyCount = try harness.library.candidate().snapshot.resourceCount
        harness.library.removePairedVideo()
        var late = try XCTUnwrap(harness.library.snapshot.first)
        late.render = Data("late-render".utf8)
        // The rendered file takes the place of the paired video, so the v1.0.5 backup counts as many files.
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: late.info)?.snapshot.resourceCount, legacyCount)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        let earlierMains = activeMains
        harness.library.publishRender("late-render")
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(reopened.state, .queuedForUpload, "equal file counts must not hide the missing rendered file")
        await harness.pass()
        XCTAssertGreaterThan(uploads, 0, "the rendered file uploads")
        // The paired video exists only under the earlier main photo, so the edit waits instead of trashing it.
        XCTAssertTrue(earlierMains.isSubset(of: activeMains))
        XCTAssertEqual(harness.state(of: reopened), .discovered)
        harness.assertSafety()
    }

    func testV105MissingRenderThatThePersonDeletedElsewhereStaysDeletedWhenTheRenderedFileAppears() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        // Another client moves the only backup to the trash, so this device keeps no exclusion for the photo.
        harness.server.personTrash(try XCTUnwrap(harness.activeMains.first).uid)
        harness.library.publishRender("late-render-after-deletion")

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        harness.clock.advance(by: 5)
        await harness.pass()
        let deferred = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(deferred.state, .discovered)
        XCTAssertEqual(
            BackupIssueRecord.decode(deferred.lastError)?.detail,
            L10n.string("backup.issue_deletion_check"))
        harness.clock.advance(by: 120)
        await harness.pass()
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .discovered)
        harness.clock.advance(by: 480)
        await harness.pass()

        let parked = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(parked.state, .failedPermanent)
        XCTAssertEqual(BackupIssueRecord.decode(parked.lastError)?.kind, .deletedElsewhere)
        XCTAssertEqual(uploads, 0, "The rendered file must not bring the deleted photo back")
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(activeMains.isEmpty)
        harness.assertSafety()
    }

    func testV105MissingRenderThatTheRunnerBacksUpBeforeTheNextScanDoesNotReopen() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        // The scan stores the catalog entry without the rendered file, which appears before the runner reads the photo.
        _ = try await harness.fullRescan()
        harness.library.publishRender("late-render-before-scan")
        await harness.drain()
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, 0)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)
        let resolutions = harness.library.resolutions.count

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1)
        let row = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertTrue(
            [.completed, .alreadyBackedUp].contains(row.state), "The backup already holds the rendered file")
        await harness.drain()
        XCTAssertEqual(harness.library.resolutions.count, resolutions, "No photo bytes should be requested again")
        XCTAssertEqual(uploads, uploadsAfterRender)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    func testV105CatalogThatAlreadyListsTheLateRenderedFileUploadsItOnceAfterTheUpgrade() async throws {
        harness = try EditScenarioHarness(v105: .missingRender)
        let late = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: late.modificationDate)
        harness.library.add("asset-2", basename: "IMG_2")
        harness.library.edit("proven-render", identifier: "asset-2", at: harness.clock.now.addingTimeInterval(-121))
        harness.library.publishRender("late-render")
        // Today's build backs up the second edit with its rendered file as main photo.
        let proven = try await harness.enqueue("asset-2")
        await harness.pass()
        XCTAssertEqual(harness.state(of: proven), .completed)
        // v1.0.5 scanned both photos after Photos listed the rendered files, so the upgrade scan sees no change.
        let observedAt = harness.clock.now
        let entries = harness.library.snapshot.map {
            PhotoLibraryCatalogMapper.entry(for: $0.info, observedAt: observedAt)
        }
        XCTAssertTrue(harness.catalog.upsertBatch(entries))
        XCTAssertFalse(harness.catalog.hasReconciledLateRenders())
        let uploadsBefore = uploads
        let provenResolutions = harness.library.resolutions.filter { $0.source == proven.source }.count

        try harness.relaunch()
        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 0)
        XCTAssertEqual(scan.discovered, 0)
        XCTAssertTrue(harness.catalog.hasReconciledLateRenders())
        let reopened = try XCTUnwrap(harness.queue.entry(for: late.source, revision: revision))
        XCTAssertEqual(reopened.state, .queuedForUpload, "The v1.0.5 backup holds no rendered file")
        XCTAssertEqual(harness.state(of: proven), .completed, "The manifest proves the rendered file")
        await harness.drain()
        XCTAssertEqual(harness.state(of: reopened), .completed)
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, uploadsBefore)
        XCTAssertEqual(harness.library.resolutions.filter { $0.source == proven.source }.count, provenResolutions)

        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.changed, 0)
        await harness.drain()
        XCTAssertEqual(uploads, uploadsAfterRender)
        XCTAssertEqual(harness.library.resolutions.filter { $0.source == proven.source }.count, provenResolutions)
        harness.assertSafety()
        harness.assertQuiescent()
    }

    /// Photos lists the rendered file later and leaves the dates alone, so the revision equals the v1.0.5 one.
    private func assertLateRenderUploads(file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let revision = UploadBackupRevision(date: asset.modificationDate)
        harness.library.publishRender("late-render")
        XCTAssertEqual(try harness.library.candidate().snapshot.revision, revision, file: file, line: line)
        XCTAssertEqual(harness.queue.entry(for: asset.source, revision: revision)?.state, .completed)

        let scan = try await harness.fullRescan()
        XCTAssertEqual(scan.changed, 1, file: file, line: line)
        let reopened = try XCTUnwrap(harness.queue.entry(for: asset.source, revision: revision))
        XCTAssertEqual(
            reopened.state, .queuedForUpload, "The v1.0.5 backup holds no rendered file", file: file, line: line)
        await harness.drain(file: file, line: line)
        XCTAssertEqual(harness.state(of: reopened), .completed, file: file, line: line)
        let uploadsAfterRender = uploads
        XCTAssertGreaterThan(uploadsAfterRender, 0, file: file, line: line)

        // The re-open happens once: the catalog now lists the rendered file.
        try harness.relaunch()
        let secondScan = try await harness.fullRescan()
        XCTAssertEqual(secondScan.changed, 0, file: file, line: line)
        await harness.drain(file: file, line: line)
        XCTAssertEqual(uploads, uploadsAfterRender, file: file, line: line)
        harness.assertSafety(file: file, line: line)
        harness.assertQuiescent(file: file, line: line)
    }
}
