import AlbumSyncCore
import Foundation
import PhotosCore
import UploadCore

/// One account's backup stack, built the same way on macOS, iOS and iPadOS: the device-local pending store, the
/// photo backup that refuses to run without it, and album sync. The account host keeps ownership, adds its own parts
/// (the Mac's watched folders, the iOS thumbnail feed) and keeps its teardown order.
@MainActor
public struct AccountBackupStack {
    /// Nil when the store cannot open; the photo backup then reports itself unavailable, because a deleted pending
    /// photo could otherwise upload.
    public let pendingStore: PendingBackupManifestStore?
    public let photoBackup: PhotoLibraryBackupController
    public let albumSync: AlbumSyncController

    public init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)?,
        editReplacement: EditedPhotoReplacement?,
        albumOperations: any AlbumSyncRemoteAlbumOps
    ) {
        let pendingStore = PendingGridSession.openStore(
            accountDataDirectory: accountDataDirectory, policy: databasePolicy)
        self.pendingStore = pendingStore
        photoBackup = PhotoLibraryBackupController(
            configuration: .init(accountDataDirectory: accountDataDirectory, databasePolicy: databasePolicy),
            identityResolver: identityResolver,
            uploader: uploader,
            tagAdder: tagAdder,
            editReplacement: editReplacement,
            pendingStore: pendingStore,
            requiresPendingStore: true
        )
        albumSync = AlbumSyncController(
            configuration: .init(accountDataDirectory: accountDataDirectory, databasePolicy: databasePolicy),
            identityResolver: identityResolver,
            uploader: uploader,
            remoteOps: albumOperations
        )
    }

    /// Closes a stack that never reached the account, for example after a cancelled or superseded load: the photo
    /// backup first, then the pending store it used, then album sync.
    public func shutdownUnused() async {
        await photoBackup.shutdown()
        pendingStore?.close()
        await albumSync.shutdown()
    }
}
