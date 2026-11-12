import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class EditedPhotoReplacementCancellationTests: XCTestCase {
    private enum Route: String { case remoteTarget, replacement, unproven }

    func testCancellationDuringAnUnprovenReadPreservesItsErrorAndTheJournal() async throws {
        try await assertCancellation(at: .unproven)
    }

    func testCancellationDuringARemoteTargetReadPreservesItsErrorAndTheJournal() async throws {
        try await assertCancellation(at: .remoteTarget)
    }

    func testCancellationDuringAReplacementReadPreservesItsErrorAndTheJournal() async throws {
        try await assertCancellation(at: .replacement)
    }

    private func assertCancellation(at route: Route) async throws {
        for scenario in CancellationReadFault.Scenario.allCases {
            let context = "\(route.rawValue)/\(scenario.rawValue)"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("replacement-cancellation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset")
            let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier")
            let replacement = PhotoUID(volumeID: "vol", nodeID: "replacement")
            if route == .unproven {
                try journal.addSuperseded(earlier, for: source)
            } else {
                try journal.addRemoteSuperseded(earlier, for: source)
            }
            let before = journal.entry(for: source)
            let remote = FakeEditReplacementRemote()
            remote.active = [earlier, replacement]
            let checker = FakeChecker()
            if route != .unproven {
                checker.compoundsByMainLinkID[earlier.nodeID] = UploadRemoteCompound(
                    main: .init(
                        linkID: earlier.nodeID, contentHash: "content", nameHash: "name", mimeType: "image/jpeg"),
                    related: [], tags: [], externalIdentifier: "cloud",
                    captureDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))
                checker.externalMainLinks["cloud"] = (links: [earlier.nodeID], complete: true)
                checker.replacedLinks[earlier.nodeID] = (links: [], complete: true)
                checker.replacingLinks[earlier.nodeID] = (links: [], complete: true)
            }
            let fault = CancellationReadFault(scenario)
            let faultedLink = route == .replacement ? replacement.nodeID : earlier.nodeID
            checker.compoundErrorsByMainLinkID[faultedLink] = [fault.error]
            checker.onCompoundRead = { link in if link == faultedLink { fault.read() } }
            let executor = EditedPhotoReplacement(
                remote: remote, albums: FakeAlbumCarryOver(), relations: checker,
                identities: FakeIdentityStore(), journal: journal)
            let operation = Task {
                try await executor.replaceSuperseded(
                    of: source, with: replacement, edited: true, holdsOriginal: true,
                    externalIdentifier: "cloud", localEditTime: Date(timeIntervalSince1970: 2),
                    localCreationDate: Date(timeIntervalSince1970: 1), externalIdentifierIsUnique: true)
            }
            do {
                _ = try await operation.value
                XCTFail("\(context): cancellation must leave the replacement unsettled")
            } catch {
                fault.assertCaught(error, context: context)
            }
            fault.assertRead(context)
            XCTAssertEqual(checker.compoundErrorsByMainLinkID[faultedLink]?.count, 0, context)
            XCTAssertEqual(journal.entry(for: source), before, context)
            XCTAssertTrue(remote.trashCalls.isEmpty, context)
        }
    }
}
