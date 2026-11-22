import Foundation
import PhotosCore
import ProtonAuth
import UploadCore

public typealias PhotosBackend = PhotosRepository
    & ThumbnailProvider
    & ThumbnailBatchLoader
    & FullMediaProvider
    & OriginalByteStreamProvider
    & OriginalFileProvider
    & VideoStreamProvider
    & PhotoMetadataProvider
    & BurstGroupProvider
    & PhotoLibraryProvider
    & FavoritesProvider
    & PhotoLibrarySaving
    & TrashProvider

/// The video-block cache budget is not part of this policy. `DiskCacheBudgetPolicy.videoBudget` is the
/// single source, and `VideoByteRangeCache` applies it.
public struct ProtonDriveBackendPolicy: Sendable, Equatable {
    public let sdkCacheDirectory: URL
    public let libraryDatabaseBaseDirectory: URL
    public let libraryDatabasePolicy: LibraryDatabasePolicy

    public init(
        sdkCacheDirectory: URL,
        libraryDatabaseBaseDirectory: URL = LibraryDatabaseLocation.defaultBaseDirectory(),
        libraryDatabasePolicy: LibraryDatabasePolicy = .conservative
    ) {
        self.sdkCacheDirectory = sdkCacheDirectory
        self.libraryDatabaseBaseDirectory = libraryDatabaseBaseDirectory
        self.libraryDatabasePolicy = libraryDatabasePolicy
    }

    public static func standard(
        libraryDatabasePolicy: LibraryDatabasePolicy = .conservative
    ) -> Self {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return Self(
            sdkCacheDirectory: caches.appendingPathComponent("EncryptedMemories/sdk", isDirectory: true),
            libraryDatabasePolicy: libraryDatabasePolicy
        )
    }

    public static let desktopLibraryDatabasePolicy = LibraryDatabasePolicy(
        mmapBytes: 268_435_456,
        cacheSizeKiB: 8_192,
        busyTimeoutMs: 3_000,
        journalSizeLimitBytes: 16 * 1024 * 1024,
        walCheckpointRowThreshold: 10_000
    )

    public static let mobileLibraryDatabasePolicy = LibraryDatabasePolicy(
        mmapBytes: 0,
        cacheSizeKiB: 2_048,
        busyTimeoutMs: 3_000,
        journalSizeLimitBytes: 8 * 1024 * 1024,
        walCheckpointRowThreshold: 5_000
    )
}

public enum ProtonDriveBackendFactory {
    public static func makeFacade(
        session: ProtonSession,
        store: SessionKeychainStore,
        policy: ProtonDriveBackendPolicy
    ) async throws -> ProtonClientFacade {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return try await ProtonClientFacade.makeUpgradeTestFacade(
                    accountUID: session.uid, keyPassword: session.keyPassword, policy: policy)
            }
        #endif
        let bridge = try await DriveSDKBridge(session: session, store: store, policy: policy)
        await bridge.startTrashedSeriesRestoreReplay()
        let accountDataDirectory = bridge.uploadManifestURL.deletingLastPathComponent()
        let sourceInventoryStore = LibrarySourceInventoryStore(
            directory: accountDataDirectory,
            accountUID: session.uid,
            encryptionKey: LibrarySourceInventoryKeyDerivation.key(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            ),
            policy: policy.libraryDatabasePolicy
        )
        let librarySources = LibrarySourceCoordinator(
            remote: bridge.makeAlbumCatalogBackend(),
            thumbnailLoader: bridge,
            inventoryStore: sourceInventoryStore
        )
        await librarySources.prepare()
        // Before any consumer binds: the first cache sweep keeps the thumbnails of the photos in Recently Deleted.
        let recentlyDeleted = await bridge.recentlyDeletedReport()
        await librarySources.setIdentitiesOutsideInventory(recentlyDeleted.uids, sequence: recentlyDeleted.sequence)
        SDKCapabilities.current.log()
        // Opening account-scoped SQLite stores is synchronous. Prepare them on a utility executor before the
        // facade's MainActor composition so account activation does not block the UI executor on disk I/O.
        let preparedStores = await Task.detached(priority: .utility) {
            let identityComposition = bridge.makeUploadIdentityResolver()
            let settlementStore = UploadManualSettlementStore(
                url: bridge.uploadManifestURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(UploadManualSettlementStore.databaseFileName),
                policy: bridge.uploadManifestPolicy
            )
            return (identityComposition, settlementStore)
        }.value
        return await MainActor.run {
            ProtonClientFacade.make(
                bridge: bridge,
                librarySources: librarySources,
                identityComposition: preparedStores.0,
                settlementStore: preparedStores.1
            )
        }
    }

    public static func purgeLocalAccountData(uid: String, policy: ProtonDriveBackendPolicy) {
        AccountDataCache.clear(uid: uid, in: policy.sdkCacheDirectory)
        // The next account prewarms map tiles only after it opened the Map itself.
        UserDefaults.standard.removeObject(forKey: AppSettingsKey.libraryMapViewportSize)
        DriveSDKBridge.purgeMetadata(uid: uid, policy: policy)
        VideoByteRangeCache.shared.clearAll()
    }
}

/// What the library-open screen shows for a failure: the text under its title, empty when the screen has none, and
/// whether another attempt can help.
///
/// Only a cause that is proven fixed hides Try again: a session that Proton rejected (the person signs in again) and
/// a drive scope that is terminally lost (its own recovery runs). Every other cause keeps it: a network failure, a
/// rate limit, an unclear answer, a library that does not exist yet and may appear later. The text is the app's own
/// sentence where one exists; Proton is named only for the rejected session.
public struct LibraryOpenFailurePresentation: Equatable, Sendable {
    public let message: String
    public let isRetryable: Bool

    public init(for error: any Error) {
        if ProtonFailureClassifier.isUnauthorized(error) {
            message = LibraryLoadFailureMessage.rejectedSession
            isRetryable = false
        } else if error is any LibraryChangeTerminalError {
            message = ""
            isRetryable = false
        } else {
            message = LibraryLoadFailureMessage.message(for: error)
            isRetryable = true
        }
    }
}
