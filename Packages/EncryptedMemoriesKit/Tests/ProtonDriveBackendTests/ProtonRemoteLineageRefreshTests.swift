import CryptoKit
import Foundation
import ProtonAuth
import SQLite3
import Testing
import UploadCore

@testable import ProtonDriveBackend

extension DriveSessionStubSuite {
    @Suite struct ProtonRemoteLineageRefreshTests {
        @Test func missingBehindOrFailedLineageUsesTheContentEventPath() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            for mode in ["absent", "missing", "behind", "failed"] {
                StubURLProtocol.reset()
                let lineage: UploadRemoteLineageIndexStore?
                if mode == "absent" {
                    lineage = nil
                } else {
                    lineage = try #require(
                        UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("\(mode).sqlite")))
                }
                defer { lineage?.close() }
                if mode == "behind" || mode == "failed" {
                    #expect(
                        lineage?.replaceRows(
                            identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "older",
                            unresolvedRemoteLinkIDs: []) == true)
                }
                if mode == "failed" {
                    #expect(
                        lineage?.replaceRows(
                            identities: [
                                .init(
                                    hashKeyEpoch: "wrong", remoteLinkID: "bad", externalIdentifier: "cloud",
                                    isMain: true)
                            ],
                            lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []) == false)
                }
                #expect(
                    content.replaceRemoteContentIndex(
                        [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                        unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
                routeEmptyEvents(from: "one", to: "two")
                try await refresh(content: content, lineage: lineage)
                #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "two")
                #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
                #expect(StubURLProtocol.requests().map(\.path) == ["/drive/volumes/vol1/events/one"])
                if let lineage {
                    #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
                }
            }
        }

        @Test func lineageWriteFailureDisablesFurtherWritesWhileContentKeepsRefreshing() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let url = directory.appendingPathComponent("lineage.sqlite")
            let lineage = try #require(UploadRemoteLineageIndexStore(url: url))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            var db: OpaquePointer?
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(
                sqlite3_exec(
                    db,
                    """
                    CREATE TRIGGER reject_checkpoint BEFORE INSERT ON lineage_checkpoint
                    BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
                    """, nil, nil, nil) == SQLITE_OK)
            StubURLProtocol.reset()
            routeEmptyEvents(from: "one", to: "two")
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "two")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .incomplete)
            #expect(sqlite3_exec(db, "DROP TRIGGER reject_checkpoint;", nil, nil, nil) == SQLITE_OK)
            #expect(
                !lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "two", unresolvedRemoteLinkIDs: []))
            routeEmptyEvents(from: "two", to: "three")
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "three")
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
            #expect(
                StubURLProtocol.requests().map(\.path) == [
                    "/drive/volumes/vol1/events/one", "/drive/volumes/vol1/events/two",
                ])
        }

        @Test func missingLineageStagingDoesNotRestartAResumedContentBuild() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            let fingerprint = SHA256.hash(data: Data("main\0".utf8)).map { String(format: "%02x", $0) }.joined()
            let build = try #require(
                content.beginRemoteContentIndexBuild(
                    hashKeyEpoch: "epoch", eventID: "one", sourceFingerprint: fingerprint, total: 1, updatedAt: Date()))
            #expect(
                content.appendRemoteContentIndexBuild(
                    records: [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], externalIdentities: [], hashKeyEpoch: "epoch", buildID: build.buildID,
                    nextCursor: 1, updatedAt: Date()))
            StubURLProtocol.reset()
            StubURLProtocol.route("GET /drive/volumes/vol1/events/latest", json: #"{"Code":1000,"EventID":"one"}"#)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/photos",
                json: #"{"Code":1000,"Photos":[{"LinkID":"main","CaptureTime":1,"Tags":[],"RelatedPhotos":[]}]}"#)
            try await refresh(content: content, lineage: lineage)
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .incomplete)
            #expect(StubURLProtocol.requests().map(\.path).filter { $0.contains("fetch_metadata") }.isEmpty)
            #expect(StubURLProtocol.requests().filter { $0.path.hasPrefix("/drive/volumes/vol1/photos") }.count == 2)
        }

        @Test func unresolvedMetadataSurvivesEmptyEventsUntilTheLinksAreRemoved() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let content = try #require(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("content.sqlite")))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [], unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [], lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json: #"""
                    {"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"missing","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"state","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"photo","Type":2,"State":1}},
                        {"EventType":2,"ContextShareID":"share1","Link":{"LinkID":"unknown","Type":2,"State":99}}
                    ]}
                    """#)
            StubURLProtocol.route(
                "POST /drive/shares/share1/links/fetch_metadata",
                json: #"""
                    {"Code":1000,"Links":[
                        {"LinkID":"state","Type":2,"FileProperties":{"ActiveRevision":{"Photo":{}}}},
                        {"LinkID":"photo","Type":2,"State":1}
                    ]}
                    """#)
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "two"))
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("two")) == .incomplete)
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch").isEmpty)
            routeEmptyEvents(from: "two", to: "three")
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("three")) == .incomplete)
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/three",
                json: #"""
                    {"Code":1000,"EventID":"four","More":0,"Refresh":0,"Events":[
                        {"EventType":0,"Link":{"LinkID":"missing"}},
                        {"EventType":0,"Link":{"LinkID":"state"}},
                        {"EventType":0,"Link":{"LinkID":"photo"}},
                        {"EventType":0,"Link":{"LinkID":"unknown"}}
                    ]}
                    """#)
            try await refresh(content: content, lineage: lineage)
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("four")) == .complete)
            #expect(!StubURLProtocol.requests().contains { $0.path.contains("/photos") })
        }

        @Test func contentPageFailureKeepsBothCheckpointsAndRows() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let contentURL = directory.appendingPathComponent("content.sqlite")
            let content = try #require(UploadIdentityManifestStore(url: contentURL))
            defer { content.close() }
            let lineage = try #require(
                UploadRemoteLineageIndexStore(url: directory.appendingPathComponent("lineage.sqlite")))
            defer { lineage.close() }
            #expect(
                content.replaceRemoteContentIndex(
                    [.init(contentHash: "hash", hashKeyEpoch: "epoch", remoteLinkID: "main")],
                    unresolvedIssues: [], hashKeyEpoch: "epoch", checkpoint: checkpoint("one")))
            #expect(
                lineage.replaceRows(
                    identities: [
                        .init(hashKeyEpoch: "epoch", remoteLinkID: "main", externalIdentifier: "cloud", isMain: true)
                    ],
                    lineage: [], hashKeyEpoch: "epoch", eventID: "one", unresolvedRemoteLinkIDs: []))
            var db: OpaquePointer?
            #expect(sqlite3_open(contentURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(
                sqlite3_exec(
                    db,
                    """
                    CREATE TRIGGER reject_content_checkpoint BEFORE INSERT ON remote_content_index_checkpoint
                    BEGIN SELECT RAISE(ABORT, 'test page failure'); END;
                    """, nil, nil, nil) == SQLITE_OK)
            StubURLProtocol.reset()
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/one",
                json:
                    #"{"Code":1000,"EventID":"two","More":0,"Refresh":0,"Events":[{"EventType":0,"Link":{"LinkID":"main"}}]}"#
            )
            await #expect(throws: UploadError.self) {
                try await refresh(content: content, lineage: lineage)
            }
            #expect(content.remoteContentIndexCheckpoint(hashKeyEpoch: "epoch")?.eventID == "one")
            #expect(content.remoteContentRecord(contentHash: "hash", hashKeyEpoch: "epoch")?.remoteLinkID == "main")
            #expect(lineage.hasCheckpoint(hashKeyEpoch: "epoch", eventID: "one"))
            #expect(lineage.activeMainLinkIDs(forExternalIdentifier: "cloud", hashKeyEpoch: "epoch") == ["main"])
            #expect(lineage.health(hashKeyEpoch: "epoch", contentCheckpoint: checkpoint("one")) == .complete)
        }

        private func checkpoint(_ eventID: String) -> UploadRemoteContentIndexCheckpoint {
            .init(eventID: eventID, refreshedAt: Date())
        }

        private func routeEmptyEvents(from: String, to: String) {
            StubURLProtocol.route(
                "GET /drive/volumes/vol1/events/\(from)",
                json: #"{"Code":1000,"EventID":"\#(to)","More":0,"Refresh":0,"Events":[]}"#)
        }

        private func refresh(
            content: UploadIdentityManifestStore, lineage: UploadRemoteLineageIndexStore?
        ) async throws {
            let session = DriveSession(
                session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
                store: SessionKeychainStore(service: "at.oncloud.encryptedmemories.tests.never-used"),
                accountCacheDirectory: FileManager.default.temporaryDirectory,
                urlProtocolClasses: [StubURLProtocol.self])
            try await ProtonUploadDedupeService.refreshRemoteContentIndex(
                material: .init(
                    context: .init(volumeID: "vol1", shareID: "share1", rootLinkID: "root1"),
                    rootKey: .init(armored: "", passphrase: ""), hashKey: Data(), epoch: "epoch"),
                session: session, crypto: DriveCrypto(addressKeys: [], signers: []),
                store: content, lineageStore: lineage, progress: { _ in })
        }
    }
}
