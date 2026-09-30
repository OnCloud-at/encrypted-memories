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

    func trashReplaced(_ uids: [PhotoUID]) async throws {
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
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
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
            EditReplacementJournalFileStore(accountDataDirectory: directory)?.entry(for: asset).superseded,
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

    func testOnlyPhotoLibraryPhotosWithAProvenEarlierUploadAreReplaced() async throws {
        // Uploaded by another client: the duplicate check proved that photo is this one, so it is replaced too.
        let adopted = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-adopted")
        let before = descriptor(adopted, filename: "IMG_2.HEIC", bytes: "theirs")
        checker.remoteItemsByNameHash["nh(IMG_2.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_2.HEIC)", contentHash: contentHash("theirs"), linkState: .active, linkID: "theirs")
        ]
        _ = try await pipeline.resolve(before)
        _ = try await pipeline.resolve(descriptor(adopted, filename: "IMG_2.JPG", bytes: "edited"))
        XCTAssertEqual(journal.entry(for: adopted).superseded, [PhotoUID(volumeID: "", nodeID: "theirs")])

        // A trashed duplicate proves nothing that is still visible.
        let trashed = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-trashed")
        checker.remoteItemsByNameHash["nh(IMG_4.HEIC)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_4.HEIC)", contentHash: contentHash("gone"), linkState: .trashed, linkID: "gone")
        ]
        _ = try await pipeline.resolve(descriptor(trashed, filename: "IMG_4.HEIC", bytes: "gone"))
        _ = try await pipeline.resolve(descriptor(trashed, filename: "IMG_4.JPG", bytes: "gone-edited"))
        XCTAssertTrue(journal.entry(for: trashed).isEmpty)

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

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(
            reopened.entry(for: asset), EditReplacementJournalEntry(superseded: [], retired: ["a", "a-video"]))
    }

    func testAJournalFromAnEarlierBuildDecodesWithoutARetireIntent() throws {
        let encoded = Data(
            #"{"photoLibraryAsset|asset-1|primary":{"superseded":[],"retired":["old"],"uploadedEdit":true}}"#.utf8)
        try encoded.write(to: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName))

        let reopened = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        XCTAssertEqual(reopened.entry(for: asset).retired, ["old"])
        XCTAssertNil(reopened.entry(for: asset).retireIntent)
        XCTAssertTrue(reopened.entry(for: asset).lastUploadWasEdit)
    }

    func testAnUnreadableJournalDisablesReplacementInsteadOfForgettingWaitingPhotos() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent(EditReplacementJournalFileStore.fileName))

        XCTAssertNil(EditReplacementJournalFileStore(accountDataDirectory: directory))
    }

    func testRetiredLinksHaveNoLimitSoAnUndoAfterManyEditsStillUploads() throws {
        for edit in 0..<100 {
            try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "edit-\(edit)"), for: asset)
            try journal.settle(["edit-\(edit)"], related: ["edit-\(edit)-original"], trashed: true, for: asset)
        }

        XCTAssertEqual(journal.entry(for: asset).retired.count, 200)
        XCTAssertTrue(journal.entry(for: asset).retired.contains("edit-0-original"))
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

    func testAPhotoTrashedAfterTheListingNamedItActiveIsNotUploadedAgain() async throws {
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "old"), for: asset)
        try journal.settle(["old"], related: [], trashed: true, for: asset)
        checker.remoteItemsByNameHash["nh(IMG_1.JPG)"] = [
            RemotePhotoDuplicate(
                nameHash: "nh(IMG_1.JPG)", contentHash: contentHash("rotated"), linkState: .active,
                linkID: "trashed-since")
        ]
        // The person trashed the photo after the listing: it was a main photo, not a related file.
        checker.linkVisibilityByID["trashed-since"] = RemoteLinkVisibility(isActive: false, mainPhotoLinkID: nil)

        let result = try await pipeline.resolve(descriptor(asset, filename: "IMG_1.JPG", bytes: "rotated"))

        XCTAssertEqual(
            result.decision, .skip(.trashedDuplicate, remoteLinkID: "trashed-since"),
            "the backup neither brings the photo back nor counts it as backed up")
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
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: albums, relations: checker, identities: store, journal: journal)

        try await replacement.replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertEqual(remote.favoriteCalls, [[new]])
        XCTAssertEqual(albums.addCalls.map(\.albumID), ["own-album"], "a shared album is never a write target")
        XCTAssertEqual(albums.addCalls.first?.uids, [new])
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(
            journal.entry(for: asset),
            EditReplacementJournalEntry(superseded: [], retired: ["old", "old-video"], uploadedEdit: true))
    }

    func testTheReplacementNeverTrashesThePhotoThatCarriesTheNewOne() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]
        checker.relatedLinkIDsByMainLinkID["old"] = ["new"]
        let replacement = EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, identities: store, journal: journal)

        try await replacement.replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty, "the trash takes related photos along")
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    private func makeReplacement(_ remote: FakeEditReplacementRemote) -> EditedPhotoReplacement {
        EditedPhotoReplacement(
            remote: remote, albums: FakeAlbumCarryOver(), relations: checker, identities: store, journal: journal)
    }

    func testAnEarlierPhotoThatAnotherLibraryAssetNeedsStays() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        // A duplicate in Photos proved its backup through the same photo.
        try await upload(
            descriptor(
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-duplicate"), filename: "IMG_9.HEIC",
                bytes: "shared"), as: "old")
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]

        try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    func testAnEarlierPhotoStaysWhenTheNewCompoundDoesNotHoldTheOriginal() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: false)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the earlier photo may be the only copy of the original")
        XCTAssertEqual(
            journal.entry(for: asset).superseded, [old], "an upload that holds the original replaces it later")
    }

    func testOnlyAnUneditedPrimaryOrAnOriginalSecondaryHoldsTheOriginal() {
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .revision(UploadBackupRevision(rawValue: 1)), secondaries: []))
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable, secondaries: [.photoKit(role: "originalPhoto", ordinal: 0)]))
        XCTAssertTrue(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable, secondaries: [.photoKit(role: "originalVideo", ordinal: 0)]))
        XCTAssertFalse(
            EditedPhotoReplacement.holdsOriginal(
                editRevision: .unavailable,
                secondaries: [.livePairedVideo, .photoKit(role: "adjustmentData", ordinal: 0)]))
    }

    /// A manifest row of `asset` that names `linkID`, as the backup writes it after an upload.
    private func row(_ resource: UploadSourceIdentity.Resource, at linkID: String) -> UploadSourceIdentity {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: asset.identifier, resource: resource)
        store.upsert(
            UploadIdentityRecord(
                source: source, filename: linkID, correctedName: linkID, fileSize: 1, modificationDate: .distantPast,
                sha1Hex: linkID, nameHash: "nh(\(linkID))", contentHash: "ch(\(linkID))", hashKeyEpoch: "epoch",
                remoteVolumeID: "vol", remoteLinkID: linkID,
                outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: .distantPast))
        return source
    }

    private func supersede(_ nodeID: String, related: Set<String> = []) -> (PhotoUID, FakeEditReplacementRemote) {
        let old = PhotoUID(volumeID: "vol", nodeID: nodeID)
        try? journal.addSuperseded(old, for: asset)
        checker.relatedLinkIDsByMainLinkID[nodeID] = related
        let remote = FakeEditReplacementRemote()
        // The photo that replaces the earlier one is in the library, like the upload that just finished.
        remote.active = [old, new]
        return (old, remote)
    }

    private let new = PhotoUID(volumeID: "vol", nodeID: "new")

    func testOtherBytesOfAPhotoThatWasNeverEditedReplaceNothing() async throws {
        let (_, remote) = supersede("old")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertTrue(remote.trashCalls.isEmpty, "only an edit or its undo replaces the earlier photo")
        XCTAssertTrue(journal.entry(for: asset).isEmpty)
    }

    func testUndoingAnEditThatTheBackupUploadedReplacesTheEdit() async throws {
        try await makeReplacement(FakeEditReplacementRemote()).replaceSuperseded(
            of: asset, with: PhotoUID(volumeID: "vol", nodeID: "edit"), edited: true, holdsOriginal: true)
        XCTAssertTrue(journal.entry(for: asset).lastUploadWasEdit)
        let (old, remote) = supersede("edit")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertFalse(journal.entry(for: asset).lastUploadWasEdit)
    }

    func testAPhotoThatAnEarlierBuildReplacedCountsAsEdited() async throws {
        // Journals of earlier builds have no edit flag, only the retired photos.
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "original"), for: asset)
        try journal.settle(["original"], related: [], trashed: true, for: asset)
        let (old, remote) = supersede("edit")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testAnEarlierPhotoStaysWhileTheLivePhotoVideoLivesOnlyUnderIt() async throws {
        let video = row(.livePairedVideo, at: "old-video")
        let (old, remote) = supersede("old", related: ["old-video"])

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the edit did not upload the video of the Live Photo again")
        XCTAssertEqual(
            journal.entry(for: asset).superseded, [old], "the earlier photo waits instead of staying for good")

        // The next edit uploads the video again under the new photo.
        _ = row(.livePairedVideo, at: "new-video")
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(store.record(for: video)?.remoteLinkID, "new-video")
    }

    func testAWaitingUndoStillReplacesTheEditOnItsNextAttempt() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        try journal.recordUpload(edited: true, for: asset)
        let (old, remote) = supersede("old", related: ["old-video"])

        let first = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: false, holdsOriginal: true)
        let second = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(first, .waiting)
        XCTAssertEqual(second, .waiting, "the retry still knows that the waiting upload undoes an edit")
        XCTAssertEqual(journal.entry(for: asset).superseded, [old])
        XCTAssertTrue(remote.trashCalls.isEmpty)
    }

    func testEarlierPhotosDoNotWaitForAPhotoThatThePersonTrashed() async throws {
        _ = row(.livePairedVideo, at: "old-video")
        let (old, remote) = supersede("old", related: ["old-video"])
        remote.active = [old]

        let outcome = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(outcome, .replacementGone)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the earlier photo stays")
    }

    func testTheOriginalOfAnEditStaysUntilAnUneditedPrimaryCarriesIt() async throws {
        _ = row(.photoKit(role: "originalPhoto", ordinal: 0), at: "old-original")
        try journal.recordUpload(edited: true, for: asset)
        let (old, remote) = supersede("old", related: ["old-original"])

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the new edit did not upload the original again")

        // The undo uploads the original itself as the new photo.
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)
        XCTAssertEqual(remote.trashCalls, [[old]])
    }

    func testRowsThatNameATrashedPhotoNoLongerProveABackup() async throws {
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "old-adjustments")
        let (old, remote) = supersede("old", related: ["old-adjustments"])

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)
        XCTAssertTrue(remote.trashCalls.isEmpty)
        XCTAssertEqual(store.record(for: adjustments)?.remoteLinkID, "old-adjustments")

        try journal.recordUpload(edited: true, for: asset)
        try journal.addSuperseded(old, for: asset)
        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: false, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        let forgotten = try XCTUnwrap(store.record(for: adjustments))
        XCTAssertNil(forgotten.remoteLinkID, "a trashed photo must not count as the backup of equal bytes")
        XCTAssertNil(forgotten.outcome)
        XCTAssertNil(store.trustedRecord(contentHash: "ch(old-adjustments)", hashKeyEpoch: "epoch"))
    }

    func testARestoredPhotoThatAnotherSourceAdoptedKeepsItsRow() async throws {
        // An earlier edit trashed "restored"; the person restored it, and a duplicate in Photos proved its backup.
        try journal.addSuperseded(PhotoUID(volumeID: "vol", nodeID: "restored"), for: asset)
        try journal.settle(["restored"], related: [], trashed: true, for: asset)
        try await upload(
            descriptor(
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-duplicate"), filename: "IMG_9.HEIC",
                bytes: "restored"), as: "restored")
        let (old, remote) = supersede("old")

        try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(remote.trashCalls, [[old]])
        XCTAssertEqual(
            store.sources(withRemoteLinkID: "restored")?.map(\.identifier), ["asset-duplicate"],
            "only the rows of the edited photo forget its trashed photos")
    }

    func testARetryAfterAFailedManifestWriteStillForgetsTheTrashedPhotos() async throws {
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "old-adjustments")
        let (old, remote) = supersede("old", related: ["old-adjustments"])
        store.rejectNextForget()

        do {
            try await makeReplacement(remote).replaceSuperseded(of: asset, with: new, edited: true, holdsOriginal: true)
            XCTFail("the manifest write fails")
        } catch {}
        XCTAssertEqual(remote.trashCalls, [[old]])

        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty)
        XCTAssertEqual(journal.entry(for: asset).retireIntent, ["old": ["old-adjustments"]])
        checker.relatedLinkIDsByMainLinkID["old"] = []
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        let changed = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(changed, .replaced(retiredAny: true), "the cached rows still show the trashed photo")
        XCTAssertEqual(journal.entry(for: asset).retired, ["old", "old-adjustments"])
        XCTAssertNil(journal.entry(for: asset).retireIntent)
        XCTAssertEqual(remote.trashCalls, [[old]], "the trash runs once")
        XCTAssertNil(store.record(for: adjustments)?.remoteLinkID)
        XCTAssertTrue(journal.entry(for: asset).superseded.isEmpty)
    }

    func testARetryAfterPartialTrashRetiresOnlyTheConfirmedMainAndItsRecordedRelatedFiles() async throws {
        let first = PhotoUID(volumeID: "vol", nodeID: "first")
        let second = PhotoUID(volumeID: "vol", nodeID: "second")
        try journal.addSuperseded(first, for: asset)
        try journal.addSuperseded(second, for: asset)
        try journal.prepareToRetire(
            ["first": ["first-adjustments"], "second": ["second-video"]], for: asset)
        let adjustments = row(.photoKit(role: "adjustmentData", ordinal: 0), at: "first-adjustments")
        _ = row(.livePairedVideo, at: "second-video")
        checker.relatedLinkIDsByMainLinkID["second"] = ["second-video"]
        let remote = FakeEditReplacementRemote()
        remote.active = [second, new]
        journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))

        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)

        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(remote.trashCalls.isEmpty, "the remaining main protects the video")
        XCTAssertEqual(journal.entry(for: asset).retired, ["first", "first-adjustments"])
        XCTAssertEqual(journal.entry(for: asset).superseded, [second])
        XCTAssertNil(journal.entry(for: asset).retireIntent)
        XCTAssertNil(store.record(for: adjustments)?.remoteLinkID)

        _ = row(.livePairedVideo, at: "new-video")
        let replaced = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(replaced, .replaced(retiredAny: true))
        XCTAssertEqual(remote.trashCalls, [[second]])
        XCTAssertEqual(
            Set(journal.entry(for: asset).retired), ["first", "first-adjustments", "second", "second-video"])
    }

    func testOnlyPhotoLibraryPhotosRecordTheirEdits() async throws {
        let file = UploadSourceIdentity.file(URL(fileURLWithPath: "/folder/IMG_3.HEIC"))

        try await makeReplacement(FakeEditReplacementRemote()).replaceSuperseded(
            of: file, with: new, edited: true, holdsOriginal: true)

        XCTAssertTrue(journal.entry(for: file).isEmpty)
    }

    func testRelatedPhotosAreJournaledBeforeTheTrashSoACrashCannotLoseThem() async throws {
        let old = PhotoUID(volumeID: "vol", nodeID: "old")
        try journal.addSuperseded(old, for: asset)
        let remote = FakeEditReplacementRemote()
        remote.active = [old, PhotoUID(volumeID: "vol", nodeID: "new")]
        remote.trashFailures = 1
        checker.relatedLinkIDsByMainLinkID["old"] = ["old-video"]

        do {
            try await makeReplacement(remote).replaceSuperseded(
                of: asset, with: PhotoUID(volumeID: "vol", nodeID: "new"), edited: true, holdsOriginal: true)
            XCTFail("the trash write fails")
        } catch {}

        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty, "the failed trash leaves related files active")
        XCTAssertEqual(journal.entry(for: asset).retireIntent, ["old": ["old-video"]])
        XCTAssertEqual(journal.entry(for: asset).superseded, [old], "the earlier photo still waits for its trash")

        // On retry, the earlier main is still active and protects this source's original video.
        _ = row(.livePairedVideo, at: "old-video")
        let waiting = try await makeReplacement(remote).replaceSuperseded(
            of: asset, with: new, edited: true, holdsOriginal: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertNil(journal.entry(for: asset).retireIntent, "an active target loses the earlier trash intent")
        XCTAssertTrue(journal.entry(for: asset).retired.isEmpty)
        XCTAssertTrue(remote.trashCalls.isEmpty)
    }
}
