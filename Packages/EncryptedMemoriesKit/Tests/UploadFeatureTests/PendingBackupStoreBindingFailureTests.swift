import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Every text bind of the pending backup store checks its result (#1194). A failed bind leaves its parameter NULL. An
/// unchecked key bind made a keyed read answer "no pending state" for a source that has one, and made an update change
/// nothing while it reported success. When a person put a deleted photo back, the photo then stayed excluded from
/// backup. The guard tests fail only the binds of one statement through `BindFailureUntilStep`, because SQLITE_NOMEM
/// need not fail every statement of a call.
final class PendingBackupStoreBindingFailureTests: XCTestCase {
    /// The store's statements prepare and a row with a short key fits under this limit; only the longer key fails.
    private static let limit: Int32 = 128
    private static let keyedStateRead = "FROM source_state WHERE source_kind=? AND source_id=?"

    private let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: String(repeating: "x", count: 300))
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private var directory: URL!
    private var store: PendingBackupManifestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(PendingBackupManifestStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    private func connection() throws -> SQLiteStoreConnection { try storeConnection(store!) }

    private func assertBindFailureRecorded(file: StaticString = #filePath, line: UInt = #line) throws {
        assertRecordedBindFailure(on: try connection(), file: file, line: line)
    }

    /// The stored desired state of every source, read through a separate connection.
    private func storedDesiredStates() throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT ifnull(source_id, 'NULL') || '/' || desired FROM source_state ORDER BY 1;", -1,
                &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }

    private func excludeSource() throws {
        XCTAssertNotNil(store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date))
        XCTAssertEqual(try storedDesiredStates(), ["\(key.identifier)/excluded"])
    }

    /// The keyed read binds no key. Before, it answered "no pending state", so a restore from the Proton trash skipped
    /// the source and the photo stayed excluded from backup.
    func testSourceStateReadWithAKeyThatDoesNotBindIsUnreadable() throws {
        try excludeSource()
        let fault = BindFailureUntilStep(
            on: try connection(), statement: Self.keyedStateRead, after: nil, limit: Self.limit)
        defer { fault.remove() }

        let read = store.sourceStateRead(for: key)

        XCTAssertEqual(read, .unreadable, "A key that does not bind is no proof that the source has no pending state")
        XCTAssertFalse(fault.stepped, "A read whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    /// The state read of `include` binds no key. Before, the source looked never excluded, `include` skipped it and
    /// reported success, and the photo stayed excluded from backup.
    func testIncludeWhoseStateReadDoesNotBindFailsAndKeepsTheSourceExcluded() throws {
        try excludeSource()
        let fault = BindFailureUntilStep(
            on: try connection(), statement: Self.keyedStateRead, after: nil, limit: Self.limit)
        defer { fault.remove() }

        let included = store.include([key], at: date)

        XCTAssertNil(included, "An include whose state read did not bind must fail, so the caller tries again")
        XCTAssertFalse(fault.stepped, "A read whose bind failed must not run")
        fault.remove()
        XCTAssertEqual(try storedDesiredStates(), ["\(key.identifier)/excluded"])
        try assertBindFailureRecorded()
    }

    /// Only the update of `include` binds no key. Before, the update changed no row, `include` reported success with
    /// the unchanged excluded state, and the photo stayed excluded from backup.
    func testIncludeWhoseUpdateAloneDoesNotBindFails() throws {
        try excludeSource()
        // The limit is lowered when the trash metadata deletion ends and restored when the update steps.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "SET desired='included'",
            after: "DELETE FROM pending_info WHERE key GLOB", limit: Self.limit)
        defer { fault.remove() }

        let included = store.include([key], at: date)

        XCTAssertNil(included, "An include whose update did not bind must fail, so the caller tries again")
        XCTAssertTrue(fault.lowered, "The fault reached the update")
        XCTAssertFalse(fault.stepped, "An update whose bind failed must not run")
        fault.remove()
        XCTAssertEqual(try storedDesiredStates(), ["\(key.identifier)/excluded"])
        try assertBindFailureRecorded()
    }

    func testReplayedHandoffWhoseTimeReadDoesNotBindPublishesNoEventOrReplacement() async throws {
        let source = UploadSourceIdentity(kind: key.kind, identifier: key.identifier, resource: .primary)
        let earlier = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 1),
            remote: PhotoUID(volumeID: "volume", nodeID: "earlier"), kind: .uploaded, createdAt: date)
        let current = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 2),
            remote: PhotoUID(volumeID: "volume", nodeID: "current"), kind: .uploaded,
            createdAt: date.addingTimeInterval(10))
        for handoff in [earlier, current] { XCTAssertEqual(store.recordHandoff(handoff), .recorded) }
        let ledger = PendingReplacementLedger()
        ledger.record(key, revision: earlier.revision, replaces: [PhotoUID(volumeID: "volume", nodeID: "replaced")])
        let replayTime = date.addingTimeInterval(20)
        let recorder = PendingBackupEventRecorder(store: store, replacementLedger: ledger, now: { replayTime })
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "FROM handoff WHERE source_kind=? AND source_id=? AND revision_us=?",
            after: "COMMIT", limit: Self.limit)
        defer { fault.remove() }

        let result = recorder.recordHandoff(
            source: source, revision: earlier.revision, remote: earlier.remote, kind: .uploaded)
        recorder.finish()
        var events: [PendingRuntimeEvent] = []
        for await event in recorder.events { events.append(event) }

        XCTAssertTrue(fault.lowered, "The handoff transaction must commit before the time read fails")
        XCTAssertFalse(fault.stepped, "The follow-up read whose key bind failed must not step")
        XCTAssertEqual(result, .failed, "A durable write with an unreadable time must remain retryable")
        XCTAssertEqual(events, [], "A failed time read must not publish the replay with the current clock time")
        XCTAssertTrue(ledger.replacementHandoffs().isEmpty, "The unreadable handoff must not reach replacement state")
        fault.remove()
        try assertBindFailureRecorded()
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .readable(current))

        let retry = PendingBackupEventRecorder(store: store, replacementLedger: ledger, now: { replayTime })
        XCTAssertEqual(
            retry.recordHandoff(source: source, revision: earlier.revision, remote: earlier.remote, kind: .uploaded),
            .recorded)
        retry.finish()
        var retryEvents: [PendingRuntimeEvent] = []
        for await event in retry.events { retryEvents.append(event) }
        XCTAssertEqual(retryEvents, [.handoff(earlier, .recorded)], "Retry must publish the original stored time")
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .readable(current))
    }

    func testLatestHandoffWhoseKeyDoesNotBindIsUnreadableWithoutLosingTheNextKey() throws {
        let healthyKey = PendingSourceKey(kind: .photoLibraryAsset, identifier: "healthy")
        let remote = PhotoUID(volumeID: "volume", nodeID: "photo")
        let handoffs = [key, healthyKey].map {
            PendingHandoff(
                key: $0, revision: UploadBackupRevision(rawValue: 1), remote: remote,
                kind: .uploaded, createdAt: date)
        }
        for handoff in handoffs { XCTAssertEqual(store.recordHandoff(handoff), .recorded) }
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .readable(handoffs[0]))
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "ORDER BY created_at DESC, revision_us DESC LIMIT 1",
            after: nil, limit: Self.limit)
        defer { fault.remove() }

        let reads = store.latestHandoffsRead(for: [key, healthyKey])

        XCTAssertEqual(reads[key], .unreadable, "A failed handoff key bind must not prove absence")
        XCTAssertEqual(reads[healthyKey], .readable(handoffs[1]), "The next key keeps its independent answer")
        fault.remove()
        try assertBindFailureRecorded()
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .readable(handoffs[0]))
    }

    func testCompletionWhoseOwnershipKeyDoesNotBindCannotSettleAnotherGeneration() throws {
        let remote = PhotoUID(volumeID: "volume", nodeID: "photo")
        let state = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date)?.first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [state]), [key])
        XCTAssertNotNil(store.include([key], at: date))
        let newer = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date)?.first)
        XCTAssertGreaterThan(newer.generation, state.generation)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [newer]), [key])
        let before = try XCTUnwrap(store.sourceState(for: key))
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "FROM remote_operation WHERE source_kind=? AND source_id=?",
            after: Self.keyedStateRead, limit: Self.limit)
        defer { fault.remove() }

        let result = store.completeEffectResult(
            .remoteTrash, for: key, generation: state.generation, remoteLinkID: remote.nodeID, at: date)

        XCTAssertEqual(result, .failed, "A failed ownership bind must not grant legacy completion permission")
        XCTAssertTrue(fault.lowered, "The source read must finish before the ownership bind fails")
        XCTAssertFalse(fault.stepped, "An ownership read whose bind failed must not run")
        fault.remove()
        try assertBindFailureRecorded()
        let reopened = try XCTUnwrap(PendingBackupManifestStore(url: databaseURL))
        defer { reopened.close() }
        XCTAssertEqual(reopened.sourceState(for: key), before, "The newer operation and its trash duty must stay")
    }

    func testFailedEvidenceBindWritesNothing() throws {
        let revision = UploadBackupRevision(rawValue: 1)
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO upload_evidence", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertFalse(store.recordUploadEvidence(key, revision: revision, at: date))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertTrue(store.evidenceRevisions().isEmpty)
        try assertBindFailureRecorded()
    }

    func testFailedEvidenceRemovalRollsBackAnEarlierRemoval() throws {
        let short = PendingSourceKey(kind: .photoLibraryAsset, identifier: "short")
        let revision = UploadBackupRevision(rawValue: 1)
        for source in [short, key] { XCTAssertTrue(store.recordUploadEvidence(source, revision: revision, at: date)) }
        let before = store.evidenceRevisions()
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "DELETE FROM upload_evidence",
            after: "DELETE FROM upload_evidence", limit: Self.limit)
        defer { fault.remove() }

        XCTAssertFalse(store.removeEvidence([(short, revision), (key, revision)]))

        XCTAssertTrue(fault.lowered, "The first removal must finish before the second bind fails")
        XCTAssertFalse(fault.stepped, "The second removal must not step")
        fault.remove()
        XCTAssertEqual(store.evidenceRevisions(), before, "The transaction must also restore the first revision")
        try assertBindFailureRecorded()
    }

    func testReverseHandoffLookupWithAFailedLinkBindIsUnreadable() throws {
        let handoff = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 1),
            remote: PhotoUID(volumeID: "volume", nodeID: key.identifier), kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "FROM handoff WHERE remote_link_id=?", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertEqual(store.handoffsRead(forRemoteLinkIDs: [key.identifier]), .unreadable)

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(store.handoffsRead(forRemoteLinkIDs: [key.identifier]), .complete([handoff]))
        try assertBindFailureRecorded()
    }

    func testFailedHandoffAcknowledgementKeepsTheReceiptUnacknowledged() throws {
        let handoff = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 1),
            remote: PhotoUID(volumeID: "volume", nodeID: "photo"), kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "UPDATE handoff SET acknowledged=1", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertFalse(store.acknowledgeHandoffs([(key, handoff.revision)]))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])
        try assertBindFailureRecorded()
    }

    func testFailedExclusionLookupDoesNotPermitAnUpload() throws {
        try excludeSource()
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "SELECT source_kind, source_id, desired, remote_op",
            after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertNil(store.exclusions(kind: key.kind, among: [key.identifier]))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(try storedDesiredStates(), ["\(key.identifier)/excluded"])
        try assertBindFailureRecorded()
    }

    func testFailedOptionalRemoteBindDoesNotStoreAnExclusionWithoutItsTarget() throws {
        let short = PendingSourceKey(kind: .photoLibraryAsset, identifier: "short")
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO source_state", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: short, presentation: nil,
                        remote: PhotoUID(volumeID: "volume", nodeID: key.identifier))
                ], at: date))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(try storedDesiredStates(), [])
        try assertBindFailureRecorded()
    }

    func testFailedPresentationBindDoesNotStoreAnExclusionWithoutItsDisplayName() throws {
        let short = PendingSourceKey(kind: .photoLibraryAsset, identifier: "short")
        let presentation = PendingPresentationMetadata(
            captureTime: date, mediaType: "image", displayName: key.identifier)
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO source_state", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertNil(
            store.exclude([PendingExclusionRequest(key: short, presentation: presentation, remote: nil)], at: date))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(try storedDesiredStates(), [])
        try assertBindFailureRecorded()
    }

    func testFailedSavedIdentifierBindDoesNotInsertANullKey() throws {
        let connection = try connection()
        let changes = connection.withLock { sqlite3_total_changes(connection.database) }
        let fault = BindFailureUntilStep(
            on: connection, statement: "INSERT INTO saved_from_app", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertFalse(
            store.recordSavedFromApp(
                localIdentifier: key.identifier,
                remote: PhotoUID(volumeID: "volume", nodeID: "photo"), at: date))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(
            connection.withLock { sqlite3_total_changes(connection.database) }, changes,
            "Even a hidden NULL-key row would count as a change")
        XCTAssertEqual(store.savedFromAppIdentifiers(), [])
        try assertBindFailureRecorded()
    }

    func testFailedActionIdentityBindStopsEveryWriterAndKeepsTheStoredAction() throws {
        let short = PendingSourceKey(kind: key.kind, identifier: "short")
        let variants = [("source_id", key, "album"), ("album_id", short, key.identifier)]
        let operations: [(String, String, (PendingAction) -> Bool)] = [
            ("retry", "UPDATE pending_action SET attempts=attempts+1", { self.store.retryAction($0, at: self.date) }),
            ("fail", "UPDATE pending_action SET failed=1", { self.store.failAction($0) }),
            ("complete", "DELETE FROM pending_action", { self.store.completeAction($0) }),
        ]
        for (column, source, album) in variants {
            for (operation, statement, write) in operations {
                let context = "\(column), \(operation)"
                XCTAssertTrue(store.addAlbumIntent(source, albumID: album, at: date), context)
                let before = store.actionsRead()
                XCTAssertTrue(before.complete, context)
                XCTAssertEqual(before.actions.count, 1, context)
                let action = try XCTUnwrap(before.actions.first, context)
                do {
                    let fault = BindFailureUntilStep(
                        on: try connection(), statement: statement, after: nil, limit: Self.limit)
                    defer { fault.remove() }

                    XCTAssertFalse(write(action), context)
                    XCTAssertTrue(fault.lowered, context)
                    XCTAssertFalse(fault.stepped, "The failed identity bind must stop the statement: \(context)")
                    fault.remove()
                    try assertBindFailureRecorded()
                    XCTAssertEqual(store.actionsRead(), before, context)
                }
                store.close()
                store = try XCTUnwrap(PendingBackupManifestStore(url: databaseURL))
                XCTAssertEqual(store.actionsRead(), before, "Reopening must keep the complete action: \(context)")
                XCTAssertTrue(store.completeAction(action), context)
                XCTAssertEqual(store.actions(), [], context)
            }
        }
    }

    func testFailedAlbumIdentifierBindDoesNotStoreAnAction() throws {
        let short = PendingSourceKey(kind: .photoLibraryAsset, identifier: "short")
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO pending_action", after: nil, limit: Self.limit)
        defer { fault.remove() }

        XCTAssertFalse(store.addAlbumIntent(short, albumID: key.identifier, at: date))

        XCTAssertFalse(fault.stepped)
        fault.remove()
        XCTAssertEqual(store.actionsRead(), PendingActionsRead(actions: [], complete: true))
        try assertBindFailureRecorded()
    }
}
