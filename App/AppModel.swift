import AppKit
import Foundation
import MLSearchAppleAdapter
import MLSearchCore
import MediaByteCache
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveBackend

/// Root application state + composition. Owns the session lifecycle and builds the SDK-backed
/// services once the user is signed in.
@MainActor
@Observable
final class AppModel {
    private enum TeardownFailure: Error {
        case purgeClaimUnavailable
        case purgeFailed
    }

    enum AuthState: Equatable {
        case checking
        case signingOut
        case signedOut(error: String?)
        case authenticating(status: String)
        case signedIn(ProtonSession)
    }

    enum BackendState {
        case idle
        case preparing(String)
        case ready(any PhotosBackend)
        case failed(String)
    }

    private(set) var auth: AuthState = .checking
    private(set) var backend: BackendState = .idle
    /// High-level client composition (uploads + albums), built alongside the backend.
    private(set) var facade: ProtonClientFacade?
    /// macOS folder-backup composition. This type owns folder access and lifecycle; sync semantics stay in core.
    private(set) var backupController: FolderBackupController?
    private(set) var photoBackupController: PhotoLibraryBackupController?
    private(set) var albumSyncController: AlbumSyncController?
    /// Bumped after album sync creates or mutates Proton albums. Views use it only to refresh
    /// visible album lists; sync correctness lives in the shared controller.
    private(set) var albumCatalogRevision = 0
    /// Account-scoped Smart Search controller. Lifecycle decisions stay in MLSearchCore.
    private(set) var smartSearch: MLSmartSearchController?
    @ObservationIgnored private var smartSearchMemoryRegistration: MemoryPressureRegistration?
    @ObservationIgnored private let smartSearchAssets = MLAssetUniverse()
    /// The most recent ordered Smart Search shutdown; sign-out awaits it before purging.
    @ObservationIgnored private var smartSearchShutdownTask: Task<Void, Never>?
    @ObservationIgnored private let signOutBarrier = AccountSignOutBarrier()
    /// Indicates that the first signed-in library load reached a terminal state. The launch veil lifts only
    /// after the grid is ready, and this flag resets for sign-out and each new backend build.
    private(set) var libraryReady = false

    /// Controls whether the persistent launch surface shows its loading content while the app prepares the
    /// session/library. The login screen keeps that same frosted surface mounted but is not itself preparation.
    var isPreparing: Bool {
        switch auth {
        case .checking:
            return true
        case .signingOut, .signedOut, .authenticating:
            return false
        case .signedIn:
            switch backend {
            case .idle, .preparing:
                return true
            case .failed:
                return false
            case .ready:
                return facade == nil || !libraryReady
            }
        }
    }

    var hasAuthenticatedAccount: Bool {
        if case .signedIn = auth { return true }
        return false
    }

    /// Called by the main UI once the timeline has settled (loaded / empty / failed) so the launch veil fades.
    func markLibraryReady() { libraryReady = true }

    private let sessionStore: SessionKeychainStore
    private let authController: ProtonAuthController
    private var startupPurgeBlocked: Bool
    private var startupCleanupTask: Task<Void, Never>?
    private var didBootstrap = false
    private let photoBackupScheduler = MacPhotoBackupScheduler()
    private var backendTask: Task<Void, Never>?
    private var scopeRecoveryTask: Task<Void, Never>?

    init(startupPlaintextPurgeSucceeded: Bool? = nil) {
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        let store = SessionKeychainStore()
        self.sessionStore = store
        self.authController = ProtonAuthController(
            store: store,
            authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)
        )
        self.startupPurgeBlocked = true
        self.startupCleanupTask = nil
        // Wire ProtonCore's CryptoGo to the patched GopenPGP implementation before any crypto runs.
        injectDefaultCryptoImplementation()
        self.startupCleanupTask = Task { @MainActor [weak self] in
            let succeeded = await ProtonAuthLocalDataPurge.performStartupOffMain(
                claim: purgeClaim,
                plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded
            )
            guard let self else { return }
            self.startupPurgeBlocked = !succeeded
            self.startupCleanupTask = nil
            self.bootstrap()
        }
    }

    /// Restore a persisted session on launch.
    func bootstrap() {
        guard startupCleanupTask == nil else { return }
        guard !didBootstrap else { return }
        didBootstrap = true
        guard !startupPurgeBlocked else {
            auth = .signedOut(error: String(localized: "auth.sign_in_failed"))
            return
        }
        apply(authController.bootstrap(), prepareBackendOnSignedIn: true)
    }

    func signIn() {
        guard !signOutBarrier.isRunning else { return }
        guard startupCleanupTask == nil else { return }
        guard !BackupLocalDataPurge.isPurgePending() else {
            auth = .signedOut(error: String(localized: "auth.sign_in_failed"))
            return
        }
        authController.signIn(
            openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } },
            onStateChange: { [weak self] state in
                self?.apply(state, prepareBackendOnSignedIn: true)
            }
        )
    }

    func cancelSignIn() {
        guard !signOutBarrier.isRunning else { return }
        apply(authController.cancelSignIn(), prepareBackendOnSignedIn: false)
    }

    func signOut() {
        guard !signOutBarrier.isRunning else { return }
        LibraryRuntimeState.shared.beginNewGeneration()
        AccountInfo.shared.clear()
        OfflineLibraryManager.shared.prepareForAccountTeardown()
        BackupLocalDataPurge.requestPurgeOnSignOut(
            persistentDomainName: Bundle.main.bundleIdentifier
        )
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        let session = authController.currentSession
        let signedOutState = authController.signOut()
        let activeScopeRecovery = scopeRecoveryTask
        activeScopeRecovery?.cancel()
        scopeRecoveryTask = nil
        let activeFacade = facade
        let folderBackup = backupController
        let photoBackup = photoBackupController
        let albumSync = albumSyncController
        auth = .signingOut
        let backendShutdown = backendTask
        backendTask?.cancel()
        backendTask = nil
        backend = .idle
        let smartSearchShutdown = stopSmartSearch()
        backupController = nil
        photoBackupScheduler.invalidate()
        photoBackupController = nil
        albumSyncController = nil
        albumCatalogRevision = 0
        facade = nil
        libraryReady = false
        let teardownCoordinator: AccountTeardownCoordinator
        do {
            teardownCoordinator = try AccountTeardownCoordinator(owners: [
                AccountTeardownOwner(id: "mac.platform-build", stage: .platformTasks) {
                    await backendShutdown?.value
                    await activeScopeRecovery?.value
                },
                AccountTeardownOwner(id: "shared.smart-search", stage: .smartSearch) {
                    await smartSearchShutdown?.value
                },
                AccountTeardownOwner(id: "mac.location-crawl", stage: .locationCrawl) {
                    await OfflineLibraryManager.shared.stopForAccountTeardown()
                },
                AccountTeardownOwner(id: "mac.folder-backup", stage: .folderBackup) {
                    await folderBackup?.shutdown()
                },
                AccountTeardownOwner(id: "shared.photo-backup", stage: .photoBackup) {
                    await photoBackup?.shutdown()
                },
                AccountTeardownOwner(id: "shared.album-sync", stage: .albumSync) {
                    await albumSync?.shutdown()
                },
                AccountTeardownOwner(id: "shared.proton-facade", stage: .facade) {
                    await activeFacade?.shutdown()
                },
                AccountTeardownOwner(id: "mac.offline-caches", stage: .caches) {
                    await OfflineLibraryManager.shared.purgeCachesForAccountTeardown()
                },
                AccountTeardownOwner(id: "shared.debug-log", stage: .logs) {
                    await DebugLog.flush()
                },
                AccountTeardownOwner(id: "mac.account-directory", stage: .purgeClaims) {
                    guard let session else { return }
                    let uid = session.uid
                    await Task.detached(priority: .utility) {
                        ProtonDriveBackendFactory.purgeLocalAccountData(
                            uid: uid,
                            policy: .standard(
                                libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
                        )
                    }.value
                },
                AccountTeardownOwner(id: "shared.local-data-claim", stage: .purgeClaims) {
                    guard let purgeClaim else { throw TeardownFailure.purgeClaimUnavailable }
                    let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: purgeClaim)
                    guard succeeded else { throw TeardownFailure.purgeFailed }
                },
            ])
        } catch {
            apply(signedOutState, prepareBackendOnSignedIn: false)
            NSApp.terminate(nil)
            return
        }

        signOutBarrier.begin { [self] in
            let report = await teardownCoordinator.teardown()
            apply(signedOutState, prepareBackendOnSignedIn: false)
            if !report.succeeded {
                NSApp.terminate(nil)
            }
        }
    }

    func retryBackend() {
        guard scopeRecoveryTask == nil else { return }
        if case .signedIn(let session) = auth { prepareBackend(session) }
    }

    /// A terminal Drive scope event invalidates every local projection for that volume. Keep authentication,
    /// but retire all account owners before deleting the SDK, metadata, media, and location caches and rebuilding.
    func recoverBackendAfterScopeAccessLoss() async {
        guard scopeRecoveryTask == nil,
            case .signedIn(let session) = auth
        else { return }

        let activeBackendTask = backendTask
        let activeFacade = facade
        let folderBackup = backupController
        let photoBackup = photoBackupController
        let albumSync = albumSyncController
        let smartSearchShutdown = stopSmartSearch()
        let policy = ProtonDriveBackendPolicy.standard(
            libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy
        )

        LibraryRuntimeState.shared.beginNewGeneration()
        OfflineLibraryManager.shared.prepareForAccountTeardown()
        activeBackendTask?.cancel()
        backendTask = nil
        backend = .preparing(String(localized: "loading.building_library"))
        backupController = nil
        photoBackupScheduler.invalidate()
        photoBackupController = nil
        albumSyncController = nil
        albumCatalogRevision = 0
        facade = nil
        libraryReady = false

        let coordinator: AccountTeardownCoordinator
        do {
            coordinator = try AccountTeardownCoordinator(owners: [
                AccountTeardownOwner(id: "mac.scope-recovery.platform", stage: .platformTasks) {
                    await activeBackendTask?.value
                    await OfflineLibraryManager.shared.stopForAccountTeardown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.smart-search", stage: .smartSearch) {
                    await smartSearchShutdown?.value
                },
                AccountTeardownOwner(id: "mac.scope-recovery.folder-backup", stage: .folderBackup) {
                    await folderBackup?.shutdown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.photo-backup", stage: .photoBackup) {
                    await photoBackup?.shutdown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.album-sync", stage: .albumSync) {
                    await albumSync?.shutdown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.facade", stage: .facade) {
                    await activeFacade?.shutdown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.caches", stage: .caches) {
                    await OfflineLibraryManager.shared.purgeCachesForAccountTeardown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.logs", stage: .logs) {
                    await DebugLog.flush()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.account-data", stage: .purgeClaims) {
                    await Task.detached(priority: .utility) {
                        ProtonDriveBackendFactory.purgeLocalAccountData(uid: session.uid, policy: policy)
                    }.value
                },
            ])
        } catch {
            preconditionFailure("Duplicate scope recovery owner identifier")
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.scopeRecoveryTask = nil }
            let report = await coordinator.teardown()
            guard report.succeeded else {
                DebugLog.log("scope recovery: ordered teardown or purge failed")
                self.backend = .failed(String(localized: "error.library_open_failed"))
                return
            }
            guard !Task.isCancelled,
                case .signedIn(let currentSession) = self.auth,
                currentSession == session
            else { return }
            self.prepareBackend(session)
        }
        scopeRecoveryTask = task
        await task.value
    }

    /// Stop Smart Search and return the ordered-shutdown task. Consecutive stops chain, so a
    /// later awaiter always sees every previous lifecycle fully torn down.
    @discardableResult
    private func stopSmartSearch() -> Task<Void, Never>? {
        let lifecycle = smartSearch?.lifecycleActor
        smartSearch = nil
        smartSearchAssets.beginHydration()
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = nil
        guard let lifecycle else { return smartSearchShutdownTask }
        let previous = smartSearchShutdownTask
        let task = Task {
            await previous?.value
            await lifecycle.shutdown()
        }
        smartSearchShutdownTask = task
        return task
    }

    /// Creates the account-scoped Smart Search lifecycle after the feed and timeline are available.
    /// Lifecycle decisions remain in the shared Core actor.
    func configureSmartSearch(
        feedCore: ThumbnailFeedCore,
        assetUIDs: [PhotoUID]
    ) {
        guard AppleSmartSearchBootstrap.featureAvailability() == .available,
            smartSearch == nil,
            let session = authController.currentSession,
            let facade
        else { return }
        smartSearchAssets.publishAuthoritative(assetUIDs)
        #if DEBUG
            let allowsDeveloperModels = true
        #else
            let allowsDeveloperModels = false
        #endif
        #if DEBUG
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.debugEndpoint(
                environment: ProcessInfo.processInfo.environment
            )
        #else
            let catalogEndpoint = AppleSmartSearchCatalogEndpoint.production
        #endif
        let lifecycle = AppleSmartSearchBootstrap.makeLifecycle(
            accountDirectory: facade.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feedCore,
            assetsProvider: { [smartSearchAssets] in smartSearchAssets.snapshot() },
            allowsDeveloperModels: allowsDeveloperModels,
            databasePolicy: facade.accountDatabasePolicy,
            catalogEndpoint: catalogEndpoint
        )
        smartSearch = MLSmartSearchController(lifecycle: lifecycle)
        // Under memory pressure the search stack drops cached vector blocks and unloads the
        // CoreML model; both rebuild on demand.
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = MemoryPressureGovernor.shared.register { tier in
            guard tier.requiresImmediatePurge else { return }
            Task { await lifecycle.releaseMemory() }
        }
    }

    func updateSmartSearchAssets(_ uids: [PhotoUID]) {
        guard smartSearchAssets.publishAuthoritative(uids) else { return }
        smartSearch?.noteLibraryChanged()
    }

    private func prepareBackend(_ session: ProtonSession) {
        LibraryRuntimeState.shared.beginNewGeneration()
        backendTask?.cancel()
        libraryReady = false
        stopSmartSearch()
        // Install the per-account encrypted-cache key derived from the restored session before the grid
        // renders or the crawl begins.
        OfflineLibraryManager.shared.configure(session: session)
        backend = .preparing(String(localized: "loading.building_library"))
        backendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: sessionStore,
                    policy: .standard(libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
                )
                guard !Task.isCancelled else {
                    await client.shutdown()
                    return
                }
                facade = client
                backupController = FolderBackupController(facade: client)
                let photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader
                )
                photoBackupController = photoBackup
                photoBackupScheduler.configure(controller: photoBackup)
                let albumSync = AlbumSyncController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    remoteOps: client.albumSyncRemoteOps
                )
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    self?.albumCatalogRevision &+= 1
                }
                albumSyncController = albumSync
                await client.uploadCoordinator.start()
                backend = .ready(client.backend)
                // Register account caches after construction so pressure events can manage their budgets.
                AppMemoryPressureCoordinator.shared.install()
            } catch is CancellationError {
                // ignore
            } catch {
                DebugLog.log("backend prepare FAILED: \(error)")
                backend = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func apply(_ state: ProtonAuthState, prepareBackendOnSignedIn: Bool) {
        switch state {
        case .checking:
            auth = .checking
        case .signedOut(let error):
            auth = .signedOut(error: error)
        case .authenticating(let progress):
            auth = .authenticating(status: ProtonAuthProgressPresentation.status(for: progress))
        case .signedIn(let session):
            auth = .signedIn(session)
            if prepareBackendOnSignedIn {
                prepareBackend(session)
            }
        }
    }
}
