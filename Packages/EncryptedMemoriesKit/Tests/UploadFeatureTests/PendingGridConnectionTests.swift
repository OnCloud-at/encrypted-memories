import Foundation
import Observation
import PhotosCore
import Testing
import UploadCore

@testable import PhotoLibraryBackupAdapter

@Suite @MainActor struct PendingGridConnectionTests {
    @Test func aStoreWithoutASessionStaysForTheTeardown() async throws {
        let fixture = try Fixture(pendingStoreInController: false)
        defer { fixture.remove() }
        let connection = PendingGridConnection()

        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }

        #expect(started == nil, "a controller without a pending recorder cannot start a session")
        #expect(connection.session == nil)
        let retired = connection.retire()
        #expect(retired.session == nil)
        #expect(retired.store === fixture.store, "the teardown still closes the opened store")
        #expect(connection.retire().store == nil, "a retired store is handed out once")
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func withoutAStoreNoSessionIsBuilt() {
        let connection = PendingGridConnection()
        var built = false

        let started = connection.start(store: nil) { _ in
            built = true
            return nil
        }

        #expect(started == nil)
        #expect(!built)
        #expect(connection.retire().store == nil)
    }

    @Test func onlyChangedFavoriteIntentsRaiseTheRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let session = try #require(started)
        #expect(connection.session === session)
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID

        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 1 }, "a new intent refreshes favorite displays")
        #expect(await eventually { session.pendingSnapshot.favoriteIntents == [uid: true] })

        // The same intent publishes another snapshot with unchanged intents.
        let published = session.pendingSnapshot.membershipRevision
        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { session.pendingSnapshot.membershipRevision != published })
        #expect(connection.favoriteRevision == 1, "unchanged intents do not refresh favorite displays")

        #expect(await session.setFavorite([uid], favorite: false))
        #expect(await eventually { connection.favoriteRevision == 2 })

        let retired = connection.retire()
        #expect(retired.session === session)
        #expect(retired.store === fixture.store)
        #expect(connection.session == nil)
        #expect(connection.favoriteRevision == 3, "retiring refreshes favorite displays")
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func retiringForgetsTheFavoriteIntentsOfTheEarlierSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        let startedFirst = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let first = try #require(startedFirst)
        #expect(await first.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 1 })
        _ = connection.retire()
        await first.close()
        #expect(connection.favoriteRevision == 2)

        // The next session reads the same stored intent; it is new for the connection.
        let startedSecond = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let second = try #require(startedSecond)
        #expect(await second.setFavorite([uid], favorite: true))
        #expect(await eventually { connection.favoriteRevision == 3 })
        _ = connection.retire()
        await second.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func albumAddsReachOnlyALiveSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let installed = HandlerBox()
        var prepared: PendingGridSession?
        var session = connection.start(
            store: fixture.store,
            makeSession: {
                PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
            },
            albumAdds: { await installed.set($0) },
            prepare: { prepared = $0 }
        )
        #expect(session != nil)
        #expect(prepared === session, "the host prepares the session it shows")
        prepared = nil
        weak var released = session
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-album").localUID

        #expect(await eventually { await installed.handler != nil }, "the albums learn where pending adds go")
        let handler = try #require(await installed.handler)
        #expect(await handler([uid], "album"), "the live session records the album add")

        _ = connection.retire()
        await session?.close()
        session = nil
        #expect(await eventually { released == nil }, "the album bridge does not keep the session alive")
        #expect(await handler([uid], "album") == false, "a released session records nothing")
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func theHostPreparesTheSessionBeforeItStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        var startedBeforePrepare: Bool?

        let started = connection.start(
            store: fixture.store,
            makeSession: { PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects()) },
            prepare: { _ in startedBeforePrepare = fixture.controller.onLibraryChange != nil }
        )

        #expect(startedBeforePrepare == false, "the presentation is attached before the first snapshot")
        #expect(fixture.controller.onLibraryChange != nil, "the session started after the host prepared it")
        _ = connection.retire()
        await started?.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    @Test func screensThatReadTheConnectionAreToldAboutEveryChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = PendingGridConnection()
        let changes = ChangeCounter()
        func observe() {
            withObservationTracking {
                _ = connection.session
                _ = connection.trash
                _ = connection.excludedTiles
                _ = connection.favoriteRevision
            } onChange: {
                changes.count += 1
            }
        }

        observe()
        let started = connection.start(store: fixture.store) {
            PendingGridSession(store: $0, photoBackup: fixture.controller, remote: NoRemoteEffects())
        }
        let session = try #require(started)
        #expect(changes.count == 1, "showing the pending grid reaches the screen")

        observe()
        let uid = PendingSourceKey(kind: .photoLibraryAsset, identifier: "local-favorite").localUID
        #expect(await session.setFavorite([uid], favorite: true))
        #expect(await eventually { changes.count == 2 }, "a new favorite intent reaches the screen")

        observe()
        _ = connection.retire()
        #expect(changes.count == 3, "retiring the pending grid reaches the screen")
        await session.close()
        await fixture.controller.shutdown()
        fixture.store.close()
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

private actor HandlerBox {
    private(set) var handler: (@Sendable ([PhotoUID], String) async -> Bool)?
    func set(_ handler: @escaping @Sendable ([PhotoUID], String) async -> Bool) { self.handler = handler }
}

@MainActor
private struct Fixture {
    let suite = "pending-grid-connection-\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let store: PendingBackupManifestStore
    let controller: PhotoLibraryBackupController

    init(pendingStoreInController: Bool = true) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: nil,
            uploader: MockUploader(),
            pendingStore: pendingStoreInController ? store : nil,
            requiresPendingStore: pendingStoreInController
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NoRemoteEffects: PendingRemoteEffects {
    func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}
