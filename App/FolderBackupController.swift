import Foundation
import Observation
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonDriveBackend
import UploadCore

/// macOS composition of the shared backup sync stack. This type owns security-scoped folder access
/// and lifecycle; UploadCore owns synchronization and recovery.
@MainActor
@Observable
final class FolderBackupController {
    /// The folders the user chose to keep backed up, each persisted as a security-scoped bookmark so the sandboxed app
    /// can reach it across launches. The core decides the list from the bookmark resolutions of this host.
    private(set) var registry = WatchedFolderRegistry(savedBookmarks: nil, resolve: { _ in .unresolved })
    var folders: [WatchedFolder] { registry.folders }
    /// The user-facing state surface shared by both platform settings views. Raw runner progress stays internal.
    private(set) var status = BackupStatus()
    private(set) var isSyncing = false
    private(set) var lastMessage: String?

    /// False when the account's dedupe manifest or sync stores could not open - backup is then
    /// disabled entirely instead of running without duplicate protection. The pending store is required too:
    /// without it, a file deleted before upload could upload after all.
    var isAvailable: Bool {
        runner != nil && (!requiresPendingStore || pendingStore?.isOperational() == true)
    }

    /// Watched folders the pending grid and the backup may read; kept accessible while they are registered.
    let pendingAccess: PendingFolderAccess
    @ObservationIgnored private let pendingStore: PendingBackupManifestStore?
    @ObservationIgnored private let requiresPendingStore: Bool
    @ObservationIgnored private var accessedFolders: [WatchedFolder.ID: URL] = [:]

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let statusProjector: BackupStatusProjector?
    private let statusProjectionGeneration = UUID()
    private var statusProjectionRevision: UInt64 = 0
    private var lastAppliedStatusProjectionRevision: UInt64 = 0
    private var statusSetupTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var runnerStopTask: Task<Void, Never>?
    private var runnerStopRunID: UUID?
    private var isShuttingDown = false
    private var isScanning = false
    /// A scan failure is not a queue item. Keep it as run-local state so a drained prefix cannot
    /// be presented as a complete backup, without polluting the durable queue with a fake row.
    private var hasFolderEnumerationFailure = false
    /// The skipped-file count of the run that scans now, and the count of the last finished scan, which the status
    /// shows. A file with a type that the app does not back up never enters the queue.
    private var scanSkippedFiles: FolderBackupSkippedFiles?
    private var skippedCount = FolderBackupSkippedCount()

    private static let foldersDefaultsKey = "backup.folderBookmarks.v1"
    /// The paths of the folders, beside the bookmark list that older versions read unchanged (#1583).
    private static let pathsDefaultsKey = "backup.folderPaths.v1"

    /// `pendingRecorder` is the photo backup's recorder, so one event stream serves the pending grid.
    init(
        facade: ProtonClientFacade,
        pendingStore: PendingBackupManifestStore? = nil,
        pendingRecorder: PendingBackupEventRecorder? = nil,
        requiresPendingStore: Bool = false
    ) {
        self.pendingStore = pendingStore
        self.requiresPendingStore = requiresPendingStore
        let pendingAccess = PendingFolderAccess()
        self.pendingAccess = pendingAccess
        let directory = facade.accountDataDirectory
        let policy = facade.accountDatabasePolicy
        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName),
            policy: policy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName),
            policy: policy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore
        // A file in a folder that the app cannot reach now waits instead of counting as deleted, and its row sets no
        // time in the status.
        let resolver = FileBackupResourceResolver(scope: { pendingAccess.scope })
        statusProjector = queueStore.map {
            BackupStatusProjector(queue: $0, fileClaimFilter: { resolver.fileClaimFilter() })
        }

        // The shared dedupe pipeline prevents each sync pass from re-uploading existing files.
        if let queueStore, let stateStore, let identityResolver = facade.uploadIdentityResolver {
            let preflight = UploadBackupPreflightIndex(store: stateStore)
            engine = UploadBackupSyncEngine(
                preflight: preflight,
                queue: queueStore,
                remoteProofResolver: identityResolver,
                exclusions: pendingStore
            )
            runner = BackupSyncRunner(
                queue: queueStore,
                preflight: preflight,
                resolver: resolver,
                identityResolver: identityResolver,
                uploader: facade.photoUploader,
                throttleInputs: BackupRuntimeSignalSource.apple.current,
                runtimeChanges: BackupRuntimeSignalSource.apple.updates,
                events: pendingRecorder
            )
        } else {
            engine = nil
            runner = nil
        }

        loadFolders()
        reconcileQueueWithRegisteredFolders()
        if let statusProjector {
            let generation = statusProjectionGeneration
            let initialContext = projectionContext
            statusSetupTask = Task {
                await statusProjector.start(
                    generation: generation,
                    revision: 0,
                    context: initialContext
                ) { @MainActor [weak self] projection in
                    self?.applyStatusProjection(projection)
                }
                if let runner {
                    await runner.setOnProgress { snapshot in
                        statusProjector.submit(snapshot, generation: generation)
                    }
                }
            }
        }
    }

    private var projectionContext: BackupStatusProjectionContext {
        BackupStatusProjectionContext(isScanning: isScanning, isRunning: isSyncing)
    }

    private func applyStatusProjection(_ projection: BackupStatusProjection) {
        guard projection.generation == statusProjectionGeneration,
            projection.revision >= lastAppliedStatusProjectionRevision
        else { return }
        lastAppliedStatusProjectionRevision = projection.revision
        let projected = skippedCount.applied(to: projection.status)
        status = hasFolderEnumerationFailure ? projected.afterFolderEnumerationFailure() : projected
    }

    // MARK: - Folder registry (bookmarks are the App-side boundary)

    func addFolder(_ url: URL) {
        let registered = BackupFolderRegistration.bookmark(for: url) {
            try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        switch registered {
        case .success(let bookmark):
            // The same folder added again replaces its entry, also a "?" entry of a drive that was away.
            registry.add(bookmark: bookmark, path: url.path, lastKnownPath: Self.lastKnownPath(of:))
            persistFolders()
            refreshFolderAccess()
            lastMessage = BackupFolderRegistration.messageAfterSuccessfulAdd(current: lastMessage)
        case .failure(let failure):
            lastMessage = failure.message
        }
    }

    func removeFolder(_ id: WatchedFolder.ID) {
        registry.remove(id)
        persistFolders()
        refreshFolderAccess()
        reconcileQueueWithRegisteredFolders()
        refreshFromQueue()
    }

    private func loadFolders() {
        let savedPaths = UserDefaults.standard.object(forKey: Self.pathsDefaultsKey)
        registry = WatchedFolderRegistry(
            savedBookmarks: WatchedFolderScope.registeredBookmarks(
                storedValue: UserDefaults.standard.object(forKey: Self.foldersDefaultsKey)),
            savedPaths: savedPaths,
            resolve: Self.resolve(bookmark:), lastKnownPath: Self.lastKnownPath(of:))
        if registry.pathsNeedSaving(comparedTo: savedPaths) { persistFolders() }
        refreshFolderAccess()
    }

    /// Resolves every bookmark again before a pass, off the main actor: a resolution can wait for a network volume. A
    /// folder whose drive was mounted meanwhile becomes readable at its current path before the reconcile and the claims,
    /// also under another name, and one that no longer resolves is marked (#1583). A folder that the person added during
    /// the resolution stays as it is.
    private func refreshFolders() async {
        let bookmarks = registry.bookmarks
        let resolved = await Task.detached {
            Dictionary(
                bookmarks.map { ($0, (Self.resolve(bookmark: $0), Self.lastKnownPath(of: $0))) },
                uniquingKeysWith: { first, _ in first })
        }.value
        updateRegistry {
            $0.refresh(resolve: { resolved[$0]?.0 }, lastKnownPath: { resolved[$0]?.1 })
        }
    }

    /// Changes the folder list, saves it when its bookmarks or paths changed, and updates the folder access.
    private func updateRegistry(_ change: (inout WatchedFolderRegistry) -> Bool) {
        let before = registry
        guard change(&registry) else { return }
        if registry.needsSaving(since: before) { persistFolders() }
        refreshFolderAccess()
    }

    private nonisolated static func resolve(bookmark: Data) -> WatchedFolderBookmarkResolution {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        else { return .unresolved }
        return .resolved(path: url.path, isStale: stale)
    }

    /// The path that a bookmark recorded, also while its drive is not mounted.
    private nonisolated static func lastKnownPath(of bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    }

    /// Keeps every readable folder accessible at its current path, for pending thumbnails, the viewer, export and the
    /// backup. An access to a folder that now has another path, for example a drive that came back as "Photos 1",
    /// starts again at the new path.
    private func refreshFolderAccess() {
        let changes = registry.accessChanges(holding: accessedFolders.mapValues(\.path))
        for id in changes.stop {
            accessedFolders[id]?.stopAccessingSecurityScopedResource()
            accessedFolders[id] = nil
        }
        for folder in changes.start {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ), url.startAccessingSecurityScopedResource()
            else { continue }
            accessedFolders[folder.id] = url
        }
        pendingAccess.setScope(registry.scope(readable: Array(accessedFolders.values)))
    }

    // MARK: - Pending grid

    /// The folder backup as a source of the pending grid.
    var pendingFileSource: PendingFileSource? {
        guard let queueStore, pendingStore != nil else { return nil }
        return PendingFileSource(
            queue: queueStore,
            metadata: PendingFolderMetadataProvider(access: pendingAccess),
            removeFromBackup: { [weak self] paths in await self?.removeFromBackup(paths: paths) ?? false },
            returnToBackup: { [weak self] paths in await self?.returnToBackup(paths: paths) ?? [] }
        )
    }

    /// Removes excluded files from queued and in-flight work; a rescan never offers them again.
    private func removeFromBackup(paths: [String]) async -> Bool {
        guard let runner, queueStore?.isOperational() == true else { return false }
        _ = await runner.removeSources(kind: .fileURL, identifiers: paths)
        return queueStore?.holdsNoRows(kind: .fileURL, identifiers: paths) == true
    }

    /// Enqueues restored files again, starts a pass and returns the paths that count as returned.
    /// A file that is gone needs nothing and counts as done; a file whose attributes cannot be
    /// read, or whose folder cannot be read now, does not count as returned, so its queue duty
    /// stays and the next backoff tries it again.
    private func returnToBackup(paths: [String]) async -> Set<String> {
        guard let engine else { return [] }
        let batch = await FolderBackupCatalog.returnToBackup(
            paths: paths,
            scope: pendingAccess.scope,
            engine: engine
        )
        refreshFromQueue()
        if batch.queuedCount > 0 { syncNow() }
        return batch.returnedPaths
    }

    private func persistFolders() {
        // The saved list is now the registry, also an empty one after the last folder was removed.
        UserDefaults.standard.set(registry.bookmarks, forKey: Self.foldersDefaultsKey)
        UserDefaults.standard.set(registry.pathsToSave, forKey: Self.pathsDefaultsKey)
        registry.pathsWereSaved()
    }

    /// The queue is a derived work index. The core removes only the rows that no registered folder
    /// holds; the separate backup-state manifest retains deduplication history.
    private func reconcileQueueWithRegisteredFolders() {
        queueStore?.removeFileSources(outside: pendingAccess.scope)
    }

    // MARK: - Sync lifecycle

    func syncNow() {
        guard !isShuttingDown, !isSyncing, runnerStopTask == nil, isAvailable, let engine, let runner else { return }
        let runID = UUID()
        activeRunID = runID
        isSyncing = true
        isScanning = true
        hasFolderEnumerationFailure = false
        lastMessage = nil
        let skippedFiles = FolderBackupSkippedFiles()
        scanSkippedFiles = skippedFiles
        refreshFromQueue()
        let statusSetupTask = self.statusSetupTask
        syncTask = Task { [weak self, statusSetupTask] in
            await statusSetupTask?.value
            // The folders as they are now come first: the reconcile, the scan and the claims all use them.
            await self?.refreshFolders()
            self?.reconcileQueueWithRegisteredFolders()
            let snapshotFolders = self?.folders ?? []
            self?.refreshFromQueue()
            var accessedURLs: [URL] = []
            defer {
                for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
            }

            // Scan every reachable folder first (cheap, no bytes), then drain the shared queue.
            for folder in snapshotFolders {
                guard !Task.isCancelled else {
                    self?.finishScanPhase(stopped: true)
                    await self?.finishSync(runID: runID)
                    return
                }
                var stale = false
                guard
                    let url = try? URL(
                        resolvingBookmarkData: folder.bookmark,
                        options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    ), !stale, url.startAccessingSecurityScopedResource()
                else {
                    self?.applyResolution(.unresolved, to: folder.id)
                    self?.recordFolderEnumerationFailure(
                        Self.localizedFolderError(
                            failureClass: .missing,
                            name: folder.displayPath
                        )
                    )
                    continue
                }
                accessedURLs.append(url)
                // A folder that resolves cleanly is readable again, before the pass claims its rows.
                self?.applyResolution(.resolved(path: url.path, isStale: false), to: folder.id)
                do {
                    _ = try await engine.scan(FolderBackupCatalog(folder: url, skippedFiles: skippedFiles))
                } catch is CancellationError {
                    self?.finishScanPhase(stopped: true)
                    await self?.finishSync(runID: runID)
                    return
                } catch let error as FolderEnumerationError {
                    guard !Task.isCancelled else {
                        self?.finishScanPhase(stopped: true)
                        await self?.finishSync(runID: runID)
                        return
                    }
                    self?.reportFolderEnumerationError(error, folder: folder, root: url)
                } catch {
                    guard !Task.isCancelled else {
                        self?.finishScanPhase(stopped: true)
                        await self?.finishSync(runID: runID)
                        return
                    }
                    self?.recordFolderEnumerationFailure(
                        Self.localizedFolderError(
                            failureClass: .transient,
                            name: folder.displayPath
                        )
                    )
                }
            }

            self?.finishScanPhase()
            guard !Task.isCancelled else {
                await self?.finishSync(runID: runID)
                return
            }
            _ = await runner.runUntilDrained(workIntent: .userInitiated)
            await self?.finishSync(runID: runID)
        }
    }

    func stopSync() {
        syncTask?.cancel()
        requestRunnerStop()
    }

    func shutdown() async {
        isShuttingDown = true
        let activeSync = syncTask
        let activeStatusSetup = statusSetupTask
        syncTask?.cancel()
        statusSetupTask = nil
        requestRunnerStop()
        let activeStop = runnerStopTask
        await activeStop?.value
        await activeSync?.value
        await activeStatusSetup?.value
        await runner?.setOnProgress(nil)
        await statusProjector?.stop()
        queueStore?.close()
        stateStore?.close()
        for url in accessedFolders.values { url.stopAccessingSecurityScopedResource() }
        accessedFolders.removeAll()
        pendingAccess.setScope(.unavailable)
    }

    /// A folder that must be picked again is no longer readable for the pending grid or the backup either; one that
    /// resolves again is readable for both.
    private func applyResolution(_ resolution: WatchedFolderBookmarkResolution, to id: WatchedFolder.ID) {
        updateRegistry { $0.apply(resolution, to: id, lastKnownPath: Self.lastKnownPath(of:)) }
    }

    private func reportFolderEnumerationError(
        _ error: FolderEnumerationError,
        folder: WatchedFolder,
        root: URL
    ) {
        if error.requiresRootAccessRenewal(for: root) {
            applyResolution(.unresolved, to: folder.id)
        }
        let name = error.url.lastPathComponent.isEmpty ? folder.displayPath : error.url.lastPathComponent
        recordFolderEnumerationFailure(
            Self.localizedFolderError(failureClass: error.failureClass, name: name)
        )
    }

    private static func localizedFolderError(
        failureClass: FolderEnumerationError.FailureClass,
        name: String
    ) -> String {
        let key =
            switch failureClass {
            case .permissionDenied: "settings.backup_folder_error_permission %@"
            case .missing: "settings.backup_folder_error_missing %@"
            case .transient: "settings.backup_folder_error_transient %@"
            }
        return String(format: NSLocalizedString(key, comment: "Folder backup read error"), name)
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func recordFolderEnumerationFailure(_ message: String) {
        // A scan with a folder that it could not read keeps the skipped count of the last complete scan.
        scanSkippedFiles?.markIncomplete()
        hasFolderEnumerationFailure = true
        status = status.afterFolderEnumerationFailure()
        reportSyncMessage(message)
    }

    private func finishScanPhase(stopped: Bool = false) {
        isScanning = false
        if let scanSkippedFiles { skippedCount.finish(scanSkippedFiles, stopped: stopped) }
        scanSkippedFiles = nil
        refreshFromQueue()
    }

    private func finishSync(runID: UUID) async {
        let stopTask = runnerStopRunID == runID ? runnerStopTask : nil
        await stopTask?.value
        guard activeRunID == runID else { return }
        activeRunID = nil
        if runnerStopRunID == runID {
            runnerStopTask = nil
            runnerStopRunID = nil
        }
        syncTask = nil
        isSyncing = false
        isScanning = false
        refreshFromQueue()
    }

    private func requestRunnerStop() {
        guard let runID = activeRunID, runnerStopTask == nil, let runner else { return }
        let task = Task { await runner.stop() }
        runnerStopRunID = runID
        runnerStopTask = task
    }

    /// Seeds the UI snapshot from the durable queue - shows outstanding work from a previous
    /// launch before any sync pass runs (relaunch-resume visibility).
    private func refreshFromQueue() {
        guard let statusProjector else { return }
        statusProjectionRevision &+= 1
        let context = projectionContext
        let revision = statusProjectionRevision
        let generation = statusProjectionGeneration
        Task {
            _ = await statusProjector.projectNow(
                context: context,
                generation: generation,
                revision: revision
            )
        }
    }
}
