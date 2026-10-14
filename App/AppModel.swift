import AppKit
import Foundation
import LibrarySourceRuntime
import MLSearchAppleAdapter
import MLSearchBackgroundAppleAdapter
import MLSearchCore
import MLSearchFeature
import MapFeature
import MediaByteCache
import MediaFeedCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import ProtonDriveBackend
import TimelineCore
import UploadCore

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
        case signOutFailed
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

    /// Native Settings navigation; no persisted preference or account behavior.
    var selectedSettingsTab: MacSettingsTabs.Tab.ID = .account

    private(set) var auth: AuthState = .checking
    private(set) var backend: BackendState = .idle
    /// High-level client composition (uploads + albums), built alongside the backend.
    private(set) var facade: ProtonClientFacade? {
        didSet {
            guard facade !== oldValue else { return }
            duplicatesLifetime.retire()
            // The Duplicates screen scans only when it opens, and a library window may not be open. A merge that the
            // end of the app left open is checked now; a new account or a sign-out ends the check of the earlier one.
            duplicatesLifetime.checkPendingMerges(of: facade?.exactDuplicates)
        }
    }
    @ObservationIgnored private let duplicatesLifetime = ExactDuplicatesAccountLifetime()
    /// macOS folder-backup composition. This type owns folder access and lifecycle; sync semantics stay in core.
    private(set) var backupController: FolderBackupController?
    private(set) var photoBackupController: PhotoLibraryBackupController?
    /// The pending grid of this account and its lists, shared with iOS. `PendingGridConnection` describes each one.
    @ObservationIgnored private let pendingGridConnection = PendingGridConnection()
    var pendingGrid: PendingGridSession? { pendingGridConnection.session }
    var pendingTrash: PendingTrashPresentation { pendingGridConnection.trash }
    var excludedPendingTiles: [PendingTile] { pendingGridConnection.excludedTiles }
    var pendingFavoriteRevision: UInt64 { pendingGridConnection.favoriteRevision }
    private(set) var albumSyncController: AlbumSyncController?
    /// Bumped after album sync creates or mutates Proton albums. Views use it only to refresh
    /// visible album lists; sync correctness lives in the shared controller.
    private(set) var albumCatalogRevision = 0
    /// Wakes analysis-only presentation after a source inventory becomes readable.
    private(set) var sourceAnalysisRevision: UInt64 = 0
    /// Account-scoped Smart Search session. Lifecycle decisions stay in MLSearchCore.
    @ObservationIgnored private let smartSearchSession = AppleSmartSearchSession(
        backgroundHost: AppleSmartSearchBackgroundCoordinator.shared
    )
    var smartSearch: MLSmartSearchController? { smartSearchSession.controller }
    let searchSuggestions = SmartSearchDiscoveryScheduler { latitude, longitude in
        await NativePlaceNameResolver.shared.cityName(latitude: latitude, longitude: longitude)
    }
    private var smartSearchAssets: MLAssetUniverse { smartSearchSession.assets }
    @ObservationIgnored private let sourceAnalysis = LibrarySourceAnalysisSession()
    @ObservationIgnored private var onPrimaryInventoryFailure: (@MainActor () -> Void)?
    @ObservationIgnored private let signOutBarrier = AccountSignOutBarrier()
    /// Retains the idempotent purge after a failure. The durable marker independently recreates this claim
    /// after process termination, before session bootstrap opens any account-owned store.
    @ObservationIgnored private var pendingSignOutPurgeClaim: BackupLocalDataPurge.Claim?
    /// Indicates that the first signed-in library load reached a terminal state. The launch veil lifts only
    /// after the grid is ready, and this flag resets for sign-out and each new backend build.
    private(set) var libraryReady = false

    /// Controls whether the persistent launch surface shows its loading content while the app prepares the
    /// session/library. The login screen keeps that same frosted surface mounted but is not itself preparation.
    var isPreparing: Bool {
        switch auth {
        case .checking:
            return true
        case .signingOut, .signOutFailed, .signedOut, .authenticating:
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
    /// The startup and sign-in guard shared with iOS: no session starts before the sign-out purge and cleanup ended.
    private let startupCleanup = ProtonAuthStartupCleanup()
    private var didBootstrap = false
    private let webAuthenticationSession = ManagedWebAuthenticationSession()
    private let webAuthenticationPresentationContext = ManagedWebAuthenticationPresentationContext {
        guard
            let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            preconditionFailure("Web authentication requires a visible application window")
        }
        return window
    }
    private let photoBackupScheduler = MacPhotoBackupScheduler()
    private var backendTask: Task<Void, Never>?
    /// One retry of the backend at a time; the failed preparation ends before the next one starts.
    @ObservationIgnored private let backendRetry = BackendRetrySequence()
    private var scopeRecoveryTask: Task<Void, Never>?

    init(startupPlaintextPurgeSucceeded: Bool? = nil) {
        let store = SessionKeychainStore()
        self.sessionStore = store
        self.authController = ProtonAuthController(
            store: store,
            authenticator: ProtonForkAuthenticator(config: .externalDriveEncryptedMemories)
        )
        // Wire ProtonCore's CryptoGo to the patched GopenPGP implementation before any crypto runs.
        injectDefaultCryptoImplementation()
        beginStartupCleanup(plaintextPurgeSucceeded: startupPlaintextPurgeSucceeded)
    }

    private func beginStartupCleanup(plaintextPurgeSucceeded: Bool? = nil, signInAfterCleanup: Bool = false) {
        guard !startupCleanup.isRunning else { return }
        auth = .checking
        startupCleanup.begin(plaintextPurgeSucceeded: plaintextPurgeSucceeded) { [weak self] succeeded in
            guard let self else { return }
            if succeeded, signInAfterCleanup {
                self.signIn()
            } else {
                self.didBootstrap = false
                self.bootstrap()
            }
        }
    }

    /// Restore a persisted session on launch.
    func bootstrap() {
        guard !startupCleanup.isRunning else { return }
        guard !didBootstrap else { return }
        didBootstrap = true
        guard startupCleanup.succeeded else {
            auth = .signedOut(error: L10n.string("auth.sign_in_failed"))
            return
        }
        apply(authController.bootstrap(), prepareBackendOnSignedIn: true)
    }

    func signIn() {
        guard !signOutBarrier.isRunning else { return }
        switch startupCleanup.admitSignIn() {
        case .waitForCleanup:
            return
        case .cleanUpFirst:
            beginStartupCleanup(signInAfterCleanup: true)
            return
        case .proceed:
            break
        }
        authController.signIn(
            openURL: { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.startWebAuthenticationSession(url: url)
                }
            },
            onStateChange: { [weak self] state in
                self?.apply(state, prepareBackendOnSignedIn: true)
            }
        )
    }

    func cancelSignIn() {
        guard !signOutBarrier.isRunning else { return }
        webAuthenticationSession.cancel()
        apply(authController.cancelSignIn(), prepareBackendOnSignedIn: false)
    }

    private func startWebAuthenticationSession(url: URL) {
        webAuthenticationSession.start(
            url: url,
            presentationContextProvider: webAuthenticationPresentationContext
        ) { [weak self] in
            guard let self, case .authenticating = self.auth else { return }
            self.apply(self.authController.cancelSignIn(), prepareBackendOnSignedIn: false)
        }
    }

    func signOut() {
        guard !signOutBarrier.isRunning else { return }
        LibraryRuntimeState.shared.beginNewGeneration()
        AccountInfo.shared.clear()
        OfflineLibraryManager.shared.prepareForAccountTeardown()
        ProtonAuthStartupCleanup.armPurgeForSignOut()
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        pendingSignOutPurgeClaim = purgeClaim
        let signedOutState = authController.signOut()
        let activeScopeRecovery = scopeRecoveryTask
        activeScopeRecovery?.cancel()
        scopeRecoveryTask = nil
        let activeFacade = facade
        let folderBackup = backupController
        let photoBackup = photoBackupController
        let activePendingGrid = pendingGridConnection.retire()
        let albumSync = albumSyncController
        auth = .signingOut
        let backendShutdown = backendTask
        backendTask?.cancel()
        backendTask = nil
        backend = .idle
        searchSuggestions.reset()
        let smartSearchShutdown = smartSearchSession.stop()
        let sourceAnalysisShutdown = stopSourceAnalysis()
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
                    await sourceAnalysisShutdown?.value
                },
                AccountTeardownOwner(id: "mac.location-crawl", stage: .locationCrawl) {
                    await OfflineLibraryManager.shared.stopForAccountTeardown()
                },
                AccountTeardownOwner(id: "mac.folder-backup", stage: .folderBackup) {
                    await folderBackup?.shutdown()
                },
                AccountTeardownOwner(id: "shared.photo-backup", stage: .photoBackup) {
                    await activePendingGrid.session?.close()
                    await photoBackup?.shutdown()
                    // The purge deletes the account directory; the pending store must be closed first.
                    activePendingGrid.store?.close()
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
                AccountTeardownOwner(id: "shared.local-data-claim", stage: .purgeClaims) {
                    guard let purgeClaim else { throw TeardownFailure.purgeClaimUnavailable }
                    PendingReplacementLedger.clearForSignOut()
                    let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: purgeClaim)
                    guard succeeded else { throw TeardownFailure.purgeFailed }
                },
            ])
        } catch {
            preconditionFailure("Duplicate account teardown owner identifier")
        }

        signOutBarrier.begin { [self] in
            let report = await teardownCoordinator.teardown()
            if report.succeeded {
                pendingSignOutPurgeClaim = nil
                apply(signedOutState, prepareBackendOnSignedIn: false)
            } else {
                auth = .signOutFailed
            }
        }
    }

    /// Retries only the purge after every account owner has already shut down. Failure keeps the marker armed.
    func retrySignOutCleanup() {
        guard case .signOutFailed = auth,
            let claim = pendingSignOutPurgeClaim,
            !signOutBarrier.isRunning
        else { return }

        auth = .signingOut
        signOutBarrier.begin { [self] in
            let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: claim)
            if succeeded {
                pendingSignOutPurgeClaim = nil
                apply(.signedOut(error: nil), prepareBackendOnSignedIn: false)
            } else {
                auth = .signOutFailed
            }
        }
    }

    /// Retries a failed preparation. A failed preparation leaves no facade: `prepareBackend` assigns one only after
    /// `makeFacade` succeeded, and a failed scope recovery shut its facade down first. So two backends never work on
    /// the account's files, a retry starts only without a facade, and only after the failed preparation ended.
    func retryBackend() {
        guard scopeRecoveryTask == nil, facade == nil, case .failed = backend,
            case .signedIn(let session) = auth
        else { return }
        let failed = backendTask
        Task {
            await backendRetry.run(
                retire: { [weak self] in
                    // A sign-out must still find a preparation that replaced the failed one meanwhile.
                    if self?.backendTask == failed { self?.backendTask = nil }
                    await failed?.value
                },
                start: { [weak self] in
                    guard let self, self.scopeRecoveryTask == nil, self.facade == nil,
                        case .signedIn(let current) = self.auth, current == session
                    else { return }
                    self.prepareBackend(session)
                })
        }
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
        let activePendingGrid = pendingGridConnection.retire()
        let albumSync = albumSyncController
        searchSuggestions.reset()
        let smartSearchShutdown = smartSearchSession.stop()
        let sourceAnalysisShutdown = stopSourceAnalysis()
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
                    await sourceAnalysisShutdown?.value
                },
                AccountTeardownOwner(id: "mac.scope-recovery.folder-backup", stage: .folderBackup) {
                    await folderBackup?.shutdown()
                },
                AccountTeardownOwner(id: "mac.scope-recovery.photo-backup", stage: .photoBackup) {
                    await activePendingGrid.session?.close()
                    await photoBackup?.shutdown()
                    activePendingGrid.store?.close()
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

    @discardableResult
    private func stopSourceAnalysis() -> Task<Void, Never>? {
        smartSearchAssets.invalidateSourceSession()
        onPrimaryInventoryFailure = nil
        return sourceAnalysis.stop()
    }

    /// Creates the account-scoped Smart Search lifecycle after the feed and timeline are available.
    /// Lifecycle decisions remain in the shared Core actor.
    func configureSmartSearch(
        feedCore: ThumbnailFeedCore,
        primaryItems: [PhotoItem],
        primaryAuthority: SourceInventoryAuthority,
        onPrimaryInventoryFailure: @escaping @MainActor () -> Void
    ) {
        guard let session = authController.currentSession, let facade else { return }
        self.onPrimaryInventoryFailure = onPrimaryInventoryFailure
        if sourceAnalysis.runtime == nil {
            sourceAnalysis.install(
                LibrarySourceAnalysisRuntime(
                    coordinator: facade.librarySources,
                    feed: feedCore,
                    assets: smartSearchAssets,
                    onAssetsChanged: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.sourceAnalysisRevision &+= 1
                            self.smartSearch?.noteLibraryChanged()
                        }
                    }
                ))
            sourceAnalysis.startPrimaryInventory(
                primaryItems,
                authority: primaryAuthority,
                onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
            )
        } else {
            sourceAnalysis.replacePrimaryInventory(
                primaryItems,
                authority: primaryAuthority,
                onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
            )
        }

        // macOS configures once per MainView life; the session keeps the first lifecycle.
        guard smartSearchSession.controller == nil else { return }
        smartSearchSession.configure(
            accountDirectory: facade.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feedCore,
            databasePolicy: facade.accountDatabasePolicy
        )
    }

    func updateSmartSearchAssets(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) {
        sourceAnalysis.replacePrimaryInventory(
            items,
            authority: authority,
            onFailure: { [weak self] in self?.onPrimaryInventoryFailure?() }
        )
    }

    func refreshLibrarySources() {
        guard let runtime = sourceAnalysis.runtime else { return }
        Task { await runtime.refresh() }
    }

    func makeDuplicatesModel(
        for facade: ProtonClientFacade,
        didTrash: @escaping @MainActor ([PhotoUID], ExactDuplicatesAccountLifetime.Token) async -> Void
    ) -> ExactDuplicatesModel? {
        guard self.facade === facade, case .ready = backend else { return nil }
        return duplicatesLifetime.replace(with: facade.exactDuplicates, didTrash: didTrash)
    }

    func isCurrentDuplicatesAccount(_ token: ExactDuplicatesAccountLifetime.Token) -> Bool {
        duplicatesLifetime.isCurrent(token)
    }

    private func prepareBackend(_ session: ProtonSession) {
        duplicatesLifetime.retire()
        LibraryRuntimeState.shared.beginNewGeneration()
        backendTask?.cancel()
        libraryReady = false
        searchSuggestions.reset()
        smartSearchSession.stop()
        stopSourceAnalysis()
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
                let pendingStore = PendingGridSession.openStore(
                    accountDataDirectory: client.accountDataDirectory,
                    policy: client.accountDatabasePolicy
                )
                let photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    tagAdder: client.photoTagAdder,
                    editReplacement: client.editedPhotoReplacement,
                    pendingStore: pendingStore,
                    requiresPendingStore: true
                )
                photoBackupController = photoBackup
                photoBackupScheduler.configure(controller: photoBackup)
                // Watched folders share the pending store and the photo backup's event stream.
                let folderBackup = FolderBackupController(
                    facade: client, pendingStore: pendingStore, pendingRecorder: photoBackup.pendingRecorder,
                    requiresPendingStore: true)
                backupController = folderBackup
                configurePendingGrid(
                    store: pendingStore, photoBackup: photoBackup, folderBackup: folderBackup, client: client)
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
                guard !Task.isCancelled, facade === client, authController.currentSession == session else { return }
                backend = .ready(client.backend)
                // Register account caches after construction so pressure events can manage their budgets.
                AppMemoryPressureCoordinator.shared.install()
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled, authController.currentSession == session else { return }
                DebugLog.log("backend prepare FAILED: \(error)")
                backend = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Pending grid

    private func configurePendingGrid(
        store: PendingBackupManifestStore?,
        photoBackup: PhotoLibraryBackupController,
        folderBackup: FolderBackupController,
        client: ProtonClientFacade
    ) {
        let albums = client.albums
        pendingGridConnection.start(
            store: store,
            makeSession: { store in
                PendingGridSession(
                    store: store,
                    photoBackup: photoBackup,
                    remote: ProtonPendingRemoteEffects(facade: client),
                    files: folderBackup.pendingFileSource
                )
            },
            albumAdds: { await albums.setPendingAlbumAdds($0) }
        )
    }

    private func apply(_ state: ProtonAuthState, prepareBackendOnSignedIn: Bool) {
        webAuthenticationSession.follow(state)
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
