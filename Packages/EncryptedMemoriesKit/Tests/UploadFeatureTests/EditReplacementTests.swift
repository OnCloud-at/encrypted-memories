import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Records the remote writes of an edit replacement.
final class FakeEditReplacementRemote: EditReplacementRemote, @unchecked Sendable {
    private let lock = NSLock()
    var active: Set<PhotoUID> = []
    var favorites: Set<PhotoUID> = []
    /// The number of trash writes that fail before one succeeds.
    var trashFailures = 0
    private(set) var trashed: [[PhotoUID]] = []
    private(set) var markedFavorite: [[PhotoUID]] = []

    func ownPhotosVolumeID() async throws -> String { "vol" }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { active.intersection(uids) }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { favorites.intersection(uids) }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        lock.withLock {
            markedFavorite.append(uids)
            favorites.formUnion(uids)
        }
    }

    func trash(_ uids: [PhotoUID]) async throws {
        try lock.withLock {
            if trashFailures > 0 {
                trashFailures -= 1
                throw UploadError.backend("trash failed")
            }
            trashed.append(uids)
            active.subtract(uids)
        }
    }

    var trashCalls: [[PhotoUID]] { lock.withLock { trashed } }
    var favoriteCalls: [[PhotoUID]] { lock.withLock { markedFavorite } }
}

final class FakeAlbumCarryOver: SeriesAlbumCarryOver, @unchecked Sendable {
    private let lock = NSLock()
    var memberships: [PhotoUID: [SeriesAlbumReference]] = [:]
    private(set) var added: [(uids: [PhotoUID], albumID: String)] = []

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        lock.withLock { memberships[uid] ?? [] }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        lock.withLock { added.append((uids, albumID)) }
    }

    var addCalls: [(uids: [PhotoUID], albumID: String)] { lock.withLock { added } }
}

final class EditReplacementTests: XCTestCase {
    private var directory: URL!
    private var journal: EditReplacementJournalFileStore!
    private var store: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!

    private let asset = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-replacement-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = EditReplacementJournalFileStore(accountDataDirectory: directory)
        store = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker, replacementJournal: journal)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func digest(_ seed: String) -> Data {
        var digest = Data(repeating: 0, count: 20)
        for (index, byte) in seed.utf8.enumerated() { digest[index % 20] ^= byte }
        return digest
    }

    private func contentHash(_ seed: String) -> String {
        "ch(\(UploadContentSHA1.hexString(digest: digest(seed))))"
    }

    private func descriptor(
        _ source: UploadSourceIdentity,
        filename: String,
        bytes: String,
        mainRemoteLinkID: String? = nil,
        requiresRelatedMatch: Bool = false
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: URL(fileURLWithPath: "/export/\(filename)"),
            filename: filename,
            fileSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            precomputedSHA1Digest: digest(bytes),
            mainRemoteLinkID: mainRemoteLinkID,
            requiresRelatedMatch: requiresRelatedMatch
        )
    }

    private func upload(_ descriptor: UploadResourceDescriptor, as linkID: String) async throws {
        let result = try await pipeline.resolve(descriptor)
        XCTAssertEqual(result.decision, .upload)
        try await pipeline.recordUploaded(
            descriptor, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: linkID)
    }

    // MARK: - Journal

    func testAnEditedPhotoKeepsItsEarlierUploadInTheJournalEvenWhenTheCheckFails() async throws {
        try await upload(descriptor(asset, filename: "IMG_1.HEIC", bytes: "original"), as: "old")

        checker.findError = UploadError.transport(code: NSURLErrorTimedOut, message: "offline")
        do {
            _ = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))
            XCTFail("the offline duplicate check must fail")
        } catch {}

        XCTAssertNil(store.record(for: asset)?.remoteLinkID, "the manifest record now describes the edited bytes")
        XCTAssertEqual(
            EditReplacementJournalFileStore(accountDataDirectory: directory).entry(for: asset).superseded,
            [PhotoUID(volumeID: "vol", nodeID: "old")],
            "the earlier photo must survive on disk before the manifest forgets it")
    }

    func testAnUnchangedPhotoWritesNoJournal() async throws {
        let original = descriptor(asset, filename: "IMG_1.HEIC", bytes: "original")
        try await upload(original, as: "old")

        let again = try await pipeline.resolve(original)

        XCTAssertEqual(again.decision, .skip(.knownFromManifest, remoteLinkID: "old"))
        XCTAssertTrue(journal.entry(for: asset).isEmpty)
    }

    func testOnlyPhotosThisInstallationUploadedFromThePhotoLibraryAreReplaced() async throws {
        // Adopted from another client: that photo is not ours to trash.
        let adopted = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-adopted")
        let before = descriptor(adopted, filename: "IMG_2.HEIC", bytes: "theirs")
        checker.remoteItemsByNameHash["nh(IMG_2.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_2.HEIC)", contentHash: contentHash("theirs"), linkState: .active, linkID: "theirs")
        ]
        _ = try await pipeline.resolve(before)
        _ = try await pipeline.resolve(descriptor(adopted, filename: "IMG_2.JPG", bytes: "edited"))
        XCTAssertTrue(journal.entry(for: adopted).isEmpty)

        // A file of a watched folder has no photo-library edit.
        let file = UploadSourceIdentity.file(URL(fileURLWithPath: "/folder/IMG_3.HEIC"))
        try await upload(descriptor(file, filename: "IMG_3.HEIC", bytes: "first"), as: "file-old")
        _ = try await pipeline.resolve(descriptor(file, filename: "IMG_3.HEIC", bytes: "second"))
        XCTAssertTrue(journal.entry(for: file).isEmpty)
    }

    func testTheJournalRetiresTrashedPhotosWithTheirRelatedPhotosAndSurvivesARelaunch() throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "a"), for: asset)
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "b"), for: asset)

        try journal.settle(["a"], related: ["a-video"], trashed: true, for: asset)
        try journal.settle(["b"], related: [], trashed: false, for: asset)

        let reopened = EditReplacementJournalFileStore(accountDataDirectory: directory)
        XCTAssertEqual(reopened.entry(for: asset), EditReplacementJournalEntry(superseded: [], retired: ["a", "a-video"]))
    }

    // MARK: - Dedupe rules

    func testASecondaryOfAReplacingEditIgnoresItsCopyUnderTheEarlierPhoto() async throws {
        let original = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: "asset-1", resource: .photoKit(role: "originalPhoto", ordinal: 0))
        try await upload(descriptor(original, filename: "IMG_1.HEIC", bytes: "original"), as: "original-old")

        let strict = try await pipeline.resolve(
            descriptor(
                original, filename: "IMG_1.HEIC", bytes: "original", mainRemoteLinkID: "edited-new",
                requiresRelatedMatch: true))
        XCTAssertEqual(strict.decision, .upload, "the earlier copy moves to the trash with the earlier photo")
        await pipeline.uploadDidFail(descriptor(original, filename: "IMG_1.HEIC", bytes: "original"))

        checker.relatedLinkIDsByMainLinkID["edited-new"] = ["original-new"]
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .active,
                linkID: "original-new")
        ]
        await pipeline.invalidateCachedRemoteState()
        let retried = try await pipeline.resolve(
            descriptor(
                original, filename: "IMG_1.HEIC", bytes: "original", mainRemoteLinkID: "edited-new",
                requiresRelatedMatch: true))
        XCTAssertEqual(
            retried.decision, .skip(.activeDuplicate, remoteLinkID: "original-new"),
            "a copy under the edited photo settles the secondary, so a retry uploads nothing twice")
    }

    func testUndoingAnEditUploadsTheOriginalAgainInsteadOfAdoptingAHiddenOrTrashedCopy() async throws {
        // State after one completed replacement: the original "old" is trashed (retired); the edited photo
        // "edited" is the current upload and carries the original as its hidden related photo "hidden".
        try await upload(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"), as: "edited")
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        let hiddenSource = UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: "asset-1", resource: .photoKit(role: "originalPhoto", ordinal: 0))
        store.upsert(
            UploadIdentityRecord(
                source: hiddenSource, filename: "IMG_1.HEIC", correctedName: "IMG_1.HEIC", fileSize: 10,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                sha1Hex: UploadContentSHA1.hexString(digest: digest("original")), nameHash: "nh(IMG_1.HEIC)",
                contentHash: contentHash("original"), hashKeyEpoch: checker.epoch, remoteVolumeID: "vol",
                remoteLinkID: "hidden", outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue,
                updatedAt: Date()))
        checker.relatedLinkIDsByMainLinkID["edited"] = ["hidden"]
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .trashed, linkID: "old"),
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.HEIC)", contentHash: contentHash("original"), linkState: .active, linkID: "hidden"),
        ]

        let reverted = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.HEIC", bytes: "original"))

        XCTAssertEqual(reverted.decision, .upload, "the original shows as a photo again")
        XCTAssertEqual(journal.entry(for: asset).superseded, [PhotoUID(volumeID: "vol", nodeID: "edited")])
    }

    func testAPhotoThePersonTrashedStaysTrashed() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"), linkState: .trashed,
                linkID: "deleted-by-person")
        ]

        let result = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))

        XCTAssertEqual(result.decision, .skip(.trashedDuplicate, remoteLinkID: "deleted-by-person"))
    }

    // MARK: - Replacement

    func testTheReplacementCarriesFavoriteAndAlbumsOverBeforeItTrashesTheEarlierPhoto() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        let new = PhotoUID(volumeID: "vol", nodeID: "new")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, new]
        remote.favorites = [old]
        let albums = FakeAlbumCarryOver()
        albums.memberships[old] = [
            SeriesAlbumReference(volumeID: "vol", albumID: "own-album"),
            SeriesAlbumReference(volumeID: "shared-vol", albumID: "shared-album"),
        ]
        checker.relatedLinkIDsByMainLinkID["old"] = ["old-video"]
        let replacement = EditedPhotoReplacement(remote: remote, albums: albums, relations: checker, journal: journal)

        try await replacement.replaceSuperseded(of: asset, with: PhotoUID(volumeID: "", nodeID: "new"))

        XCTAssertEqual(remote.favoriteCalls, [[new]])
        XCTAssertEqual(albums.addCalls.map(\.albumID), ["own-album"], "a shared album is never a write target")
        XCTAssertEqual(albums.addCalls.first?.uids, [new])
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(journal.entry(for: asset), EditReplacementJournalEntry(superseded: [], retired: ["old", "old-video"]))
    }

    func testTheReplacementNeverTrashesThePhotoThatCarriesTheNewOne() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old]
        checker.relatedLinkIDsByMainLinkID["old"] = ["new"]
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, journal: journal)

        try await replacement.replaceSuperseded(of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"))

        XCTAssertTrue(remote.trashCalls.isEmpty, "the trash takes related photos along")
        XCTAssertTrue(journal.entry(for: asset).isEmpty)
    }
}
