import Foundation
import SQLite3
import XCTest

@testable import UploadCore

final class UploadRemoteLineageIndexStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent(UploadRemoteLineageIndexStore.databaseFileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testRowsRoundTripAndOnlyMainLinksMatchIdentity() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        XCTAssertTrue(replace(store, links: [identity("main"), identity("related", isMain: false)]))
        store.close()
        let reopened = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(reopened.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["main"])
        XCTAssertEqual(reopened.replacingMainLinkIDs(ofReplacedLink: "old", hashKeyEpoch: "epoch"), ["main"])
        XCTAssertEqual(reopened.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .complete)
        XCTAssertTrue(reopened.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "other").isEmpty)
    }

    func testReplacingMainReadReturnsAncestorsOnlyForItsEpoch() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(
            store.replaceRows(
                identities: [identity("main"), identity("other")],
                lineage: [
                    .init(hashKeyEpoch: "epoch", replacedLinkID: "old", replacingLinkID: "main"),
                    .init(hashKeyEpoch: "epoch", replacedLinkID: "older", replacingLinkID: "main"),
                    .init(hashKeyEpoch: "epoch", replacedLinkID: "unrelated", replacingLinkID: "other"),
                ], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))

        XCTAssertEqual(store.replacedLinkIDs(ofReplacingMain: "main", hashKeyEpoch: "epoch"), ["old", "older"])
        XCTAssertTrue(store.replacedLinkIDs(ofReplacingMain: "main", hashKeyEpoch: "another-epoch").isEmpty)
    }

    func testMainIdentityReadIgnoresSecondariesAndOtherEpochs() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(replace(store, links: [identity("main"), identity("related", isMain: false)]))

        XCTAssertEqual(store.externalIdentifier(ofMainLink: "main", hashKeyEpoch: "epoch"), "cloud")
        XCTAssertNil(store.externalIdentifier(ofMainLink: "related", hashKeyEpoch: "epoch"))
        XCTAssertNil(store.externalIdentifier(ofMainLink: "main", hashKeyEpoch: "another-epoch"))
    }

    func testFullBuildReplacesEpochRows() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(replace(store, links: [identity("main")]))
        XCTAssertTrue(replace(store, links: [identity("new")], replacing: "new", eventID: "two"))
        XCTAssertEqual(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["new"])
        XCTAssertEqual(store.replacingMainLinkIDs(ofReplacedLink: "old", hashKeyEpoch: "epoch"), ["new"])
    }

    func testEventRefreshDeletesNamedOwnersAndPreservesOtherLineage() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(
            store.replaceRows(
                identities: [identity("main"), identity("unchanged")],
                lineage: [
                    .init(hashKeyEpoch: "epoch", replacedLinkID: "old", replacingLinkID: "main"),
                    .init(hashKeyEpoch: "epoch", replacedLinkID: "main", replacingLinkID: "unchanged"),
                ],
                hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
        XCTAssertTrue(
            store.applyChanges(
                identities: [identity("new")],
                lineage: [.init(hashKeyEpoch: "epoch", replacedLinkID: "main", replacingLinkID: "new")],
                removingRemoteLinkIDs: ["main", "new", "old"],
                hashKeyEpoch: "epoch", expectedEventID: "one", eventID: "two", unresolvedRemoteLinkIDs: []
            ))
        XCTAssertEqual(
            store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["new", "unchanged"])
        XCTAssertTrue(store.replacingMainLinkIDs(ofReplacedLink: "old", hashKeyEpoch: "epoch").isEmpty)
        XCTAssertEqual(store.replacingMainLinkIDs(ofReplacedLink: "main", hashKeyEpoch: "epoch"), ["new", "unchanged"])
        XCTAssertFalse(
            store.applyChanges(
                identities: [], lineage: [], removingRemoteLinkIDs: ["new"],
                hashKeyEpoch: "epoch", expectedEventID: "one", eventID: "three", unresolvedRemoteLinkIDs: []
            ))
        XCTAssertEqual(store.replacingMainLinkIDs(ofReplacedLink: "main", hashKeyEpoch: "epoch"), ["new", "unchanged"])
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")), .complete)
    }

    func testCompletenessRequiresMatchingCheckpointAndNoUnresolvedLinks() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
        XCTAssertTrue(replace(store, links: [identity("main")]))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")), .incomplete)
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: nil), .incomplete)
        XCTAssertTrue(replace(store, links: [identity("main")], unresolved: ["unreadable"]))
        store.close()
        let reopened = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(reopened.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
        XCTAssertEqual(reopened.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
    }

    func testResumedBuildRetainsEarlierWindowsAndPublishesOnlyAtFinish() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        XCTAssertTrue(replace(store, links: [identity("previous")]))
        let build = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "two", sourceFingerprint: "source", cursor: 0, total: 2, updatedAt: Date())
        XCTAssertTrue(store.prepareBuild(build, hashKeyEpoch: "epoch"))
        XCTAssertTrue(
            store.appendBuild(
                identities: [identity("first")], lineage: [], hashKeyEpoch: "epoch",
                buildID: "build", nextCursor: 1, unresolvedRemoteLinkIDs: ["unreadable"]))
        XCTAssertEqual(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["previous"])
        store.close()
        let resumed = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { resumed.close() }
        let continuation = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "two", sourceFingerprint: "source", cursor: 1, total: 2, updatedAt: Date())
        XCTAssertTrue(resumed.prepareBuild(continuation, hashKeyEpoch: "epoch"))
        XCTAssertTrue(
            resumed.appendBuild(
                identities: [identity("second")], lineage: [], hashKeyEpoch: "epoch",
                buildID: "build", nextCursor: 2, unresolvedRemoteLinkIDs: []))
        XCTAssertTrue(resumed.finishBuild(continuation, hashKeyEpoch: "epoch"))
        XCTAssertEqual(
            resumed.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["first", "second"])
        XCTAssertEqual(resumed.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")), .incomplete)
    }

    func testAnotherSchemaIsRebuilt() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE future(value TEXT); PRAGMA user_version=99;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
        XCTAssertTrue(replace(store, links: [identity("main")]))
    }

    func testMissingBuildStagingCannotResumeAndInvalidRowsDisableWrites() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        let continuation = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "two", sourceFingerprint: "source", cursor: 1, total: 2, updatedAt: Date())
        XCTAssertFalse(store.prepareBuild(continuation, hashKeyEpoch: "epoch"))
        XCTAssertTrue(replace(store, links: [identity("main")]))
        XCTAssertFalse(
            replace(
                store,
                links: [
                    .init(hashKeyEpoch: "other", remoteLinkID: "bad", externalIdentifier: "cloud", isMain: true)
                ]))
        XCTAssertEqual(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["main"])
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
        XCTAssertFalse(replace(store, links: [identity("new")]))
        XCTAssertFalse(store.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
    }

    func testDefaultCheckerReadsAreIncomplete() async throws {
        let checker: any UploadDuplicateChecking = FakeChecker()
        let identity = try await checker.activeMainLinkIDs(forExternalIdentifier: "cloud")
        let lineage = try await checker.replacingMainLinkIDs(ofReplacedLink: "old")
        XCTAssertTrue(identity.links.isEmpty)
        XCTAssertFalse(identity.complete)
        XCTAssertTrue(lineage.links.isEmpty)
        XCTAssertFalse(lineage.complete)
    }

    func testClosedStoreReportsIncomplete() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        XCTAssertTrue(replace(store, links: [identity("main")]))
        store.close()
        XCTAssertTrue(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch").isEmpty)
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
    }

    func testUnresolvedLinksPersistUntilNamedAndResolvedOrRemoved() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(
            store.replaceRows(
                identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one",
                unresolvedRemoteLinkIDs: ["unreadable", "removed"]))
        XCTAssertTrue(
            store.applyChanges(
                identities: [], lineage: [], removingRemoteLinkIDs: [],
                hashKeyEpoch: "epoch", expectedEventID: "one", eventID: "two", unresolvedRemoteLinkIDs: []))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")), .incomplete)
        XCTAssertTrue(
            store.applyChanges(
                identities: [], lineage: [], removingRemoteLinkIDs: ["unreadable"],
                hashKeyEpoch: "epoch", expectedEventID: "two", eventID: "three",
                unresolvedRemoteLinkIDs: ["unreadable"]))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")), .incomplete)
        XCTAssertTrue(
            store.applyChanges(
                identities: [identity("unreadable")], lineage: [], removingRemoteLinkIDs: ["unreadable", "removed"],
                hashKeyEpoch: "epoch", expectedEventID: "three", eventID: "four", unresolvedRemoteLinkIDs: []))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("four")), .complete)
    }

    func testFailedEventPageRollsBackRowsAndCheckpointAndDisablesWrites() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        XCTAssertTrue(replace(store, links: [identity("main")]))
        XCTAssertFalse(
            store.applyChanges(
                identities: [identity("new"), identity("")], lineage: [], removingRemoteLinkIDs: ["main"],
                hashKeyEpoch: "epoch", expectedEventID: "one", eventID: "two", unresolvedRemoteLinkIDs: ["bad"]))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
        XCTAssertFalse(replace(store, links: [identity("new")]))
        store.close()
        let reopened = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { reopened.close() }
        XCTAssertFalse(reopened.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
        XCTAssertFalse(reopened.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "two"))
        XCTAssertEqual(reopened.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["main"])
        XCTAssertEqual(reopened.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")), .incomplete)
        XCTAssertFalse(replace(reopened, links: [identity("new")]))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db, "SELECT event_id FROM lineage_checkpoint WHERE key_epoch='epoch';", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
        XCTAssertEqual(String(cString: text), "one")
    }

    func testResumedAppendAtOrPastCursorDoesNothingAndUnresolvedLinksAreUnique() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        let build = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "one", sourceFingerprint: "source", cursor: 0, total: 2, updatedAt: Date())
        XCTAssertTrue(store.prepareBuild(build, hashKeyEpoch: "epoch"))
        XCTAssertTrue(
            store.appendBuild(
                identities: [identity("first")], lineage: [], hashKeyEpoch: "epoch", buildID: "build",
                nextCursor: 2, unresolvedRemoteLinkIDs: ["bad", "bad"]))
        XCTAssertTrue(store.prepareBuild(build, hashKeyEpoch: "epoch"))
        for cursor in [1, 2] {
            XCTAssertTrue(
                store.appendBuild(
                    identities: [identity("must-not-appear")], lineage: [], hashKeyEpoch: "epoch", buildID: "build",
                    nextCursor: cursor, unresolvedRemoteLinkIDs: ["another"]))
        }
        XCTAssertTrue(store.finishBuild(build, hashKeyEpoch: "epoch"))
        XCTAssertEqual(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch"), ["first"])
        XCTAssertTrue(
            store.applyChanges(
                identities: [], lineage: [], removingRemoteLinkIDs: ["bad"],
                hashKeyEpoch: "epoch", expectedEventID: "one", eventID: "two", unresolvedRemoteLinkIDs: []))
        XCTAssertEqual(store.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")), .complete)
    }

    func testFullBuildDeletesEveryOtherEpochIncludingStaging() throws {
        let store = try XCTUnwrap(UploadRemoteLineageIndexStore(url: url))
        defer { store.close() }
        XCTAssertTrue(replace(store, links: [identity("old")], unresolved: ["unreadable"]))
        let build = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "two", sourceFingerprint: "source", cursor: 0, total: 1, updatedAt: Date())
        XCTAssertTrue(store.prepareBuild(build, hashKeyEpoch: "epoch"))
        XCTAssertTrue(
            store.appendBuild(
                identities: [], lineage: [], hashKeyEpoch: "epoch", buildID: "build",
                nextCursor: 1, unresolvedRemoteLinkIDs: ["old-staged"]))
        XCTAssertTrue(store.prepareBuild(build, hashKeyEpoch: "new-epoch"))
        XCTAssertTrue(
            store.appendBuild(
                identities: [
                    .init(hashKeyEpoch: "new-epoch", remoteLinkID: "new", externalIdentifier: "cloud", isMain: true)
                ],
                lineage: [], hashKeyEpoch: "new-epoch", buildID: "build", nextCursor: 1, unresolvedRemoteLinkIDs: []))
        XCTAssertTrue(store.finishBuild(build, hashKeyEpoch: "new-epoch"))
        XCTAssertTrue(store.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch").isEmpty)
        XCTAssertTrue(store.replacingMainLinkIDs(ofReplacedLink: "old", hashKeyEpoch: "epoch").isEmpty)
        XCTAssertFalse(store.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
        let continuation = UploadRemoteContentIndexBuildCheckpoint(
            buildID: "build", eventID: "two", sourceFingerprint: "source", cursor: 1, total: 1, updatedAt: Date())
        XCTAssertFalse(store.prepareBuild(continuation, hashKeyEpoch: "epoch"))
        XCTAssertEqual(store.health(hashKeyEpoch: "new-epoch", contentCheckpoint: checkpoint("two")), .complete)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for table in ["lineage_unresolved", "lineage_build_unresolved"] {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db, "SELECT COUNT(*) FROM \(table) WHERE key_epoch='epoch';", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
            sqlite3_finalize(statement)
        }
    }

    private func identity(_ link: String, isMain: Bool = true) -> UploadRemoteLinkIdentityRecord {
        .init(hashKeyEpoch: "epoch", remoteLinkID: link, externalIdentifier: "cloud", isMain: isMain)
    }

    private func checkpoint(_ eventID: String) -> UploadRemoteContentIndexCheckpoint {
        .init(eventID: eventID, refreshedAt: Date())
    }

    private func replace(
        _ store: UploadRemoteLineageIndexStore, links: [UploadRemoteLinkIdentityRecord],
        replacing: String = "main", eventID: String = "one", unresolved: Set<String> = []
    ) -> Bool {
        store.replaceRows(
            identities: links,
            lineage: [.init(hashKeyEpoch: "epoch", replacedLinkID: "old", replacingLinkID: replacing)],
            hashKeyEpoch: "epoch", eventID: eventID, unresolvedRemoteLinkIDs: unresolved)
    }
}
