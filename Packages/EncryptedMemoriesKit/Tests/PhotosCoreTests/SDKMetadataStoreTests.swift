import XCTest

@testable import PhotosCore

/// A full sign-out must erase the encrypted SDK cache so no
/// account-tied data survives, while the Settings "Delete Offline Cache" action must stay narrower
/// (cached media only, keeps the account key, stays signed in). `SDKMetadataStore` is the testable
/// authority for which files the sign-out purge removes; these tests pin that it deletes the
/// current account's cache and leaves other account data untouched.
final class SDKMetadataStoreTests: XCTestCase {
    private let uid = "user-ABC123"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDKMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ name: String, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testMetadataFileNamesCoverCurrentCacheAndSidecars() {
        let names = Set(SDKMetadataStore.metadataFileNames(uid: uid))
        XCTAssertTrue(
            names.isSuperset(of: [
                "sdk-cache-v1-\(uid).sqlite",
                "sdk-cache-v1-\(uid).sqlite-wal",
                "sdk-cache-v1-\(uid).sqlite-shm",
            ]))
        XCTAssertEqual(names.count, 3, "one store × {main, -wal, -shm}")
    }

    func testCacheFileNameIsScopedToTheGivenUID() {
        let names = SDKMetadataStore.metadataFileNames(uid: "OTHER")
        XCTAssertTrue(names.contains("sdk-cache-v1-OTHER.sqlite"))
        XCTAssertFalse(names.contains("sdk-cache-v1-\(uid).sqlite"))
    }

    func testPurgeDeletesAllMetadataFilesAndReportsCount() throws {
        let dir = try makeTempDir()
        for name in SDKMetadataStore.metadataFileNames(uid: uid) { try write(name, in: dir) }

        let removed = SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        XCTAssertEqual(removed, 3, "the current cache and sidecars are removed")
        for name in SDKMetadataStore.metadataFileNames(uid: uid) {
            XCTAssertFalse(exists(name, in: dir), "\(name) should be gone after sign-out purge")
        }
    }

    func testPurgeIsBestEffortWhenSidecarsAbsent() throws {
        let dir = try makeTempDir()
        // Only the main SQLite file exists (no WAL/SHM, e.g. clean shutdown).
        try write("sdk-cache-v1-\(uid).sqlite", in: dir)

        let removed = SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        XCTAssertEqual(removed, 1, "only the present file counts as removed")
        XCTAssertFalse(exists("sdk-cache-v1-\(uid).sqlite", in: dir))
    }

    func testPurgeLeavesUnrelatedFilesIntact() throws {
        let dir = try makeTempDir()
        for name in SDKMetadataStore.metadataFileNames(uid: uid) { try write(name, in: dir) }

        // Co-located artifacts that the metadata purge must not touch - they're erased (or kept) by
        // their own paths. This is what keeps sign-out's full purge distinct from cache-clear and
        // scoped per account.
        let bystanders = [
            "account-users-\(uid).enc",  // AccountDataCache - cleared separately on sign-out
            "account-addresses-\(uid).enc",
            "sdk-cache-v1-OTHER-UID.sqlite",  // a different account's SDK cache
            "unrelated.sqlite",
        ]
        for name in bystanders { try write(name, in: dir) }

        SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        for name in bystanders {
            XCTAssertTrue(exists(name, in: dir), "\(name) must survive the scoped metadata purge")
        }
    }

    func testPurgeOnEmptyDirectoryRemovesNothing() throws {
        let dir = try makeTempDir()
        XCTAssertEqual(SDKMetadataStore.purgeMetadata(in: dir, uid: uid), 0)
    }
}
