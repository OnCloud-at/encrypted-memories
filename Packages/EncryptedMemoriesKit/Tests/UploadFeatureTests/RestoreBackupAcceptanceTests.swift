import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Account stores, duplicate checks, queue draining and the session's private effects run unchanged.
/// Local resource export and Proton responses use the existing file-backed runner and server fixtures.
@MainActor
final class RestoreBackupAcceptanceTests: XCTestCase {
    func testPhotoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
        try await assertRestore(.photo)
    }

    func testVideoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
        try await assertRestore(.video)
    }

    func testLivePhotoReturnsThroughProductionSessionWithoutASecondUpload() async throws {
        try await assertRestore(.live)
    }

    private func assertRestore(_ shape: Fixture.Shape) async throws {
        try await withFixture(shape) { fixture in
            let main = try await fixture.backUp()
            try fixture.exclude(main)
            try await fixture.startSession(main)
            await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }
            let uploads = fixture.server.uploadRequestCount
            let reads = fixture.resolver.readCount

            let result = try await fixture.restore(main)

            XCTAssertTrue(result.isReadable)
            guard case .waiting? = result.outcomes[fixture.key] else {
                return XCTFail("The production effects must enqueue a real compound recheck")
            }
            let admitted = try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision))
            XCTAssertFalse(admitted.state.isTerminalSuccess, "The old completed queue row must reopen")
            XCTAssertTrue(try XCTUnwrap(fixture.pending.sourceState(for: fixture.key)).needsQueueSync)
            await assertEventually { fixture.session.excludedTiles.isEmpty }

            await fixture.drain()
            XCTAssertEqual(fixture.resolver.readCount, reads + 1, "One restored revision needs one queue drain")
            XCTAssertTrue(
                try XCTUnwrap(fixture.queue.entry(for: fixture.source, revision: fixture.revision)).state
                    .isTerminalSuccess)
            // The session uses the production 60-second recheck timer. Do not acknowledge the duty in the test.
            await assertEventually(seconds: 75) { fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil) }
            XCTAssertEqual(
                fixture.server.uploadRequestCount, uploads, "The real duplicate check must reuse Proton data")
            XCTAssertEqual(fixture.remote.compensations, 0, "A confirmed Restore must not send another remote Restore")

            let completed = fixture.queue.entry(for: fixture.source, revision: fixture.revision)
            let repeated = try await fixture.restore(main)
            XCTAssertTrue(repeated.isReadable)
            await fixture.drain()
            XCTAssertEqual(fixture.queue.entry(for: fixture.source, revision: fixture.revision), completed)
            XCTAssertEqual(fixture.resolver.readCount, reads + 1)
            XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
            XCTAssertEqual(fixture.remote.compensations, 0)
            XCTAssertEqual(fixture.queue.rows(kind: .photoLibraryAsset, identifiers: [fixture.key.identifier]).count, 1)
            XCTAssertEqual(fixture.remote.personRestores, 2)
            XCTAssertEqual(fixture.server.links.filter { $0.state == .active }.count, shape == .live ? 2 : 1)
        }
    }

    func testUnreadableSavedSourceStaysVisiblyExcludedWithoutQueueOrRemoteEffects() async throws {
        try await withFixture(.photo) { fixture in
            let main = try await fixture.backUp()
            try fixture.exclude(main)
            try await fixture.startSession(main)
            await assertEventually { fixture.session.excludedTiles.map(\.key) == [fixture.key] }
            try fixture.execute("UPDATE source_state SET desired='future-state';")
            XCTAssertEqual(fixture.pending.sourceStateRead(for: fixture.key), .unreadable)
            let saved = try fixture.rawSourceRow()
            let queue = fixture.queue.entry(for: fixture.source, revision: fixture.revision)
            let uploads = fixture.server.uploadRequestCount
            let reads = fixture.resolver.readCount

            let result = try await fixture.restore(main)

            XCTAssertFalse(result.isReadable)
            XCTAssertEqual(result.outcomes[fixture.key], .unreadable)
            XCTAssertEqual(fixture.session.excludedTiles.map(\.key), [fixture.key])
            XCTAssertEqual(try fixture.rawSourceRow(), saved, "Unreadable state must remain byte-for-byte intact")
            XCTAssertEqual(fixture.queue.entry(for: fixture.source, revision: fixture.revision), queue)
            XCTAssertEqual(fixture.resolver.readCount, reads)
            XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
            XCTAssertEqual(fixture.remote.trashes, 0)
            XCTAssertEqual(fixture.remote.compensations, 0)
            XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
        }
    }

    func testTrashAlreadyInFlightAfterConfirmedRestoreStillOwesCompensation() async throws {
        try await withFixture(.photo) { fixture in
            let main = try await fixture.backUp()
            try fixture.exclude(main, trashInFlight: true)
            await fixture.remote.trashGate.hold()
            try await fixture.startSession(main, waitForExcluded: false)
            await assertEventually { fixture.remote.trashEntered }
            let uploads = fixture.server.uploadRequestCount
            let reads = fixture.resolver.readCount

            _ = try await fixture.restore(main)
            XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
            let restored = try XCTUnwrap(fixture.pending.sourceState(for: fixture.key))
            XCTAssertEqual(restored.desired, .included)
            XCTAssertTrue(restored.needsQueueSync, "The held trash cannot count as a completed Restore")
            await fixture.remote.trashGate.release()

            await assertEventually { fixture.remote.trashes == 1 && fixture.remote.compensations == 1 }
            XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
            XCTAssertTrue(try XCTUnwrap(fixture.pending.sourceState(for: fixture.key)).needsQueueSync)
            XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
            // Reconcile can admit the real queue after compensation. Wait for that admission before draining it.
            await assertEventually {
                fixture.queue.entry(for: fixture.source, revision: fixture.revision)?.state.isTerminalSuccess == false
            }
            await fixture.drain()
            XCTAssertEqual(fixture.resolver.readCount, reads + 1)
            // The trash check uses the first recheck. Admission after compensation uses the 300-second backoff.
            await assertEventually(seconds: 325) { fixture.pending.sourceStateRead(for: fixture.key) == .readable(nil) }
            XCTAssertEqual(fixture.remote.compensations, 1)
            XCTAssertEqual(fixture.server.uploadRequestCount, uploads)
            XCTAssertEqual(fixture.server.links.first { $0.uid == main }?.state, .active)
        }
    }

    private func withFixture(_ shape: Fixture.Shape, _ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(shape)
        do { try await body(fixture) } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func assertEventually(
        seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private final class Resolver: BackupResourceResolving, @unchecked Sendable {
        let resource: BackupResolvedResource
        private let lock = NSLock()
        private var reads = 0
        var readCount: Int { lock.withLock { reads } }
        init(_ resource: BackupResolvedResource) { self.resource = resource }
        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            lock.withLock { reads += 1 }
            return resource
        }
    }

    private actor TrashGate {
        private var held = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() { held = true }
        func wait() async {
            guard held else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            held = false
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Remote: PendingRemoteEffects, @unchecked Sendable {
        let server: EditScenarioServer
        let trashGate = TrashGate()
        private let lock = NSLock()
        private var entered = false
        private var trashCount = 0
        private var compensationCount = 0
        private var personCount = 0
        var trashEntered: Bool { lock.withLock { entered } }
        var trashes: Int { lock.withLock { trashCount } }
        var compensations: Int { lock.withLock { compensationCount } }
        var personRestores: Int { lock.withLock { personCount } }
        init(_ server: EditScenarioServer) { self.server = server }
        func personRestore(_ uids: [PhotoUID]) async throws {
            lock.withLock { personCount += 1 }
            try await server.restoreDuplicates(uids)
        }
        func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            lock.withLock { entered = true }
            await trashGate.wait()
            do {
                try await server.trashDuplicates(uids)
                lock.withLock { trashCount += 1 }
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            lock.withLock { compensationCount += 1 }
            do {
                try await server.restoreDuplicates(uids)
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .permanentFailure }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .permanentFailure }
    }

    @MainActor private final class Fixture {
        enum Shape { case photo, video, live }
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let server: EditScenarioServer
        let remote: Remote
        let pending: PendingBackupManifestStore
        let identities: UploadIdentityManifestStore
        let state: UploadBackupStateManifestStore
        let catalog: PhotoLibraryCatalogManifestStore
        let controller: PhotoLibraryBackupController
        let runner: BackupSyncRunner
        let tagAdder = SpyTagAdder()
        let resolver: Resolver
        let clock: BackupTestClock
        var session: PendingGridSession!
        var source: UploadSourceIdentity { resolver.resource.candidate.snapshot.source }
        var revision: UploadBackupRevision { resolver.resource.candidate.snapshot.revision }
        var key: PendingSourceKey { PendingSourceKey(source) }
        var queue: UploadBackupSyncQueueManifestStore { controller.queueStoreForTesting! }

        init(_ shape: Shape) throws {
            suite = "restore-acceptance-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults.set(true, forKey: "photoBackup.enabled.v1")
            defaults.set(true, forKey: "photoBackup.userPaused.v1")
            clock = BackupTestClock(start: Date().addingTimeInterval(2))
            server = EditScenarioServer()
            remote = Remote(server)
            pending = try XCTUnwrap(
                PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
            identities = try XCTUnwrap(
                UploadIdentityManifestStore(
                    url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
            let journal = try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: directory))
            let pipeline = UploadDedupePipeline(store: identities, checker: server, replacementJournal: journal)
            let replacement = EditedPhotoReplacement(
                remote: server, albums: server, relations: server, identities: identities, journal: journal)
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults)
            configuration.currentAccessState = { .full }
            controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: pipeline, uploader: server,
                tagAdder: tagAdder,
                editReplacement: replacement, pendingStore: pending, requiresPendingStore: true)
            state = try XCTUnwrap(
                UploadBackupStateManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
            catalog = try XCTUnwrap(
                PhotoLibraryCatalogManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName)))
            let date = Date(timeIntervalSince1970: 1_720_000_000)
            var resources: [PhotoBackupAssetInfo.Resource] = [
                .init(
                    role: shape == .video ? .originalVideo : .originalPhoto,
                    originalFilename: shape == .video ? "MAIN.MOV" : "MAIN.HEIC",
                    mimeType: shape == .video ? "video/quicktime" : "image/heic")
            ]
            if shape == .live {
                resources.append(.init(role: .pairedVideo, originalFilename: "PAIR.MOV", mimeType: "video/quicktime"))
            }
            let info = PhotoBackupAssetInfo(
                localIdentifier: "restore-acceptance", creationDate: date, modificationDate: date, pixelWidth: 10,
                pixelHeight: 10, durationSeconds: shape == .photo ? 0 : 1, isLivePhoto: shape == .live,
                isVideo: shape == .video, resources: resources)
            let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
            let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
            let resourceDirectory = directory
            func descriptor(_ item: PhotoBackupExportPlan.Item, primary: Bool) throws -> UploadResourceDescriptor {
                let url = resourceDirectory.appendingPathComponent(item.uploadFilename)
                let bytes = Data("restore-acceptance-\(item.uploadFilename)".utf8)
                try bytes.write(to: url)
                return UploadResourceDescriptor(
                    source: .init(
                        kind: .photoLibraryAsset, identifier: info.localIdentifier,
                        resource: primary ? .primary : item.sourceResource), fileURL: url,
                    filename: item.uploadFilename, fileSize: Int64(bytes.count), modificationDate: date,
                    precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: url))
            }
            resolver = Resolver(
                BackupResolvedResource(
                    candidate: candidate, descriptor: try descriptor(plan.primary, primary: true),
                    mediaType: plan.primary.mimeType ?? "image/heic", captureDate: date,
                    secondaries: try plan.secondaries.map {
                        BackupSecondaryResource(
                            descriptor: try descriptor($0, primary: false), mediaType: $0.mimeType ?? "video/quicktime")
                    }))
            runner = BackupSyncRunner(
                queue: controller.queueStoreForTesting!,
                preflight: UploadBackupPreflightIndex(store: state, now: { [clock] in clock.now }), resolver: resolver,
                identityResolver: pipeline, uploader: server, tagAdder: tagAdder,
                configuration: .init(throttle: .init(baseConcurrency: 1)),
                clock: clock, events: controller.pendingRecorder, now: { [clock] in clock.now })
        }

        func backUp() async throws -> PhotoUID {
            let engine = UploadBackupSyncEngine(
                preflight: UploadBackupPreflightIndex(store: state), queue: queue, exclusions: pending)
            _ = try await engine.enqueueBatch([resolver.resource.candidate])
            await drain()
            XCTAssertTrue(try XCTUnwrap(queue.entry(for: source, revision: revision)).state.isTerminalSuccess)
            XCTAssertEqual(server.uploadRequestCount, 1 + resolver.resource.secondaries.count)
            let main = PhotoUID(volumeID: "vol", nodeID: try XCTUnwrap(identities.record(for: source)?.remoteLinkID))
            XCTAssertEqual(
                pending.recordHandoff(
                    .init(key: key, revision: revision, remote: main, kind: .uploaded, createdAt: Date())), .recorded)
            return main
        }

        func exclude(_ main: PhotoUID, trashInFlight: Bool = false) throws {
            let excluded = try XCTUnwrap(
                pending.exclude(
                    [
                        .init(
                            key: key,
                            presentation: .init(
                                captureTime: Date(), mediaType: resolver.resource.mediaType,
                                displayName: "Restore acceptance"), remote: main, revision: revision)
                    ], at: Date())?.first)
            server.personTrash(main)
            XCTAssertTrue(pending.completeEffect(.queueSync, for: key, generation: excluded.generation, at: Date()))
            if trashInFlight {
                XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: [excluded]), [key])
            } else {
                XCTAssertTrue(
                    pending.completeEffect(
                        .remoteTrash, for: key, generation: excluded.generation, remoteLinkID: main.nodeID, at: Date()))
            }
            XCTAssertTrue(pending.unlistFromTrash([key], at: Date()))
        }

        func startSession(_ main: PhotoUID, waitForExcluded: Bool = true) async throws {
            session = try XCTUnwrap(PendingGridSession(store: pending, photoBackup: controller, remote: remote))
            let item = PhotoItem(
                uid: .init(volumeID: main.volumeID, nodeID: "volume-anchor"), captureTime: Date(),
                mediaType: "image/heic")
            session.setRemote(TimelineSnapshot(orderedItems: [item]))
            session.start()
            if waitForExcluded {
                for _ in 0..<500 where session.excludedTiles.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(session.excludedTiles.map(\.key), [key])
            }
        }

        func restore(_ main: PhotoUID) async throws -> PendingBackupRestoreResult {
            try await remote.personRestore([main])
            return await session.restoreSources(ofRemote: [main])
        }

        func drain() async {
            clock.advance(by: 2)
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
        }

        func execute(_ sql: String) throws {
            var handle: OpaquePointer?
            XCTAssertEqual(
                sqlite3_open_v2(
                    directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &handle,
                    SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }

        func rawSourceRow() throws -> [Data?] {
            var handle: OpaquePointer?
            XCTAssertEqual(
                sqlite3_open_v2(
                    directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &handle,
                    SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT * FROM source_state;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return (0..<sqlite3_column_count(statement)).map { column in
                guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
            }
        }

        func close() async {
            await remote.trashGate.release()
            await session?.close()
            await runner.stop()
            await controller.shutdown()
            state.close()
            catalog.close()
            identities.close()
            pending.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
