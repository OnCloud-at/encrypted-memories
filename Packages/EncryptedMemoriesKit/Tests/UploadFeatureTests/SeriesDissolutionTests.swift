import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// "Keep Only Favorites": journal, crash recovery, the trash ordering, the shared-album refusal and the
/// dedupe collision rule. One shared `FakeSeriesServer` plays Proton for the remote, uploader and checker seams.
final class SeriesDissolutionTests: XCTestCase {
    private var tempDir: URL!
    private var server: FakeSeriesServer!
    private var journalStore: SeriesDissolutionJournalFileStore!

    private let main = PhotoUID(volumeID: "own", nodeID: "m1")
    private var series: [PhotoUID] { ["m1", "m2", "m3", "m4"].map { PhotoUID(volumeID: "own", nodeID: $0) } }
    private func member(_ id: String) -> PhotoUID { PhotoUID(volumeID: "own", nodeID: id) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-dissolution-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = FakeSeriesServer(ownVolumeID: "own", seriesNodeIDs: ["m1", "m2", "m3", "m4"])
        journalStore = SeriesDissolutionJournalFileStore(accountDataDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A new orchestrator over the same journal directory and server models the next app launch.
    private func makeOrchestrator() -> SeriesDissolutionOrchestrator {
        SeriesDissolutionOrchestrator(
            remote: server,
            uploader: server,
            duplicateChecker: server,
            journalStore: journalStore,
            tempDirectory: tempDir.appendingPathComponent("work", isDirectory: true),
            currentClientUID: "this-installation"
        )
    }

    // MARK: Happy path

    func testFavoritesBecomeStandalonePhotosBeforeTheWholeSeriesMovesToTrash() async throws {
        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])

        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC"], "the copies keep the original filenames")
        for upload in server.uploads {
            XCTAssertNil(upload.mainPhotoUID, "a kept favorite is a standalone photo, not a related photo")
            XCTAssertEqual(upload.tags, [], "a kept favorite carries no bursts tag")
            XCTAssertNotNil(upload.expectedSHA1, "the original bytes are verified on upload")
        }
        XCTAssertEqual(server.uploads.map(\.captureTime), [server.captureTime(of: "m2"), server.captureTime(of: "m4")])
        XCTAssertEqual(server.uploads.first?.additionalMetadata.map(\.name), ["Camera"])
        XCTAssertEqual(server.trashCalls, [series], "the main photo and every member move to the trash together")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "a finished operation leaves no journal")
        XCTAssertEqual(
            server.events.last, .trash, "every copy is confirmed before the series is touched: \(server.events)")
    }

    // MARK: Crash safety and idempotence

    func testFailureAfterAPartialUploadLeavesTheSeriesUntouchedAndResumesWithoutDuplicates() async throws {
        server.failUploads(named: "m4.HEIC", times: 1)

        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])
            XCTFail("the second favorite fails")
        } catch {}

        XCTAssertTrue(server.trashCalls.isEmpty, "the series must never be trashed before every favorite exists")
        let journal = try XCTUnwrap(try journalStore.journal(forSeries: main))
        XCTAssertEqual(journal.phase, .copyingFavorites)
        XCTAssertEqual(journal.confirmedFavoriteCount, 1, "the confirmed copy is durable across the failure")

        // Next launch: nobody confirmed the operation in this session, so the automatic resume leaves it alone.
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC"])
        XCTAssertTrue(server.trashCalls.isEmpty, "a series the user may have abandoned is never trashed")
        XCTAssertEqual(try journalStore.journal(forSeries: main), journal)

        // The user's Retry continues the journaled operation.
        try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])

        XCTAssertEqual(
            server.uploads.map(\.name), ["m2.HEIC", "m4.HEIC", "m4.HEIC"],
            "the confirmed favorite must not upload again; only the failed one repeats")
        XCTAssertEqual(server.activeCopyUIDs.count, 2)
        XCTAssertEqual(server.trashCalls, [series])
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testCrashBetweenRemoteCommitAndJournalWriteAdoptsTheCommittedCopy() async throws {
        // The upload commits on the server, but the process dies before the journal records it.
        server.commitThenFailUploads(named: "m2.HEIC", times: 1)
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("the simulated crash surfaces as an error")
        } catch {}
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.confirmedFavoriteCount, 0)
        XCTAssertTrue(server.trashCalls.isEmpty)

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])

        XCTAssertEqual(server.uploads.count, 1, "the retry finds the committed copy and uploads nothing")
        XCTAssertEqual(Set(copies), server.activeCopyUIDs)
        XCTAssertEqual(server.trashCalls, [series])
    }

    func testCrashDuringTheTrashStepResumesWithoutCopyingAgain() async throws {
        server.failNextTrash()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
            XCTFail("the trash step fails")
        } catch {}
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
        // Half of the series already moved before the failure.
        server.markTrashed(["m1", "m2"])

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertEqual(outcomes.map(\.seriesUIDs), [series], "the host learns which series left the library")
        XCTAssertEqual(try outcomes.first?.result.get().count, 1)
        XCTAssertEqual(server.uploads.count, 1)
        XCTAssertEqual(
            server.trashCalls.last, [member("m3"), member("m4")],
            "the resumed trash step skips photos that are already in the trash")
        XCTAssertEqual(try journalStore.pendingJournals(), [])
    }

    func testAbandonRemovesACopyingJournalAndKeepsTheConfirmedCopies() async throws {
        server.failUploads(named: "m4.HEIC", times: 1)
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])
            XCTFail("the second favorite fails")
        } catch {}

        // The user answers the failure with Cancel.
        try await makeOrchestrator().abandon(seriesMainUID: main)

        XCTAssertEqual(try journalStore.pendingJournals(), [])
        XCTAssertEqual(server.activeCopyUIDs.count, 1, "the confirmed copy stays as a standalone photo")
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty, "the abandoned series stays in the library")
    }

    func testAbandonKeepsAJournalWhoseTrashStepStarted() async throws {
        server.failNextTrash()
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
            XCTFail("the trash step fails")
        } catch {}

        try await makeOrchestrator().abandon(seriesMainUID: main)

        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
    }

    func testResumeReportsAFailedTrashStepAndKeepsItsJournal() async throws {
        server.failNextTrash()
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m3")])
        server.failNextTrash()

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertThrowsError(try outcomes.first?.result.get(), "the host receives the error instead of silence")
        XCTAssertEqual(try journalStore.journal(forSeries: main)?.phase, .trashingSeries)
    }

    func testACopyThatVanishedIsCopiedAgainBeforeTheSeriesIsTrashed() async throws {
        server.failUploads(named: "m3.HEIC", times: 1)
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])
        let confirmed = try XCTUnwrap(try journalStore.journal(forSeries: main)?.favorites.first?.copyUID)
        server.markTrashed([confirmed.nodeID])  // the user deleted the first copy in the meantime

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])

        XCTAssertFalse(copies.contains(confirmed))
        XCTAssertEqual(Set(copies), server.activeCopyUIDs, "both favorites exist as active standalone photos")
        XCTAssertEqual(server.trashCalls, [series])
    }

    func testARetryMayChangeTheSelectionWhileTheSeriesIsUntouched() async throws {
        server.failUploads(named: "m3.HEIC", times: 1)
        _ = try? await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m3")])

        let copies = try await makeOrchestrator().keepOnlyFavorites(
            seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2"), member("m4")])

        XCTAssertEqual(server.uploads.map(\.name), ["m2.HEIC", "m3.HEIC", "m4.HEIC"], "m2 keeps its confirmed copy")
        XCTAssertEqual(copies.count, 2)
    }

    // MARK: Refusals

    func testSharedAlbumSeriesIsRefusedBeforeAnyRemoteWrite() async throws {
        let foreign = ["s1", "s2"].map { PhotoUID(volumeID: "shared-volume", nodeID: $0) }
        let orchestrator = makeOrchestrator()

        let canDissolve = await orchestrator.canDissolve(seriesUIDs: foreign)
        XCTAssertFalse(canDissolve)
        do {
            try await orchestrator.keepOnlyFavorites(
                seriesMainUID: foreign[0], seriesUIDs: foreign, favoriteUIDs: [foreign[1]])
            XCTFail("a series of a shared album must be refused")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .notOwnLibrary)
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertEqual(try journalStore.pendingJournals(), [], "a refused operation leaves no journal to resume")
    }

    func testSeriesThatMixesAForeignVolumeIsRefused() async throws {
        let mixed = series + [PhotoUID(volumeID: "shared-volume", nodeID: "s1")]
        let canDissolve = await makeOrchestrator().canDissolve(seriesUIDs: mixed)
        XCTAssertFalse(canDissolve)
    }

    func testSelectionOutsideTheSeriesOrEmptyIsRefused() async throws {
        for favorites in [[], [member("not-in-series")]] {
            do {
                try await makeOrchestrator().keepOnlyFavorites(
                    seriesMainUID: main, seriesUIDs: series, favoriteUIDs: favorites)
                XCTFail("invalid selection")
            } catch let error as SeriesDissolutionError {
                XCTAssertEqual(error, .invalidSelection)
            }
        }
        XCTAssertTrue(server.trashCalls.isEmpty)
    }

    // MARK: Dedupe collision rule

    func testSeriesMemberRowsNeverCountAsAnExistingCopy() {
        // The favorite's own member row has the same name and content. The standard dedupe would link to it.
        let decision = SeriesFavoriteCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [.init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2")],
            seriesLinkIDs: ["m1", "m2"], currentClientUID: "me")
        XCTAssertEqual(decision, .upload(replacingDraft: false))
    }

    func testActiveStandalonePhotoWithTheSameNameAndContentIsAdopted() {
        let decision = SeriesFavoriteCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "m2"),
                .init(nameHash: "nh", contentHash: "ch", linkState: .active, linkID: "standalone"),
            ],
            seriesLinkIDs: ["m1", "m2"], currentClientUID: "me")
        XCTAssertEqual(decision, .adopt(remoteLinkID: "standalone"))
    }

    func testOwnDraftIsReplacedAndAForeignDraftBlocks() {
        func decide(clientUID: String?) -> SeriesFavoriteCopyPolicy.Decision {
            SeriesFavoriteCopyPolicy.decide(
                nameHash: "nh", contentHash: "ch",
                remoteItems: [
                    .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "d", clientUID: clientUID)
                ],
                seriesLinkIDs: ["m1"], currentClientUID: "me")
        }
        XCTAssertEqual(decide(clientUID: "me"), .upload(replacingDraft: true))
        XCTAssertEqual(decide(clientUID: "other-device"), .blockedByForeignDraft)
        XCTAssertEqual(decide(clientUID: nil), .blockedByForeignDraft)
    }

    func testTrashedOrDifferentContentNeverSuppressesTheCopy() {
        let decision = SeriesFavoriteCopyPolicy.decide(
            nameHash: "nh", contentHash: "ch",
            remoteItems: [
                .init(nameHash: "nh", contentHash: "ch", linkState: .trashed, linkID: "old"),
                .init(nameHash: "nh", contentHash: "ch", linkState: nil, linkID: "deleted"),
                .init(nameHash: "nh", contentHash: "other", linkState: .active, linkID: "same-name"),
                .init(nameHash: "unrelated", contentHash: "ch", linkState: .active, linkID: "other-name"),
            ],
            seriesLinkIDs: [], currentClientUID: "me")
        XCTAssertEqual(
            decision, .upload(replacingDraft: false),
            "the user keeps this favorite now; an older deletion of an identical file must not remove it")
    }

    func testForeignDraftStopsTheOperationAndKeepsItResumable() async throws {
        server.addRemoteRow(name: "m2.HEIC", contentOf: nil, state: .draft, linkID: "foreign", clientUID: "other")
        do {
            try await makeOrchestrator().keepOnlyFavorites(
                seriesMainUID: main, seriesUIDs: series, favoriteUIDs: [member("m2")])
            XCTFail("a foreign draft blocks the name")
        } catch let error as SeriesDissolutionError {
            XCTAssertEqual(error, .blockedByForeignDraft("m2.HEIC"))
        }
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertTrue(server.trashCalls.isEmpty)
        XCTAssertNotNil(try journalStore.journal(forSeries: main))
    }

    // MARK: Journal store

    func testJournalRoundTripsAndKeepsSeriesApart() throws {
        let other = PhotoUID(volumeID: "own", nodeID: "x1")
        var journal = SeriesDissolutionJournal(
            seriesMainUID: main, seriesUIDs: series, favorites: [.init(memberUID: member("m2"))])
        try journalStore.save(journal)
        try journalStore.save(
            SeriesDissolutionJournal(seriesMainUID: other, seriesUIDs: [other], favorites: [.init(memberUID: other)]))

        journal.favorites[0].copyUID = member("copy")
        journal.phase = .trashingSeries
        try journalStore.save(journal)

        XCTAssertEqual(try journalStore.journal(forSeries: main), journal)
        XCTAssertEqual(try journalStore.pendingJournals().count, 2)
        try journalStore.remove(forSeries: main)
        XCTAssertNil(try journalStore.journal(forSeries: main))
        XCTAssertEqual(try journalStore.pendingJournals().map(\.seriesMainUID), [other])
    }
}

// MARK: - Fake Proton

/// In-memory Proton for the dissolution seams: nodes with names, bytes and states, the duplicates endpoint,
/// uploads and the trash. Thread-safe; failure injection models errors and crashes.
private final class FakeSeriesServer: SeriesDissolutionRemote, PhotoUploading, UploadDuplicateChecking,
    @unchecked Sendable
{
    enum Event: Equatable { case upload, trash }

    private struct Node {
        var name: String
        var bytes: Data
        var state: RemotePhotoDuplicate.LinkState
        var clientUID: String?
        var isCopy: Bool
    }

    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private let ownVolumeID: String
    private var nodes: [String: Node] = [:]
    private var uploadFailures: [String: Int] = [:]
    private var commitThenFail: [String: Int] = [:]
    private var trashFailures = 0
    private var _uploads: [PhotoUploadRequest] = []
    private var _trashCalls: [[PhotoUID]] = []
    private var _events: [Event] = []

    init(ownVolumeID: String, seriesNodeIDs: [String]) {
        self.ownVolumeID = ownVolumeID
        for id in seriesNodeIDs {
            nodes[id] = Node(name: "\(id).HEIC", bytes: Data("bytes-of-\(id)".utf8), state: .active, isCopy: false)
        }
    }

    var uploads: [PhotoUploadRequest] { lock.withLock { _uploads } }
    var trashCalls: [[PhotoUID]] { lock.withLock { _trashCalls } }
    var events: [Event] { lock.withLock { _events } }
    var activeCopyUIDs: Set<PhotoUID> {
        lock.withLock {
            Set(nodes.filter { $0.value.isCopy && $0.value.state == .active }.map { uid($0.key) })
        }
    }

    func captureTime(of id: String) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(id.unicodeScalars.last?.value ?? 0))
    }

    func failUploads(named name: String, times: Int) { lock.withLock { uploadFailures[name] = times } }
    func commitThenFailUploads(named name: String, times: Int) { lock.withLock { commitThenFail[name] = times } }
    func failNextTrash() { lock.withLock { trashFailures = 1 } }
    func markTrashed(_ ids: [String]) { lock.withLock { for id in ids { nodes[id]?.state = .trashed } } }

    func addRemoteRow(
        name: String, contentOf id: String?, state: RemotePhotoDuplicate.LinkState, linkID: String, clientUID: String?
    ) {
        lock.withLock {
            nodes[linkID] = Node(
                name: name, bytes: id.flatMap { nodes[$0]?.bytes } ?? Data(), state: state, clientUID: clientUID,
                isCopy: false)
        }
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: ownVolumeID, nodeID: id) }

    // SeriesDissolutionRemote

    func ownPhotosVolumeID() async throws -> String { ownVolumeID }

    func source(for member: PhotoUID) async throws -> SeriesMemberSource {
        let node = try lock.withLock { try XCTUnwrap(nodes[member.nodeID]) }
        return SeriesMemberSource(
            filename: node.name,
            mediaType: "image/heic",
            captureTime: captureTime(of: member.nodeID),
            modificationDate: captureTime(of: member.nodeID),
            additionalMetadata: [.init(name: "Camera", utf8JsonValue: Data("{}".utf8))]
        )
    }

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let node = try lock.withLock { try XCTUnwrap(nodes[uid.nodeID]) }
        try node.bytes.write(to: destination)
        onProgress(1)
    }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { nodes[$0.nodeID]?.state == .active }) }
    }

    func trashSeries(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if trashFailures > 0 {
                trashFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "trash unavailable")
            }
            _trashCalls.append(uids)
            _events.append(.trash)
            for uid in uids { nodes[uid.nodeID]?.state = .trashed }
        }
    }

    // PhotoUploading

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let bytes = try Data(contentsOf: request.fileURL)
        return try lock.withLock {
            _uploads.append(request)
            if let left = uploadFailures[request.name], left > 0 {
                uploadFailures[request.name] = left - 1
                throw UploadError.retryableBackend(code: 503, message: "upload failed")
            }
            let id = "copy-\(_uploads.count)"
            nodes[id] = Node(name: request.name, bytes: bytes, state: .active, isCopy: true)
            _events.append(.upload)
            if let left = commitThenFail[request.name], left > 0 {
                commitThenFail[request.name] = left - 1
                throw CancellationError()
            }
            return uid(id)
        }
    }

    func cancel(token: UUID) async {}

    // UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String { "nh(\(name))" }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "ch(\(sha1Hex))" }
    func hashKeyEpoch() async throws -> String { "epoch" }
    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> { [] }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock {
            nodes.sorted { $0.key < $1.key }.compactMap { id, node in
                guard nameHashes.contains("nh(\(node.name))") else { return nil }
                let sha1 = UploadContentSHA1.hexString(digest: Self.sha1(node.bytes))
                return RemotePhotoDuplicate(
                    nameHash: "nh(\(node.name))",
                    contentHash: node.state == .draft ? nil : "ch(\(sha1))",
                    linkState: node.state,
                    linkID: id,
                    clientUID: node.clientUID
                )
            }
        }
    }

    private static func sha1(_ data: Data) -> Data {
        let accumulator = UploadSHA1Accumulator()
        accumulator.update(data)
        return accumulator.finalizeDigest()
    }
}
