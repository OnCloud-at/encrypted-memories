import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import Testing
import UploadCore

@testable import EncryptedMemoriesMobile

/// An upload backend that never finishes a call: each one throws `CancellationError`.
struct StalledUploadBackend: PhotoUploading, UploadIdentityResolving {
    let capabilities: UploadBackendCapabilities

    init(canUpload: Bool) {
        capabilities = UploadBackendCapabilities(
            canUpload: canUpload, supportsCancel: true, supportsPauseResume: false,
            supportsResumeAcrossRelaunch: false)
    }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        throw CancellationError()
    }
    func upload(
        _ request: PhotoUploadRequest, onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> PhotoUID { throw CancellationError() }
    func cancel(token: UUID) async {}
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw CancellationError()
    }
    func recordUploaded(
        _ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String,
        remoteLinkID: String
    ) async throws { throw CancellationError() }
}

/// Remote effects that all succeed at once.
struct SettledPendingRemote: PendingRemoteEffects {
    func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

/// A pending-photo store, a backup controller and the pending grid session of a library model, in a temporary
/// directory that `close()` removes.
@MainActor struct MobilePendingOwnerFixture {
    private let suite = "mobile-pending-owner-" + UUID().uuidString
    private let directory: URL
    private let defaults: UserDefaults
    let store: PendingBackupManifestStore
    private let controller: PhotoLibraryBackupController
    let session: PendingGridSession

    /// `prepare` runs on the controller before the model installs it.
    init(
        model: MobileLibraryModel, canUpload: Bool = false, remote: any PendingRemoteEffects = SettledPendingRemote(),
        prepare: (PhotoLibraryBackupController) -> Void = { _ in }
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        store = try #require(PendingGridSession.openStore(accountDataDirectory: directory, policy: .conservative))
        let backend = StalledUploadBackend(canUpload: canUpload)
        controller = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
            identityResolver: backend, uploader: backend, pendingStore: store, requiresPendingStore: true)
        prepare(controller)
        model.installIsolatedPendingBackupForTesting(controller, store: store, remote: remote)
        session = try #require(model.pendingGrid)
    }

    func close() async {
        await session.close()
        await controller.shutdown()
        store.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
