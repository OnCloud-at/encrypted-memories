import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class ExactDuplicateFingerprintStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName) }
    private let scope = ExactDuplicateFingerprintStore.Scope(
        accountID: "account", volumeID: "volume", hashKeyEpoch: "epoch")
    private let first = PhotoUID(volumeID: "volume", nodeID: "first")
    private let second = PhotoUID(volumeID: "volume", nodeID: "second")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func open() throws -> ExactDuplicateFingerprintStore {
        try XCTUnwrap(ExactDuplicateFingerprintStore(url: url, cacheDirectory: directory))
    }

    private func details(_ device: String = "camera") -> ExactDuplicateFingerprint {
        ExactDuplicateFingerprint(
            captureTime: Date(timeIntervalSince1970: 1_700_000_000.125), latitude: 12.25, longitude: -34.5,
            device: device, pixelWidth: 1920, pixelHeight: 1080, durationSeconds: 1.125, mimeType: "image/heic")
    }

    private var group: ExactDuplicateGroup {
        ExactDuplicateGroup(contentHash: "content", hashKeyEpoch: "epoch", members: [first, second])
    }

    func testReopenedStoredFingerprintsSplitDifferentMetadata() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let expected = [first: details(), second: details("other-camera")]
        XCTAssertTrue(store.store(expected, for: snapshot))
        store.close()

        let reopened = try open()
        defer { reopened.close() }
        let current = try XCTUnwrap(reopened.prepare(scope: scope, eventID: "event"))
        XCTAssertEqual(current, snapshot)
        let saved = try XCTUnwrap(reopened.fingerprints(for: group.members, in: current))
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(group.split(by: saved), [])
    }

    func testEqualMetadataSurvivesButAnUnknownMemberKeepsTheWholeGroup() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details(), second: details()], for: snapshot))
        let saved = try XCTUnwrap(store.fingerprints(for: group.members, in: snapshot))
        XCTAssertEqual(group.split(by: saved).map(\.members), [group.members])
        let unknown = PhotoUID(volumeID: "volume", nodeID: "unknown")
        let partial = ExactDuplicateGroup(
            contentHash: "content", hashKeyEpoch: "epoch", members: [first, second, unknown])
        XCTAssertNil(store.fingerprints(for: partial.members, in: snapshot))
    }

    func testEverySDKFieldAndNodeOnlyIdentitySurvivesPersistence() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let variants: [ExactDuplicateFingerprint] = [
            details(), ExactDuplicateFingerprint(), .matchingOnly(first),
            .init(captureTime: Date(timeIntervalSince1970: 0)), .init(latitude: 0), .init(longitude: 0),
            .init(device: ""), .init(pixelWidth: 0), .init(pixelHeight: 0), .init(durationSeconds: 0),
            .init(mimeType: ""),
        ]
        for expected in variants {
            XCTAssertTrue(store.store([first: expected], for: snapshot))
            XCTAssertEqual(store.fingerprints(for: [first], in: snapshot), [first: expected])
        }
        XCTAssertTrue(store.store([first: .matchingOnly(first), second: .matchingOnly(second)], for: snapshot))
        let matchingOnly = try XCTUnwrap(store.fingerprints(for: group.members, in: snapshot))
        XCTAssertEqual(group.split(by: matchingOnly), [])
    }

    func testEachScopeComponentAndCursorChangeDiscardsThePreviousSnapshot() throws {
        let variants: [(ExactDuplicateFingerprintStore.Scope, String)] = [
            (.init(accountID: "another-account", volumeID: "volume", hashKeyEpoch: "epoch"), "event"),
            (.init(accountID: "account", volumeID: "another-volume", hashKeyEpoch: "epoch"), "event"),
            (.init(accountID: "account", volumeID: "volume", hashKeyEpoch: "another-epoch"), "event"),
            (scope, "another-event"),
        ]
        let store = try open()
        defer { store.close() }
        for (changedScope, changedCursor) in variants {
            let before = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
            XCTAssertTrue(store.store([first: details()], for: before))
            let after = try XCTUnwrap(store.prepare(scope: changedScope, eventID: changedCursor))
            XCTAssertNotEqual(after, before)
            XCTAssertNil(store.fingerprints(for: [first], in: after))
            XCTAssertFalse(store.store([first: details()], for: before))
            XCTAssertNil(store.fingerprints(for: [first], in: before))
        }
    }

    func testAnEventInvalidatesOnlyTouchedLinksAndRejectsLateRankingWrites() throws {
        let store = try open()
        defer { store.close() }
        let before = try XCTUnwrap(store.prepare(scope: scope, eventID: "before"))
        XCTAssertTrue(store.store([first: details(), second: details()], for: before))
        let after = try XCTUnwrap(store.advance(from: before, to: "after", invalidating: [first.nodeID]))
        XCTAssertNil(store.fingerprints(for: [first], in: after))
        XCTAssertEqual(store.fingerprints(for: [second], in: after), [second: details()])
        XCTAssertNil(store.fingerprints(for: [second], in: before))
        XCTAssertFalse(store.store([first: details()], for: before))
        XCTAssertNil(store.advance(from: before, to: "late", invalidating: []))
        XCTAssertEqual(store.prepare(scope: scope, eventID: "after"), after)
        XCTAssertNil(store.fingerprints(for: [first], in: after))
        XCTAssertTrue(store.store([first: details("updated")], for: after))
        XCTAssertEqual(store.fingerprints(for: [first], in: after), [first: details("updated")])
    }

    func testInvalidationAtTheSameCursorStillRevokesAnEarlierRead() throws {
        let store = try open()
        defer { store.close() }
        let before = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details()], for: before))
        XCTAssertNil(store.advance(from: before, to: "", invalidating: [first.nodeID]))
        XCTAssertEqual(store.fingerprints(for: [first], in: before), [first: details()])
        let after = try XCTUnwrap(store.advance(from: before, to: "event", invalidating: [first.nodeID]))
        XCTAssertNotEqual(after, before)
        XCTAssertFalse(store.store([first: details()], for: before))
        XCTAssertNil(store.fingerprints(for: [first], in: after))
    }

    func testInvalidBatchCannotPartiallyReplaceSavedMetadata() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details()], for: snapshot))
        let foreign = PhotoUID(volumeID: "foreign-volume", nodeID: "foreign")
        XCTAssertFalse(store.store([first: details("wrong"), foreign: details()], for: snapshot))
        XCTAssertEqual(store.fingerprints(for: [first], in: snapshot), [first: details()])
        XCTAssertFalse(store.store([first: .matchingOnly(second)], for: snapshot))
        XCTAssertEqual(store.fingerprints(for: [first], in: snapshot), [first: details()])
        XCTAssertFalse(store.store([first: .init(durationSeconds: .infinity)], for: snapshot))
        XCTAssertEqual(store.fingerprints(for: [first], in: snapshot), [first: details()])
    }

    func testUnusableContextAndClosedStoreKeepTheExistingRankingPath() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertNil(store.prepare(scope: scope, eventID: ""))
        XCTAssertNil(
            store.prepare(scope: .init(accountID: "", volumeID: "volume", hashKeyEpoch: "epoch"), eventID: "event"))
        XCTAssertNil(
            store.prepare(scope: .init(accountID: "account", volumeID: "", hashKeyEpoch: "epoch"), eventID: "event"))
        XCTAssertNil(
            store.prepare(scope: .init(accountID: "account", volumeID: "volume", hashKeyEpoch: ""), eventID: "event"))
        store.close()
        XCTAssertNil(store.prepare(scope: scope, eventID: "event"))
        XCTAssertFalse(store.store([first: details()], for: snapshot))
        XCTAssertNil(store.fingerprints(for: [first], in: snapshot))
    }

    func testAGroupCannotUseDetailsOfAnotherEpochOrVolume() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details(), second: details("different")], for: snapshot))
        let otherEpoch = ExactDuplicateGroup(
            contentHash: "content", hashKeyEpoch: "other-epoch", members: group.members)
        XCTAssertEqual(store.fingerprints(ofGroups: [otherEpoch], in: snapshot), [:])
        let foreign = PhotoUID(volumeID: "foreign-volume", nodeID: first.nodeID)
        XCTAssertNil(store.fingerprints(for: [foreign], in: snapshot))
    }

    func testMalformedSavedDetailsFallBackInsteadOfRemovingTheGroup() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details(), second: details("different")], for: snapshot))
        store.close()
        try changeDatabase("UPDATE fingerprint SET payload=x'00' WHERE link_id='first';")
        let reopened = try open()
        defer { reopened.close() }
        let current = try XCTUnwrap(reopened.prepare(scope: scope, eventID: "event"))
        XCTAssertNil(reopened.fingerprints(for: group.members, in: current))
        reopened.close()
        try changeDatabase("PRAGMA user_version=2;")
        let unknownVersion = try open()
        defer { unknownVersion.close() }
        let reset = try XCTUnwrap(unknownVersion.prepare(scope: scope, eventID: "event"))
        XCTAssertNil(unknownVersion.fingerprints(for: [second], in: reset))
    }

    func testOneReadReturnsTheDetailsOfEveryCompleteGroupAndLeavesTheOthersOut() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let third = PhotoUID(volumeID: "volume", nodeID: "third")
        let fourth = PhotoUID(volumeID: "volume", nodeID: "fourth")
        let unknown = PhotoUID(volumeID: "volume", nodeID: "unknown")
        let saved = [first: details(), second: details("different"), third: details(), fourth: details()]
        XCTAssertTrue(store.store(saved, for: snapshot))
        let complete = ExactDuplicateGroup(contentHash: "a", hashKeyEpoch: "epoch", members: [first, second])
        let withUnknownMember = ExactDuplicateGroup(contentHash: "b", hashKeyEpoch: "epoch", members: [third, unknown])
        let anotherEpoch = ExactDuplicateGroup(contentHash: "c", hashKeyEpoch: "another", members: [third, fourth])
        let anotherVolume = ExactDuplicateGroup(
            contentHash: "d", hashKeyEpoch: "epoch", members: [PhotoUID(volumeID: "other", nodeID: "third"), fourth])

        let read = store.fingerprints(
            ofGroups: [complete, withUnknownMember, anotherEpoch, anotherVolume], in: snapshot)

        XCTAssertEqual(Set(read.keys), [first, second], "only the complete group of this scope is returned")
        XCTAssertEqual(read[first], details())
        XCTAssertEqual(read[second], details("different"))
    }

    func testOneReadReturnsNothingForAStaleSnapshotAndSkipsAGroupWithACorruptRow() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details(), second: details("different")], for: snapshot))
        let groups = [ExactDuplicateGroup(contentHash: "a", hashKeyEpoch: "epoch", members: [first, second])]
        let later = try XCTUnwrap(store.advance(from: snapshot, to: "event-2", invalidating: []))

        XCTAssertTrue(store.fingerprints(ofGroups: groups, in: snapshot).isEmpty, "the earlier snapshot is stale")
        XCTAssertEqual(store.fingerprints(ofGroups: groups, in: later).count, 2)
        store.close()
        try changeDatabase("UPDATE fingerprint SET payload=x'00' WHERE link_id='second';")
        let reopened = try open()
        defer { reopened.close() }
        let current = try XCTUnwrap(reopened.prepare(scope: scope, eventID: "event-2"))
        XCTAssertTrue(
            reopened.fingerprints(ofGroups: groups, in: current).isEmpty, "a corrupt row leaves its group out")
    }

    func testAFailedInvalidationCannotPublishAPartialSnapshot() throws {
        let store = try open()
        let before = try XCTUnwrap(store.prepare(scope: scope, eventID: "before"))
        let values = [first: details(), second: details("different")]
        XCTAssertTrue(store.store(values, for: before))
        store.close()
        for target in ["INSERT ON fingerprint_context", "DELETE ON fingerprint"] {
            let opened = try open()
            try changeDatabase(
                """
                CREATE TRIGGER reject_write BEFORE \(target)
                BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;
                """)
            XCTAssertNil(opened.advance(from: before, to: "after", invalidating: [first.nodeID]))
            XCTAssertNil(opened.fingerprints(for: group.members, in: before))
            try changeDatabase("DROP TRIGGER reject_write;")
            opened.close()
            let reopened = try open()
            let restored = try XCTUnwrap(reopened.prepare(scope: scope, eventID: "before"))
            XCTAssertEqual(restored, before)
            XCTAssertEqual(reopened.fingerprints(for: group.members, in: restored), values)
            reopened.close()
        }
    }

    func testRecoveryNeverOpensAnotherFilenameOrFollowsASymlink() throws {
        let protected = directory.appendingPathComponent("upload-manifest-v1.sqlite")
        let authoritative = try XCTUnwrap(UploadIdentityManifestStore(url: protected))
        authoritative.close()
        let original = try Data(contentsOf: protected)
        XCTAssertNil(ExactDuplicateFingerprintStore(url: protected, cacheDirectory: directory))
        XCTAssertEqual(try Data(contentsOf: protected), original)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: protected)
        XCTAssertNil(ExactDuplicateFingerprintStore(url: url, cacheDirectory: directory))
        XCTAssertEqual(try Data(contentsOf: protected), original)
        try FileManager.default.removeItem(at: url)
        let differentlyCased = directory.appendingPathComponent(
            ExactDuplicateFingerprintStore.databaseFileName.uppercased())
        try FileManager.default.createSymbolicLink(at: differentlyCased, withDestinationURL: protected)
        XCTAssertNil(ExactDuplicateFingerprintStore(url: url, cacheDirectory: directory))
        XCTAssertEqual(try Data(contentsOf: protected), original)
    }

    func testMalformedGenerationDiscardsSavedDetailsAndCreatesAValidToken() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details()], for: snapshot))
        store.close()
        let malformed = ExactDuplicateFingerprintStore.Snapshot(
            scope: scope, eventID: "event", generation: "not-a-uuid")
        let payload = try JSONEncoder().encode(malformed).map { String(format: "%02x", $0) }.joined()
        try changeDatabase("UPDATE fingerprint_context SET payload=x'\(payload)' WHERE id=1;")

        let reopened = try open()
        defer { reopened.close() }
        let current = try XCTUnwrap(reopened.prepare(scope: scope, eventID: "event"))
        XCTAssertNotNil(UUID(uuidString: current.generation))
        XCTAssertNil(reopened.fingerprints(for: [first], in: current))
        XCTAssertFalse(reopened.store([first: details()], for: malformed))
    }

    func testASymlinkedAncestorOrForeignDirectoryCannotOpenTheCache() throws {
        let actual = directory.appendingPathComponent("actual", isDirectory: true)
        let cache = actual.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let aliasedFile = alias.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName)
        XCTAssertNil(ExactDuplicateFingerprintStore(url: aliasedFile, cacheDirectory: cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasedFile.path))

        let foreignFile = actual.appendingPathComponent(ExactDuplicateFingerprintStore.databaseFileName)
        XCTAssertNil(ExactDuplicateFingerprintStore(url: foreignFile, cacheDirectory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignFile.path))
    }

    func testAPathReadErrorRejectsCacheAdmission() {
        XCTAssertTrue(ExactDuplicateFingerprintStore.admitsPath(url, cacheDirectory: directory))
        var reads = 0
        XCTAssertFalse(
            ExactDuplicateFingerprintStore.admitsPath(url, cacheDirectory: directory) { _, _ in
                reads += 1
                throw CocoaError(.fileReadNoPermission)
            })
        XCTAssertEqual(reads, 1)
    }

    func testOpaqueCursorCanReturnToAnEarlierValueAndAlwaysDiscardsDetails() throws {
        let store = try open()
        defer { store.close() }
        let firstEvent = try XCTUnwrap(store.prepare(scope: scope, eventID: "E1"))
        XCTAssertTrue(store.store([first: details()], for: firstEvent))
        let secondEvent = try XCTUnwrap(store.prepare(scope: scope, eventID: "E2"))
        XCTAssertNil(store.fingerprints(for: [first], in: secondEvent))
        XCTAssertTrue(store.store([first: details("updated")], for: secondEvent))
        let returnedEvent = try XCTUnwrap(store.prepare(scope: scope, eventID: "E1"))
        XCTAssertEqual(returnedEvent.eventID, "E1")
        XCTAssertNotEqual(returnedEvent, firstEvent)
        XCTAssertNotEqual(returnedEvent, secondEvent)
        XCTAssertNil(store.fingerprints(for: [first], in: returnedEvent))
        XCTAssertFalse(store.store([first: details()], for: firstEvent))
        XCTAssertFalse(store.store([first: details()], for: secondEvent))
    }

    func testRepeatedGroupsKeepOnlyCompleteMetadataAfterMissingAndCorruptMembers() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let third = PhotoUID(volumeID: "volume", nodeID: "third")
        let fourth = PhotoUID(volumeID: "volume", nodeID: "fourth")
        let missing = PhotoUID(volumeID: "volume", nodeID: "missing")
        let values = [first: details("first"), second: details("second"), third: details("third")]
        XCTAssertTrue(store.store(values.merging([fourth: details()]) { first, _ in first }, for: snapshot))
        try changeDatabase("UPDATE fingerprint SET payload=x'00' WHERE link_id='fourth';")
        let groups = [
            ExactDuplicateGroup(contentHash: "missing", hashKeyEpoch: "epoch", members: [first, missing]),
            ExactDuplicateGroup(contentHash: "corrupt", hashKeyEpoch: "epoch", members: [second, fourth]),
            ExactDuplicateGroup(contentHash: "good", hashKeyEpoch: "epoch", members: [first, third]),
            ExactDuplicateGroup(contentHash: "overlap", hashKeyEpoch: "epoch", members: [second, third]),
        ]
        XCTAssertEqual(store.fingerprints(ofGroups: groups, in: snapshot), values)
        XCTAssertEqual(store.fingerprints(ofGroups: Array(groups.reversed()), in: snapshot), values)
        store.close()
    }

    func testManyInvalidatedLinksLeaveUntouchedMetadataAndRevokeTheOldSnapshot() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let third = PhotoUID(volumeID: "volume", nodeID: "third")
        XCTAssertTrue(store.store([first: details(), second: details(), third: details("kept")], for: snapshot))
        let next = try XCTUnwrap(
            store.advance(from: snapshot, to: "next", invalidating: [first.nodeID, second.nodeID]))
        XCTAssertEqual(store.fingerprints(ofGroups: [group], in: next), [:])
        let survivor = ExactDuplicateGroup(contentHash: "kept", hashKeyEpoch: "epoch", members: [third])
        XCTAssertEqual(store.fingerprints(ofGroups: [survivor], in: next), [third: details("kept")])
        XCTAssertEqual(store.fingerprints(ofGroups: [survivor], in: snapshot), [:])
    }

    func testFingerprintReadBindFailureIsRecordedInsteadOfBecomingAMissingRow() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let long = PhotoUID(volumeID: "volume", nodeID: String(repeating: "x", count: 512))
        XCTAssertTrue(store.store([long: details()], for: snapshot))
        let connection = try storeConnection(store)
        let fault = BindFailureUntilStep(
            on: connection, statement: "SELECT payload FROM fingerprint WHERE",
            after: "SELECT payload FROM fingerprint_context",
            limit: 128)
        defer { fault.remove() }
        let group = ExactDuplicateGroup(contentHash: "long", hashKeyEpoch: "epoch", members: [long])
        XCTAssertEqual(store.fingerprints(ofGroups: [group], in: snapshot), [:])
        XCTAssertTrue(fault.lowered)
        XCTAssertFalse(fault.stepped)
        assertRecordedBindFailure(on: connection)
    }

    func testFingerprintDeleteBindFailureKeepsThePreviousSnapshotAndRows() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let long = PhotoUID(volumeID: "volume", nodeID: String(repeating: "x", count: 512))
        XCTAssertTrue(store.store([long: details()], for: snapshot))
        let connection = try storeConnection(store)
        let fault = BindFailureUntilStep(
            on: connection, statement: "DELETE FROM fingerprint WHERE",
            after: "SELECT payload FROM fingerprint_context",
            limit: 128)
        XCTAssertNil(store.advance(from: snapshot, to: "next", invalidating: [long.nodeID]))
        XCTAssertTrue(fault.lowered)
        XCTAssertFalse(fault.stepped)
        assertRecordedBindFailure(on: connection)
        fault.remove()
        store.close()
        let reopened = try open()
        defer { reopened.close() }
        XCTAssertEqual(reopened.prepare(scope: scope, eventID: "event"), snapshot)
        XCTAssertEqual(reopened.fingerprints(for: [long], in: snapshot), [long: details()])
    }

    func testFingerprintBlobBindingFailureStopsBeforeStepAndKeepsThePreviousRows() throws {
        let store = try open()
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details()], for: snapshot))
        let connection = try storeConnection(store)
        let fault = BindFailureUntilStep(
            on: connection, statement: "INSERT OR REPLACE INTO fingerprint VALUES",
            after: "SELECT payload FROM fingerprint_context", limit: 128)
        XCTAssertFalse(store.store([first: details(String(repeating: "x", count: 512))], for: snapshot))
        XCTAssertTrue(fault.lowered)
        XCTAssertFalse(fault.stepped, "a refused BLOB bind must not step the INSERT")
        assertRecordedBindFailure(on: connection)
        fault.remove()
        store.close()
        let reopened = try open()
        defer { reopened.close() }
        XCTAssertEqual(reopened.prepare(scope: scope, eventID: "event"), snapshot)
        XCTAssertEqual(reopened.fingerprints(for: [first], in: snapshot), [first: details()])
    }

    func testFingerprintReadStepFailureIsRecordedAndKeepsTheRankingPath() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        XCTAssertTrue(store.store([first: details(), second: details()], for: snapshot))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT payload FROM fingerprint WHERE")
        defer { fault.stop() }
        XCTAssertEqual(store.fingerprints(ofGroups: [group], in: snapshot), [:])
        XCTAssertTrue(fault.fired)
        let connection = try storeConnection(store)
        connection.withLock { XCTAssertTrue(connection.operationFailed) }
    }

    func testFingerprintPrepareFailuresAreRecordedButEmptyBatchesNeedNoStatement() throws {
        for action in [SQLITE_READ, SQLITE_DELETE] {
            let store = try open()
            let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
            XCTAssertTrue(store.store([first: details(), second: details()], for: snapshot))
            let connection = try storeConnection(store)
            try withSQLiteAuthorization(
                in: store,
                authorizing: { operation, table, _ in
                    operation == action && table == "fingerprint" ? SQLITE_DENY : SQLITE_OK
                },
                {
                    if action == SQLITE_READ {
                        XCTAssertEqual(store.fingerprints(ofGroups: [], in: snapshot), [:])
                        connection.withLock { XCTAssertFalse(connection.operationFailed) }
                        XCTAssertEqual(store.fingerprints(ofGroups: [group], in: snapshot), [:])
                    } else {
                        let next = store.advance(from: snapshot, to: "empty", invalidating: [])
                        XCTAssertNotNil(next, "an empty invalidation needs no delete statement")
                        if let next {
                            XCTAssertNil(store.advance(from: next, to: "next", invalidating: [first.nodeID]))
                        }
                    }
                    connection.withLock { XCTAssertTrue(connection.operationFailed) }
                }
            )
            store.close()
        }
    }

    func testMultipleReadsAndInvalidationsPrepareEachStatementOnce() throws {
        let store = try open()
        defer { store.close() }
        let snapshot = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let values = [first: details("first"), second: details("second")]
        XCTAssertTrue(store.store(values, for: snapshot))
        var counts: [Int32] = [0, 0]
        try withSQLiteAuthorization(
            in: store,
            authorizing: { operation, table, column in
                if table == "fingerprint" {
                    if operation == SQLITE_READ, column == "payload" { counts[0] += 1 }
                    if operation == SQLITE_DELETE { counts[1] += 1 }
                }
                return SQLITE_OK
            },
            {
                XCTAssertEqual(store.fingerprints(ofGroups: [group, group], in: snapshot), values)
                XCTAssertNotNil(store.advance(from: snapshot, to: "next", invalidating: [first.nodeID, second.nodeID]))
            }
        )
        XCTAssertEqual(counts, [1, 1], "one prepare serves every member or invalidation in its transaction")
    }

    func testSQLiteAuthorizationFiltersUpdatesAndCleansUpAfterReturnOrThrow() throws {
        let store = try open()
        defer { store.close() }
        _ = try XCTUnwrap(store.prepare(scope: scope, eventID: "event"))
        let connection = try storeConnection(store)
        for shouldThrow in [false, true] {
            do {
                try withSQLiteAuthorization(
                    in: store,
                    authorizing: { operation, table, _ in
                        operation == SQLITE_UPDATE && table == "fingerprint" ? SQLITE_DENY : SQLITE_OK
                    },
                    {
                        connection.withLock {
                            XCTAssertEqual(
                                sqlite3_exec(
                                    connection.database, "UPDATE fingerprint SET payload=payload;", nil, nil, nil),
                                SQLITE_AUTH)
                            XCTAssertEqual(
                                sqlite3_exec(
                                    connection.database, "UPDATE fingerprint_context SET payload=payload;", nil, nil,
                                    nil),
                                SQLITE_OK)
                        }
                        if shouldThrow { throw CancellationError() }
                    }
                )
                XCTAssertFalse(shouldThrow)
            } catch is CancellationError {
                XCTAssertTrue(shouldThrow)
            }
            connection.withLock {
                XCTAssertEqual(
                    sqlite3_exec(connection.database, "UPDATE fingerprint SET payload=payload;", nil, nil, nil),
                    SQLITE_OK)
            }
        }
    }

    func testSQLiteAuthorizationRemovesTheCallbackAfterAThrownError() throws {
        let store = try open()
        defer { store.close() }
        let connection = try storeConnection(store)
        XCTAssertThrowsError(
            try withDeniedSQLiteSelect(in: store) {
                connection.withLock {
                    XCTAssertEqual(sqlite3_exec(connection.database, "SELECT 1;", nil, nil, nil), SQLITE_AUTH)
                }
                throw CancellationError()
            }
        ) { XCTAssertTrue($0 is CancellationError) }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "SELECT 1;", nil, nil, nil), SQLITE_OK)
        }
    }

    func testSQLiteAuthorizationAdaptersOnlyDenyTheirOperation() throws {
        let store = try open()
        defer { store.close() }
        let connection = try storeConnection(store)
        for denyPragma in [false, true] {
            let body = {
                connection.withLock {
                    XCTAssertEqual(
                        sqlite3_exec(connection.database, "SELECT 1;", nil, nil, nil),
                        denyPragma ? SQLITE_OK : SQLITE_AUTH)
                    XCTAssertEqual(
                        sqlite3_exec(connection.database, "PRAGMA user_version;", nil, nil, nil),
                        denyPragma ? SQLITE_AUTH : SQLITE_OK)
                }
            }
            if denyPragma {
                try withDeniedSQLitePragma(in: store, body)
            } else {
                try withDeniedSQLiteSelect(in: store, body)
            }
            connection.withLock {
                XCTAssertEqual(
                    sqlite3_exec(connection.database, "SELECT 1; PRAGMA user_version;", nil, nil, nil), SQLITE_OK)
            }
        }
    }

    private func changeDatabase(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
