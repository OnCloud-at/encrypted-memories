import Foundation
import Photos

struct PhotoLibraryLiveChangeBuffer {
    struct Snapshot: Equatable {
        var changedIdentifiers: Set<String>
        var deletedIdentifiers: Set<String>
        var requiresFullRescan: Bool
        var generation: UInt64
    }

    private struct Batch {
        var changedIdentifiers: Set<String>
        var deletedIdentifiers: Set<String>
        var requiresFullRescan: Bool
        var generation: UInt64
    }

    private var batches: [Batch] = []
    private var generation: UInt64 = 0

    mutating func record(
        changedIdentifiers: Set<String>,
        deletedIdentifiers: Set<String>,
        requiresFullRescan: Bool
    ) {
        guard requiresFullRescan || !changedIdentifiers.isEmpty || !deletedIdentifiers.isEmpty else { return }
        generation &+= 1
        var changed = changedIdentifiers
        changed.subtract(deletedIdentifiers)
        batches.append(
            Batch(
                changedIdentifiers: changed,
                deletedIdentifiers: deletedIdentifiers,
                requiresFullRescan: requiresFullRescan,
                generation: generation
            )
        )
    }

    func snapshot() -> Snapshot {
        var changed: Set<String> = []
        var deleted: Set<String> = []
        var requiresFullRescan = false
        for batch in batches {
            changed.formUnion(batch.changedIdentifiers)
            deleted.formUnion(batch.deletedIdentifiers)
            requiresFullRescan = requiresFullRescan || batch.requiresFullRescan
        }
        changed.subtract(deleted)
        return Snapshot(
            changedIdentifiers: changed,
            deletedIdentifiers: deleted,
            requiresFullRescan: requiresFullRescan,
            generation: generation
        )
    }

    mutating func commit(through committedGeneration: UInt64) {
        batches.removeAll { $0.generation <= committedGeneration }
    }

    mutating func reset() {
        batches.removeAll(keepingCapacity: false)
    }
}

/// Incremental change tracking across launches (persistent change history) plus a live in-session
/// observer. The persistent token is PhotoKit-specific state, so it lives here in the adapter,
/// persisted as a secure-coded archive next to the account's backup stores.
public final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private final class ObservedAssetsBox: @unchecked Sendable {
        let fetchResult: PHFetchResult<PHAsset>

        init(_ fetchResult: PHFetchResult<PHAsset>) {
            self.fetchResult = fetchResult
        }
    }

    public struct ChangeSet: Sendable {
        /// Assets to (re)scan - inserted or updated.
        public var changedIdentifiers: [String]
        /// Assets deleted locally (backup never mirrors deletions; rows become source-missing
        /// lazily when work touches them).
        public var deletedIdentifiers: [String]
        /// The stored token no longer resolves (expired history / first run) - callers fall back
        /// to a full cheap rescan, which preflight keeps mostly read-only.
        public var requiresFullRescan: Bool
    }

    public struct PreparedChangeSet: @unchecked Sendable {
        public let changes: ChangeSet
        fileprivate let commitToken: PHPersistentChangeToken
        fileprivate let liveGeneration: UInt64
    }

    private let tokenURL: URL
    private let fetchObservedAssets: @Sendable () -> PHFetchResult<PHAsset>
    private let lock = NSLock()
    private var onLibraryChange: (@Sendable () -> Void)?
    private var observedAssets: PHFetchResult<PHAsset>?
    private var liveChanges = PhotoLibraryLiveChangeBuffer()
    private var isObserving = false
    private var isStarting = false
    private var observationGeneration: UInt64 = 0

    public convenience init(tokenURL: URL) {
        self.init(tokenURL: tokenURL) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            return PHAsset.fetchAssets(with: options)
        }
    }

    init(
        tokenURL: URL,
        fetchObservedAssets: @escaping @Sendable () -> PHFetchResult<PHAsset>
    ) {
        self.tokenURL = tokenURL
        self.fetchObservedAssets = fetchObservedAssets
        super.init()
    }

    deinit {
        if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// Starts the in-session observer. `handler` fires (debounced by the caller) whenever the
    /// library changes while the app runs. The initial full-library fetch runs on a utility task
    /// so a foreground controller never blocks its actor while PhotoKit creates the snapshot.
    public func startObserving(_ handler: @Sendable @escaping () -> Void) {
        let generation: UInt64? = lock.withLock {
            onLibraryChange = handler
            guard !isObserving, !isStarting else { return nil }
            isStarting = true
            observationGeneration &+= 1
            return observationGeneration
        }
        guard let generation else { return }

        let fetchObservedAssets = self.fetchObservedAssets
        Task.detached(priority: .utility) { [weak self] in
            let assets = ObservedAssetsBox(fetchObservedAssets())
            guard !Task.isCancelled else { return }
            self?.finishStarting(with: assets, generation: generation)
        }
    }

    public func stopObserving() {
        let shouldUnregister = lock.withLock {
            onLibraryChange = nil
            observationGeneration &+= 1
            isStarting = false
            guard isObserving else { return false }
            isObserving = false
            observedAssets = nil
            liveChanges.reset()
            return true
        }
        if shouldUnregister {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    private func finishStarting(with assets: ObservedAssetsBox, generation: UInt64) {
        let shouldRegister: Bool = lock.withLock {
            guard isStarting, generation == observationGeneration, onLibraryChange != nil else { return false }
            observedAssets = assets.fetchResult
            isStarting = false
            isObserving = true
            return true
        }
        guard shouldRegister else { return }

        // PhotoKit owns this external callback boundary. Never call it while holding our state lock:
        // registration may synchronously re-enter the observer. A stop that races registration is
        // repaired by the post-registration generation check.
        PHPhotoLibrary.shared().register(self)
        let registrationIsCurrent = lock.withLock {
            isObserving && generation == observationGeneration
        }
        if !registrationIsCurrent {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard isObserving,
                let observedAssets,
                let details = changeInstance.changeDetails(for: observedAssets)
            else {
                return nil
            }
            self.observedAssets = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                liveChanges.record(
                    changedIdentifiers: Set(
                        (details.insertedObjects + details.changedObjects).map(\.localIdentifier)
                    ),
                    deletedIdentifiers: Set(details.removedObjects.map(\.localIdentifier)),
                    requiresFullRescan: false
                )
            } else {
                liveChanges.record(
                    changedIdentifiers: [],
                    deletedIdentifiers: [],
                    requiresFullRescan: true
                )
            }
            return onLibraryChange
        }
        handler?()
    }

    /// Changes since the stored token. This deliberately does not advance the stored token. Callers
    /// must commit the returned value only after their durable scan/enqueue work succeeds.
    public func prepareChanges() -> PreparedChangeSet {
        let library = PHPhotoLibrary.shared()
        let live = lock.withLock { liveChanges.snapshot() }
        let currentToken = library.currentChangeToken

        guard let previous = loadToken() else {
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(live.changedIdentifiers),
                    deletedIdentifiers: Array(live.deletedIdentifiers),
                    requiresFullRescan: true
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        }
        do {
            var changed = live.changedIdentifiers
            var deleted = live.deletedIdentifiers
            for change in try library.fetchPersistentChanges(since: previous) {
                do {
                    let details = try change.changeDetails(for: .asset)
                    changed.formUnion(details.insertedLocalIdentifiers)
                    changed.formUnion(details.updatedLocalIdentifiers)
                    deleted.formUnion(details.deletedLocalIdentifiers)
                } catch {
                    // Advancing past one unreadable history entry could permanently miss an asset.
                    // Fall back to the stable full scan and commit the token only after that succeeds.
                    return PreparedChangeSet(
                        changes: ChangeSet(
                            changedIdentifiers: Array(changed),
                            deletedIdentifiers: Array(deleted),
                            requiresFullRescan: true
                        ),
                        commitToken: currentToken,
                        liveGeneration: live.generation
                    )
                }
            }
            changed.subtract(deleted)
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(changed),
                    deletedIdentifiers: Array(deleted),
                    requiresFullRescan: live.requiresFullRescan
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        } catch {
            // Token expired or history unavailable - full cheap rescan is the documented fallback.
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(live.changedIdentifiers),
                    deletedIdentifiers: Array(live.deletedIdentifiers),
                    requiresFullRescan: true
                ),
                commitToken: currentToken,
                liveGeneration: live.generation
            )
        }
    }

    /// Advances the persistent token after the caller has durably handled the prepared changes.
    public func commit(_ prepared: PreparedChangeSet) {
        store(token: prepared.commitToken)
        lock.withLock {
            liveChanges.commit(through: prepared.liveGeneration)
        }
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func store(token: PHPersistentChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            return
        }
        try? data.write(to: tokenURL, options: .atomic)
    }
}
