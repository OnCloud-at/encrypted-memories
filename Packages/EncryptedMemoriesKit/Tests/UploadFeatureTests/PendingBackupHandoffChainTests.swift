import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class PendingBackupHandoffChainTests: XCTestCase {
    // This store sequence does not establish that the production runner can generate both late handoffs.
    func testMiddleHandoffRemainsDueAfterOriginalAndLatestTrashComplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-handoff-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        defer { store.close() }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "handoff-chain-asset")
        let original = PhotoUID(volumeID: "vol", nodeID: "upload-A")
        let middle = PhotoUID(volumeID: "vol", nodeID: "upload-B")
        let latest = PhotoUID(volumeID: "vol", nodeID: "upload-C")

        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: original)], at: date))
        let generation = try XCTUnwrap(excluded.first).generation
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: generation, at: date))
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])

        for (revision, remote) in [(Int64(2), middle), (Int64(3), latest)] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key, revision: UploadBackupRevision(rawValue: revision), remote: remote,
                        kind: .uploaded, createdAt: date.addingTimeInterval(Double(revision)))),
                .excludedRemoteNeedsTrash)
        }
        let waiting = try XCTUnwrap(store.sourceStateRead(for: key).state)
        XCTAssertEqual(waiting.remote, original, "both handoffs must preserve A's outstanding trash")
        XCTAssertTrue(waiting.needsRemoteTrash)
        XCTAssertEqual(waiting.remoteOperation, .remoteTrash)
        XCTAssertEqual(
            Set(store.handoffs(forRemoteLinkIDs: [middle.nodeID, latest.nodeID]).map(\.remote)),
            [middle, latest], "B and C must both be durable before A completes")

        let originalCompletion = date.addingTimeInterval(4)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: original.nodeID, at: originalCompletion))
        let next = try XCTUnwrap(store.sourceStateRead(for: key).state)
        XCTAssertEqual(next.remote, latest, "the latest-handoff resume selects C after A")
        XCTAssertTrue(next.needsRemoteTrash)
        XCTAssertFalse(next.remoteTrashed)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [next]), [key])

        let latestCompletion = date.addingTimeInterval(5)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: generation, remoteLinkID: latest.nodeID, at: latestCompletion))

        let remaining = store.dueSourceStatesRead(by: latestCompletion)
        XCTAssertTrue(remaining.complete, "a failed read cannot prove that no trash remains due")
        XCTAssertEqual(
            remaining.states.filter { $0.key == key && $0.needsRemoteTrash }.compactMap(\.remote),
            [middle], "B must still be scheduled after A and C complete; B has never completed trash")
    }
}
