import Foundation
import Observation

/// Owns publication of an immutable collection snapshot across reloads and confirmed removals.
/// Expensive transforms run off the main actor. A transform rebases if another publication won
/// while it was suspended, so independent removals cannot restore one another's items.
@MainActor @Observable
public final class TimelineSnapshotReconciler {
    public struct LoadToken: Sendable {
        fileprivate let epoch: UUID
        fileprivate let generation: UInt64
        fileprivate let revision: UInt64
    }

    public private(set) var snapshot: TimelineSnapshot
    @ObservationIgnored public private(set) var epoch = UUID()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private let transform: @Sendable (TimelineSnapshot, Set<PhotoUID>) async -> TimelineSnapshot

    public convenience init(snapshot: TimelineSnapshot = TimelineSnapshot()) {
        self.init(snapshot: snapshot) { snapshot, uids in
            await Task.detached(priority: .userInitiated) {
                snapshot.removingItems(withUIDs: uids)
            }.value
        }
    }

    init(
        snapshot: TimelineSnapshot,
        transform: @escaping @Sendable (TimelineSnapshot, Set<PhotoUID>) async -> TimelineSnapshot
    ) {
        self.snapshot = snapshot
        self.transform = transform
    }

    /// A route/account replacement fences every previously admitted operation without retaining
    /// permanent UID tombstones. A later authoritative load may legitimately add an item again.
    public func reset(to snapshot: TimelineSnapshot = TimelineSnapshot()) {
        invalidatePendingWork()
        self.snapshot = snapshot
    }

    public func invalidatePendingWork() {
        epoch = UUID()
        revision &+= 1
        loadGeneration &+= 1
    }

    public func beginLoad() -> LoadToken {
        loadGeneration &+= 1
        return LoadToken(epoch: epoch, generation: loadGeneration, revision: revision)
    }

    public func isCurrent(_ token: LoadToken) -> Bool {
        token.epoch == epoch && token.generation == loadGeneration && token.revision == revision
    }

    @discardableResult
    public func publishLoaded(_ snapshot: TimelineSnapshot, token: LoadToken) -> Bool {
        guard isCurrent(token) else { return false }
        self.snapshot = snapshot
        revision &+= 1
        return true
    }

    @discardableResult
    public func remove(
        _ uids: Set<PhotoUID>, within operationEpoch: UUID,
        withPublication: (_ update: () -> Void) -> Void = { $0() }
    ) async -> Bool {
        guard operationEpoch == epoch else { return false }
        // A load that started before the confirmed server mutation cannot republish old content.
        revision &+= 1
        loadGeneration &+= 1
        while true {
            let baseRevision = revision
            let updated = await transform(snapshot, uids)
            guard operationEpoch == epoch else { return false }
            guard baseRevision == revision else { continue }
            // The native host can wrap this synchronous commit in its animation transaction.
            // Confirmed remote mutations still reconcile if their caller was cancelled; a route
            // or account epoch change, rather than cancellation alone, retires this publication.
            withPublication {
                snapshot = updated
                revision &+= 1
                // Also reject loads started while this transform was suspended.
                loadGeneration &+= 1
            }
            return true
        }
    }
}
