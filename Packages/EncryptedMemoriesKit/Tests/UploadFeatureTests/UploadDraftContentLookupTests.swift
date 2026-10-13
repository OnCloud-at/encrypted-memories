import CryptoKit
import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class UploadDraftContentLookupTests: XCTestCase {
    func testForeignNameDraftDoesNotHideAnActiveCopyUnderAnotherName() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let active = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        let draft = harness.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("different-photo".utf8))),
            clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(before.map(\.linkID), [draft.nodeID])
        XCTAssertEqual(before.first?.linkState, .draft)
        XCTAssertNotEqual(before.first?.contentHash, harness.server.links.first { $0.uid == active }?.contentHash)
        let entry = try await harness.enqueue()

        await harness.pass()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(after, before, "The foreign draft must survive unchanged")
        XCTAssertEqual(harness.server.links.count, 2)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        XCTAssertFalse(harness.server.steps.contains { $0.action.hasPrefix("upload ") })

        try harness.relaunch()
        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
    }

    func testForeignAndUnknownDraftsRemainBlockedWithoutAnActiveCopy() async throws {
        for owner in ["other-uploader", nil] {
            let server = EditScenarioServer()
            let (pipeline, descriptor, draft) = fixture(server: server, owner: owner)
            let result = try await pipeline.resolve(descriptor)
            XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
            XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
            XCTAssertEqual(server.uploadRequestCount, 0)
        }
    }

    func testRelatedActiveContentDoesNotSettleARootBlockedByDraft() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let main = server.seedLink(digest: Data(repeating: 2, count: 20))
        _ = server.seedLink(digest: descriptor.precomputedSHA1Digest!, main: main)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testInactiveContentFromAStaleIndexDoesNotReplaceTheDraftBlock() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        let old = server.seedLink(digest: descriptor.precomputedSHA1Digest!)
        server.personTrash(old)
        server.returnInactiveContentFromStaleIndex()

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == old }?.state, .trashed)
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
    }

    func testCancelledContentLookupReleasesClaimsAndStartsNoUpload() async throws {
        let server = EditScenarioServer()
        let (pipeline, descriptor, draft) = fixture(server: server)
        server.setContentLookupError(CancellationError())
        do {
            _ = try await pipeline.resolve(descriptor)
            XCTFail("A cancelled content lookup must not settle the photo")
        } catch is CancellationError {
        }
        server.setContentLookupError(nil)
        let active = server.seedLink(digest: descriptor.precomputedSHA1Digest!)

        let retried = try await pipeline.resolve(descriptor)

        XCTAssertEqual(retried.decision, .skip(.activeDuplicate, remoteLinkID: active.nodeID))
        XCTAssertEqual(server.links.first { $0.uid == draft }?.state, .draft)
        XCTAssertEqual(server.uploadRequestCount, 0)
    }

    func testAdoptedLivePrimaryUploadsOnlyItsMissingVideoAndKeepsTheForeignDraft() async throws {
        let harness = try EditScenarioHarness(live: true)
        defer { try? harness.cleanup() }
        let asset = try XCTUnwrap(harness.library.snapshot.first)
        let active = harness.server.seedLink(digest: Data(Insecure.SHA1.hash(data: asset.current)))
        let draft = harness.server.seedDraft(
            name: "IMG_1.HEIC", digest: Data(Insecure.SHA1.hash(data: Data("different-photo".utf8))),
            clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(before.map(\.linkID), [draft.nodeID])
        XCTAssertTrue(harness.server.links.filter { $0.mainLinkID == active.nodeID }.isEmpty)
        let entry = try await harness.enqueue()

        await harness.pass()

        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(IMG_1.HEIC)"])
        XCTAssertEqual(after, before, "The foreign draft must survive unchanged")
        XCTAssertEqual(harness.server.uploadRequestCount, 1)
        let uploaded = harness.server.links.filter { $0.uid != active && $0.uid != draft }
        XCTAssertEqual(uploaded.count, 1)
        let video = try XCTUnwrap(uploaded.first)
        XCTAssertEqual(video.mainLinkID, active.nodeID)
        XCTAssertEqual(video.nameHash, "nh(IMG_1.MOV)")
        XCTAssertEqual(video.state, .active)
        XCTAssertEqual(
            video.contentHash,
            EditScenarioServer.contentHash(Data(Insecure.SHA1.hash(data: try XCTUnwrap(asset.pairedVideo)))))
        let secondarySource = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: asset.identifier, resource: .livePairedVideo)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.remoteLinkID, video.linkID)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.outcome, "uploaded")

        try harness.relaunch()
        XCTAssertEqual(harness.state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(harness.identities.record(for: entry.source)?.remoteLinkID, active.nodeID)
        XCTAssertEqual(harness.identities.record(for: secondarySource)?.remoteLinkID, video.linkID)
        XCTAssertEqual(harness.server.uploadRequestCount, 1)
    }

    func testBlockedResolveKeepsExistingRestoredVersionJournalUpdates() async throws {
        let harness = try EditScenarioHarness()
        defer { try? harness.cleanup() }
        let source = try XCTUnwrap(harness.library.snapshot.first).source
        let descriptor = UploadResourceDescriptor(
            source: source, fileURL: URL(fileURLWithPath: "/fixture/current.heic"), filename: "current.heic",
            fileSize: 20, modificationDate: harness.clock.now, precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let restored = harness.server.seedLink(digest: Data(repeating: 2, count: 20))
        try harness.journal.addSuperseded(restored, for: source)
        try harness.journal.settle([restored.nodeID], related: [], trashed: true, for: source)
        try harness.journal.keepDeleted(for: source)
        XCTAssertEqual(harness.journal.entry(for: source).retired, [restored.nodeID])
        XCTAssertEqual(harness.journal.entry(for: source).keptDeleted, true)
        let draft = harness.server.seedDraft(
            name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: "other-uploader")
        let before = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: harness.server, currentClientUID: "this-uploader",
            replacementJournal: harness.journal)

        let result = try await pipeline.resolve(descriptor)

        XCTAssertEqual(result.decision, .skip(.draftExists, remoteLinkID: draft.nodeID))
        let journal = harness.journal.entry(for: source)
        XCTAssertNil(journal.keptDeleted)
        XCTAssertTrue(journal.retired.isEmpty)
        XCTAssertEqual(journal.superseded, [PhotoUID(volumeID: "", nodeID: restored.nodeID)])
        let after = try await harness.server.findDuplicates(nameHashes: ["nh(current.heic)"])
        XCTAssertEqual(after, before)
        XCTAssertEqual(harness.server.uploadRequestCount, 0)
        try harness.relaunch()
        XCTAssertEqual(harness.journal.entry(for: source), journal)
    }

    private func fixture(
        server: EditScenarioServer, owner: String? = "other-uploader"
    ) -> (UploadDedupePipeline, UploadResourceDescriptor, PhotoUID) {
        let url = URL(fileURLWithPath: "/fixture/current.heic")
        let descriptor = UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: "current.heic", fileSize: 20,
            modificationDate: Date(timeIntervalSince1970: 1_720_000_000),
            precomputedSHA1Digest: Data(repeating: 1, count: 20))
        let draft = server.seedDraft(name: descriptor.filename, digest: Data(repeating: 3, count: 20), clientUID: owner)
        let pipeline = UploadDedupePipeline(
            store: FakeIdentityStore(), checker: server, currentClientUID: "this-uploader")
        return (pipeline, descriptor, draft)
    }
}
