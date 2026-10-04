import Foundation
import Testing
import UploadCore

@testable import AlbumSyncCore

@MainActor @Suite struct AlbumSyncLastRunStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-last-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let items = [
        BackupFailedItem(
            id: "album/a", filename: "a.heic", reason: "attach reason", isPermanent: false, isRetryable: true,
            category: .userResolvable),
        BackupFailedItem(
            id: "queue-b", filename: "b.heic", reason: "gone reason", isPermanent: true, issue: .sourceMissing),
    ]

    private func relaunch(_ directory: URL) async -> AlbumSyncLastRunStore {
        let store = AlbumSyncLastRunStore(directory: directory)
        await store.load()
        return store
    }

    @Test func listSurvivesARelaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        await store.flush()

        let relaunched = await relaunch(directory)

        let loaded = relaunched.items(albumID: "L1")
        #expect(loaded.map(\.id) == ["album/a", "queue-b"])
        #expect(loaded.map(\.filename) == ["a.heic", "b.heic"])
        #expect(loaded.map(\.reason) == ["attach reason", "gone reason"])
        #expect(loaded.map(\.category) == [.userResolvable, .permanent])
        #expect(loaded.map(\.isPermanent) == [false, true])
        #expect(relaunched.items(albumID: "L2").isEmpty)
    }

    @Test func emptyListClearsTheAlbumAndRemovesTheFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        await store.flush()
        let url = directory.appendingPathComponent(AlbumSyncLastRunStore.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.record([], albumID: "L1")
        await store.flush()

        #expect(store.items(albumID: "L1").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await relaunch(directory).items(albumID: "L1").isEmpty)
    }

    @Test func clearingOneAlbumKeepsTheOthers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await relaunch(directory)
        store.record(items, albumID: "L1")
        store.record([items[0]], albumID: "L2")

        store.record([], albumID: "L1")
        await store.flush()

        let relaunched = await relaunch(directory)
        #expect(relaunched.items(albumID: "L1").isEmpty)
        #expect(relaunched.items(albumID: "L2").map(\.id) == ["album/a"])
    }

    @Test func unreadableFileMeansNoLists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent(AlbumSyncLastRunStore.fileName))

        let store = await relaunch(directory)

        #expect(store.items(albumID: "L1").isEmpty)
        // The next finished run rewrites the cache.
        store.record(items, albumID: "L1")
        await store.flush()
        #expect(await relaunch(directory).items(albumID: "L1").count == 2)
    }

    @Test func aListRecordedBeforeTheFileLoadsWinsAndKeepsTheOtherAlbums() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = await relaunch(directory)
        earlier.record(items, albumID: "L1")
        earlier.record(items, albumID: "L2")
        earlier.record(items, albumID: "L3")
        await earlier.flush()

        let store = AlbumSyncLastRunStore(directory: directory)
        // Runs finish before the file has loaded: one list changes, one clears.
        store.record([items[1]], albumID: "L1")
        store.record([], albumID: "L2")
        await store.flush()
        // Until the load, the file keeps every album: an exit now loses no list.
        #expect(await relaunch(directory).items(albumID: "L3").count == 2)
        await store.load()
        await store.flush()

        #expect(store.items(albumID: "L1").map(\.id) == ["queue-b"])
        let relaunched = await relaunch(directory)
        #expect(relaunched.items(albumID: "L1").map(\.id) == ["queue-b"])
        #expect(relaunched.items(albumID: "L2").isEmpty)
        #expect(relaunched.items(albumID: "L3").count == 2, "an album that only the file knew stays")
    }

    @Test func anAlbumKeepsAtMostTheListLimit() throws {
        let store = AlbumSyncLastRunStore(directory: try makeDirectory())
        let many = (0..<(AlbumSyncLastRunStore.itemLimit + 5)).map {
            BackupFailedItem(id: "\($0)", filename: "\($0).heic", reason: "r", isPermanent: false)
        }

        store.record(many, albumID: "L1")

        #expect(store.items(albumID: "L1").count == AlbumSyncLastRunStore.itemLimit)
        #expect(store.items(albumID: "L1").first?.id == "0")
    }
}
