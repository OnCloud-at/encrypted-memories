import Foundation
import PhotosCore
import Testing
import UploadCore

@testable import AlbumSyncCore

@Suite struct AlbumSyncPhotoRecoveryTests {
    @Test func exactTrashRestoresOnlyTheRecordedLink() async throws {
        let remote = RecoveryRemote()
        let result = try await AlbumSyncPhotoRecovery.restore(
            record: record(), descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
            validate: {})
        #expect(result == .restored)
        #expect(await remote.restored == [PhotoUID(volumeID: "volume", nodeID: "trash")])
        #expect(await remote.evidenceReads == 1)
    }

    @Test func alreadyActiveNeedsNoRestore() async throws {
        let remote = RecoveryRemote(state: .active)
        let result = try await AlbumSyncPhotoRecovery.restore(
            record: record(), descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
            validate: {})
        #expect(result == .alreadyActive)
        #expect(await remote.restored.isEmpty)
    }

    @Test func unknownNeverRestores() async {
        let remote = RecoveryRemote(state: .unavailable)
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: record(), descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
                validate: {})
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test func changedSourceNeverRestores() async {
        let remote = RecoveryRemote()
        var changed = record()
        changed.sha1Hex = "different"
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: changed, descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
                validate: {})
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test func staleEpochNeverRestores() async {
        let remote = RecoveryRemote()
        var changed = record()
        changed.hashKeyEpoch = "old"
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: changed, descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
                validate: {})
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test func nilVolumeUsesOnlyTheProblemSession() async throws {
        let remote = RecoveryRemote()
        var target = record()
        target.remoteVolumeID = nil
        let context = await remote.context
        let result = try await AlbumSyncPhotoRecovery.restore(
            record: target, descriptor: descriptor(), remote: remote, expectedContext: context, validate: {})
        #expect(result == .restored)
        #expect(await remote.restored == [.init(volumeID: context.volumeID, nodeID: "trash")])
    }

    @Test func nilVolumeCannotUseAnotherSession() async {
        let remote = RecoveryRemote()
        var target = record()
        target.remoteVolumeID = nil
        let other = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "volume", hashKeyEpoch: "epoch")
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: target, descriptor: descriptor(), remote: remote, expectedContext: other, validate: {})
        }
        #expect(await remote.restored.isEmpty)
        #expect(await remote.evidenceReads == 0)
    }

    @Test func sessionChangeDuringEvidenceCannotRestore() async {
        let remote = RecoveryRemote()
        let context = await remote.context
        await remote.changeSessionAfterEvidence()
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: record(), descriptor: descriptor(), remote: remote, expectedContext: context, validate: {})
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test(arguments: [
        "missingLink", "emptyLink", "foreignVolume", "emptyNameHash", "emptyContentHash", "unknownOutcome",
    ])
    func incompleteOrForeignIdentityCannotRestore(change: String) async {
        let remote = RecoveryRemote()
        var target = record()
        switch change {
        case "missingLink": target.remoteLinkID = nil
        case "emptyLink": target.remoteLinkID = ""
        case "foreignVolume": target.remoteVolumeID = "foreign"
        case "emptyNameHash": target.nameHash = ""
        case "emptyContentHash": target.contentHash = ""
        default: target.outcome = nil
        }
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: target, descriptor: descriptor(), remote: remote, expectedContext: await remote.context,
                validate: {})
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test func failedAdmissionCannotDispatch() async {
        let remote = RecoveryRemote()
        await #expect(throws: CancellationError.self) {
            try await AlbumSyncPhotoRecovery.restore(
                record: record(), descriptor: descriptor(), remote: remote, expectedContext: await remote.context
            ) { throw CancellationError() }
        }
        #expect(await remote.restored.isEmpty)
    }

    @Test(arguments: [nil, Data(repeating: 1, count: 19)] as [Data?])
    func missingOrInvalidDigestNeverRestores(digest: Data?) async {
        let remote = RecoveryRemote()
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await AlbumSyncPhotoRecovery.restore(
                record: record(), descriptor: descriptor(digest: digest), remote: remote,
                expectedContext: await remote.context, validate: {})
        }
        #expect(await remote.evidenceReads == 0)
        #expect(await remote.restored.isEmpty)
    }

    @Test func defaultProtocolMethodsRemainUnavailable() async throws {
        let remote = DefaultRecoveryRemote()
        #expect(try await remote.photoRecoveryContext() == nil)
        #expect(try await remote.photoRecoveryState(for: record()) == .unavailable)
        let context = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "volume", hashKeyEpoch: "epoch")
        await #expect(throws: AlbumSyncPhotoRecovery.Error.unavailable) {
            try await remote.restorePhoto(.init(volumeID: "volume", nodeID: "trash"), context: context) {}
        }
    }

    private func record() -> UploadIdentityRecord {
        .init(
            source: .init(kind: .photoLibraryAsset, identifier: "asset"), filename: "photo.heic",
            correctedName: "photo.heic", fileSize: 4, modificationDate: Date(timeIntervalSince1970: 1000),
            sha1Hex: String(repeating: "01", count: 20), nameHash: "name", contentHash: "content",
            hashKeyEpoch: "epoch", remoteVolumeID: "volume", remoteLinkID: "trash",
            outcome: "duplicateTrashed", updatedAt: Date(timeIntervalSince1970: 1000))
    }

    private func descriptor(digest: Data? = Data(repeating: 1, count: 20)) -> UploadResourceDescriptor {
        .init(
            source: .init(kind: .photoLibraryAsset, identifier: "asset"),
            fileURL: URL(fileURLWithPath: "/unused"), filename: "photo.heic", fileSize: 4,
            modificationDate: Date(timeIntervalSince1970: 1000),
            precomputedSHA1Digest: digest)
    }
}

private actor RecoveryRemote: AlbumSyncRemoteAlbumOps {
    let state: AlbumSyncPhotoRecovery.RemoteState
    var restored: [PhotoUID] = []
    var evidenceReads = 0
    var context = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "volume", hashKeyEpoch: "epoch")

    private var changesSession = false
    func changeSessionAfterEvidence() { changesSession = true }
    init(state: AlbumSyncPhotoRecovery.RemoteState = .trashed) { self.state = state }
    func photoRecoveryContext() async throws -> AlbumSyncPhotoRecovery.Context? { context }
    func photoRecoveryState(for record: UploadIdentityRecord) async throws -> AlbumSyncPhotoRecovery.RemoteState {
        evidenceReads += 1
        if changesSession {
            context = .init(sessionID: UUID(), volumeID: context.volumeID, hashKeyEpoch: context.hashKeyEpoch)
        }
        return state
    }
    func restorePhoto(
        _ uid: PhotoUID, context: AlbumSyncPhotoRecovery.Context,
        validate: @Sendable () async throws -> Void
    ) async throws {
        try await validate()
        restored.append(uid)
    }
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
    func createAlbum(name: String) async throws -> String { "album" }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        .init()
    }
}

private struct DefaultRecoveryRemote: AlbumSyncRemoteAlbumOps {
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { [] }
    func createAlbum(name: String) async throws -> String { "album" }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> { [] }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult { .init() }
}
