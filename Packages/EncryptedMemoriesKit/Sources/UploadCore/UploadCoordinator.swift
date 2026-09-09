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

/// `items` and `stats` travel together so the consumer never mixes queue state from two moments.
struct UploadSnapshotEnvelope: Sendable {
    let sequence: UInt64
    let items: [UploadItem]
    let stats: UploadQueueStats
}

/// Bounded single-slot mailbox for the latest snapshot. `deliver` succeeds only while the owning
/// coordinator generation is alive; after `finish()` every late delivery returns `false` and is
/// dropped, so a stale callback can neither overwrite newer state nor leak unbounded tasks.
final class UploadCallbackMailbox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Element>.Continuation?
    private let sequence: ((Element) -> UInt64)?
    private var latestSequence: UInt64 = 0

    init(
        continuation: AsyncStream<Element>.Continuation,
        sequence: ((Element) -> UInt64)? = nil
    ) {
        self.continuation = continuation
        self.sequence = sequence
    }

    /// Enqueues the value if the mailbox is still attached. Returns `false` for retired mailboxes.
    @discardableResult
    func deliver(_ value: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        if let sequence {
            let valueSequence = sequence(value)
            guard valueSequence > latestSequence else { return false }
            latestSequence = valueSequence
        }
        continuation.yield(value)
        return true
    }

    /// Detaches the mailbox so late deliveries are dropped and the stream terminates.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.finish()
    }
}

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

    /// Streaming state belongs to this coordinator. Repeated starts share the same subscription;
    /// account replacement creates a new coordinator and manager.
    @ObservationIgnored private var snapshotMailbox: UploadCallbackMailbox<UploadSnapshotEnvelope>?
    @ObservationIgnored private var completionMailbox: UploadCallbackMailbox<UploadCompletedEvent>?
    @ObservationIgnored private var snapshotConsumerTask: Task<Void, Never>?
    @ObservationIgnored private var completionConsumerTask: Task<Void, Never>?
    @ObservationIgnored private var appliedSnapshotSequence: UInt64 = 0

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

    deinit {
        snapshotMailbox?.finish()
        completionMailbox?.finish()
        snapshotConsumerTask?.cancel()
        completionConsumerTask?.cancel()
    }

    /// Begins one subscription. Admission is synchronous on MainActor, so concurrent calls cannot
    /// install a retired callback after a newer start or create a gap in terminal event delivery.
    public func start() async {
        guard snapshotMailbox == nil else { return }
        let (snapshotStream, snapshotContinuation) = AsyncStream.makeStream(
            of: UploadSnapshotEnvelope.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (completionStream, completionContinuation) = AsyncStream.makeStream(of: UploadCompletedEvent.self)
        let snapshotMailbox = UploadCallbackMailbox(
            continuation: snapshotContinuation,
            sequence: { $0.sequence }
        )
        let completionMailbox = UploadCallbackMailbox(continuation: completionContinuation)
        self.snapshotMailbox = snapshotMailbox
        self.completionMailbox = completionMailbox
        snapshotConsumerTask = Task { @MainActor [weak self] in
            for await envelope in snapshotStream {
                self?.applySnapshot(envelope)
            }
        }
        completionConsumerTask = Task { @MainActor [weak self] in
            for await event in completionStream {
                self?.applyCompletedUpload(event)
            }
        }
        await manager.setCoordinatorCallbacks(
            onChange: { [weak snapshotMailbox] sequence, items, stats in
                snapshotMailbox?.deliver(UploadSnapshotEnvelope(sequence: sequence, items: items, stats: stats))
            },
            onCompleted: { [weak completionMailbox] event in
                completionMailbox?.deliver(event)
            }
        )
    }

    /// Applies a snapshot envelope unless a newer sequence was already applied.
    func applySnapshot(_ envelope: UploadSnapshotEnvelope) {
        guard envelope.sequence > appliedSnapshotSequence else { return }
        appliedSnapshotSequence = envelope.sequence
        items = envelope.items
        stats = envelope.stats
    }

    /// Applies a durable completion event. Deliberately unfenced: completions must stay lossless.
    func applyCompletedUpload(_ event: UploadCompletedEvent) {
        latestCompletedUpload = event
        completedUploadRevision += 1
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
