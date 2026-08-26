import Foundation
import Observation
import PhotosCore

/// Minimal upload-picker projection supplied by the app's album catalog. UploadCore deliberately
/// does not depend on AlbumCore; an upload destination needs only stable identity and display title.
public struct UploadAlbumDestination: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

typealias FolderEnqueueOperation = @Sendable (URL, UploadDestination) async throws -> [UploadQueueItemID]

/// Main-actor, observable façade the UI binds to. Mirrors the `UploadManager` actor's snapshots onto
/// the main thread and exposes the user-facing actions (choose destination, pause/resume/cancel/retry).
@MainActor
@Observable
public final class UploadCoordinator {
    public private(set) var items: [UploadItem] = []
    public private(set) var stats = UploadQueueStats()
    public var preparationStatus: UploadPreparationStatus { UploadPreparationStatus(items: items) }

    /// Albums offered in the destination picker (supplied by the app, which already loads them).
    public var albums: [UploadAlbumDestination] = []

    /// UI presentation flags.
    public var isQueueVisible = false
    public var isDestinationSheetPresented = false
    public private(set) var latestFolderEnumerationError: FolderEnumerationError?
    public private(set) var latestCompletedUpload: UploadCompletedEvent?
    public private(set) var completedUploadRevision = 0

    public let uploadCapabilities: UploadBackendCapabilities
    public let canCreateAlbum: Bool
    public let canAddToAlbum: Bool
    public let canSetAlbumCover: Bool

    private let manager: UploadManager
    private var folderEnqueueOperation: FolderEnqueueOperation
    private var pending: PendingSelection?
    private var folderEnqueueTail: Task<Void, Never>?
    private var nextFolderOperationID: UInt64 = 0
    private var latestFolderErrorOperationID: UInt64 = 0

    private enum PendingSelection {
        case files([URL])
        case folder(URL)
    }

    public init(
        manager: UploadManager,
        uploadCapabilities: UploadBackendCapabilities,
        canCreateAlbum: Bool,
        canAddToAlbum: Bool,
        canSetAlbumCover: Bool
    ) {
        self.manager = manager
        self.uploadCapabilities = uploadCapabilities
        self.canCreateAlbum = canCreateAlbum
        self.canAddToAlbum = canAddToAlbum
        self.canSetAlbumCover = canSetAlbumCover
        self.folderEnqueueOperation = { [manager] url, destination in
            try await manager.enqueueFolder(url, destination: destination)
        }
    }

    convenience init(
        manager: UploadManager,
        uploadCapabilities: UploadBackendCapabilities,
        canCreateAlbum: Bool,
        canAddToAlbum: Bool,
        canSetAlbumCover: Bool,
        folderEnqueueOperation: @escaping FolderEnqueueOperation
    ) {
        self.init(
            manager: manager,
            uploadCapabilities: uploadCapabilities,
            canCreateAlbum: canCreateAlbum,
            canAddToAlbum: canAddToAlbum,
            canSetAlbumCover: canSetAlbumCover
        )
        self.folderEnqueueOperation = folderEnqueueOperation
    }

    /// Begin streaming snapshots from the manager. Call once after construction.
    public func start() async {
        await manager.setOnChange { [weak self] items, stats in
            Task { @MainActor in
                self?.items = items
                self?.stats = stats
            }
        }
        await manager.setOnCompleted { [weak self] event in
            Task { @MainActor in
                self?.latestCompletedUpload = event
                self?.completedUploadRevision += 1
            }
        }
    }

    // MARK: - Destination flow

    public func chooseDestination(files: [URL]) {
        guard !files.isEmpty else { return }
        pending = .files(files)
        isDestinationSheetPresented = true
    }

    public func chooseDestination(folder: URL) {
        pending = .folder(folder)
        isDestinationSheetPresented = true
    }

    /// Confirm the destination, enqueue the pending selection, and reveal the queue.
    public func confirm(destination: UploadDestination) {
        let selection = pending
        pending = nil
        isDestinationSheetPresented = false
        guard let selection else { return }
        isQueueVisible = true
        switch selection {
        case .files(let urls):
            Task {
                _ = await manager.enqueueFiles(urls, destination: destination)
            }
        case .folder(let url):
            enqueueFolder(url, destination: destination)
        }
    }

    private func enqueueFolder(_ url: URL, destination: UploadDestination) {
        nextFolderOperationID &+= 1
        let operationID = nextFolderOperationID
        latestFolderEnumerationError = nil
        let predecessor = folderEnqueueTail
        let operation = folderEnqueueOperation
        folderEnqueueTail = Task { [weak self] in
            await predecessor?.value
            guard let self, !Task.isCancelled else { return }
            do {
                _ = try await operation(url, destination)
            } catch is CancellationError {
                // Cancellation does not indicate a folder-access failure.
            } catch let error as FolderEnumerationError {
                presentFolderEnumerationError(error, operationID: operationID)
            } catch {
                presentFolderEnumerationError(
                    FolderEnumerationError(operation: .readDirectory, url: url, error: error),
                    operationID: operationID
                )
            }
            if operationID == nextFolderOperationID {
                folderEnqueueTail = nil
            }
        }
    }

    private func presentFolderEnumerationError(
        _ error: FolderEnumerationError,
        operationID: UInt64
    ) {
        guard operationID == nextFolderOperationID,
            operationID > latestFolderErrorOperationID
        else { return }
        latestFolderErrorOperationID = operationID
        latestFolderEnumerationError = error
    }

    public func dismissFolderEnumerationError() {
        latestFolderEnumerationError = nil
    }

    public func cancelDestination() {
        pending = nil
        isDestinationSheetPresented = false
    }

    // MARK: - Queue item actions

    public func pause(_ id: UploadQueueItemID) { Task { await manager.pause(id) } }
    public func resume(_ id: UploadQueueItemID) { Task { await manager.resume(id) } }
    public func cancel(_ id: UploadQueueItemID) { Task { await manager.cancel(id) } }
    public func retry(_ id: UploadQueueItemID) { Task { await manager.retry(id) } }
    public func clearFinished() { Task { await manager.clearFinished() } }
}
