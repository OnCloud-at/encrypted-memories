import Foundation
import MediaFeedCore
import PhotosCore

public enum LibraryInventoryDelta {
    /// Returns newly discovered identities in authoritative timeline order.
    public static func addedUIDs(previous: [PhotoUID], current: [PhotoUID]) -> [PhotoUID] {
        let previousSet = Set(previous)
        var seen = Set<PhotoUID>()
        return current.filter { previousSet.contains($0) == false && seen.insert($0).inserted }
    }
}

public struct LibraryThumbnailUpdateState: Equatable, Sendable {
    public let pendingCount: Int

    public var isActive: Bool { pendingCount > 0 }

    public init(pendingCount: Int = 0) {
        self.pendingCount = max(0, pendingCount)
    }

    public static let idle = LibraryThumbnailUpdateState()
}

public struct LibraryThumbnailUpdatePolicy: Equatable, Sendable {
    public let pollInterval: Duration
    public let maximumStatusBatch: Int
    public let pollsBetweenRetries: Int

    public init(
        pollInterval: Duration = .seconds(1),
        maximumStatusBatch: Int = 128,
        pollsBetweenRetries: Int = 10
    ) {
        self.pollInterval = pollInterval
        self.maximumStatusBatch = max(1, maximumStatusBatch)
        self.pollsBetweenRetries = max(1, pollsBetweenRetries)
    }
}

/// Tracks only thumbnails that belong to assets newly discovered by an authoritative inventory refresh.
/// Generic cache crawling, location indexing, polling, and metadata-only changes never enter this state machine.
@MainActor
public final class LibraryThumbnailUpdateCoordinator {
    public typealias Resolver =
        @Sendable (
            _ uids: [PhotoUID],
            _ enqueueMissing: Bool
        ) async -> LibraryThumbnailResolutionSnapshot

    public private(set) var state: LibraryThumbnailUpdateState = .idle

    private let policy: LibraryThumbnailUpdatePolicy
    private var pendingUIDs: [PhotoUID] = []
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var stateHandler: (@MainActor @Sendable (LibraryThumbnailUpdateState) -> Void)?

    public init(policy: LibraryThumbnailUpdatePolicy = LibraryThumbnailUpdatePolicy()) {
        self.policy = policy
    }

    /// Reconciles one authoritative inventory. Existing pending IDs survive later refreshes, newly added IDs join
    /// the same batch, and deleted IDs retire immediately. No deadline can hide genuine thumbnail work.
    public func reconcile(
        currentUIDs: [PhotoUID],
        addedUIDs: [PhotoUID],
        onStateChange: (@MainActor @Sendable (LibraryThumbnailUpdateState) -> Void)? = nil,
        resolver: @escaping Resolver
    ) {
        if let onStateChange { stateHandler = onStateChange }
        let currentSet = Set(currentUIDs)
        var next = pendingUIDs.filter { currentSet.contains($0) }
        var included = Set(next)
        for uid in addedUIDs where currentSet.contains(uid) && included.insert(uid).inserted {
            next.append(uid)
        }

        guard next != pendingUIDs || worker == nil else { return }
        let previousWorker = worker
        previousWorker?.cancel()
        generation &+= 1
        let activeGeneration = generation
        pendingUIDs = next
        updateState(LibraryThumbnailUpdateState(pendingCount: next.count))

        guard !next.isEmpty else {
            worker = nil
            return
        }

        let policy = self.policy
        worker = Task { [weak self, previousWorker] in
            await previousWorker?.value
            guard !Task.isCancelled else { return }
            await Self.resolve(
                next,
                policy: policy,
                resolver: resolver
            ) { remaining in
                self?.publish(remaining: remaining, generation: activeGeneration)
            }
        }
    }

    /// Cancels account-bound work and returns the retiring task so teardown can join it before releasing the feed.
    @discardableResult
    public func cancel() -> Task<Void, Never>? {
        generation &+= 1
        let retiring = worker
        retiring?.cancel()
        worker = nil
        pendingUIDs.removeAll(keepingCapacity: false)
        updateState(.idle)
        return retiring
    }

    private func publish(remaining: [PhotoUID], generation: UInt64) {
        guard generation == self.generation else { return }
        pendingUIDs = remaining
        updateState(LibraryThumbnailUpdateState(pendingCount: remaining.count))
        if remaining.isEmpty { worker = nil }
    }

    private func updateState(_ next: LibraryThumbnailUpdateState) {
        guard next != state else { return }
        state = next
        stateHandler?(next)
    }

    private nonisolated static func resolve(
        _ initialUIDs: [PhotoUID],
        policy: LibraryThumbnailUpdatePolicy,
        resolver: @escaping Resolver,
        publish: @escaping @MainActor @Sendable ([PhotoUID]) -> Void
    ) async {
        var pending = initialUIDs
        var everEnqueued = Set<PhotoUID>()
        var pollsSinceRetry = policy.pollsBetweenRetries

        while !pending.isEmpty, !Task.isCancelled {
            let statusCount = min(policy.maximumStatusBatch, pending.count)
            let checked = Array(pending.prefix(statusCount))
            let unchecked = Array(pending.dropFirst(statusCount))
            let includesNewDemand = checked.contains { everEnqueued.contains($0) == false }
            let shouldEnqueue = includesNewDemand || pollsSinceRetry >= policy.pollsBetweenRetries
            let resolution = await resolver(checked, shouldEnqueue)
            guard !Task.isCancelled else { return }

            if shouldEnqueue {
                everEnqueued.formUnion(checked)
                pollsSinceRetry = 0
            } else {
                pollsSinceRetry += 1
            }

            let settled = Set(resolution.availableUIDs).union(resolution.terminalUIDs)
            let unresolved = checked.filter { settled.contains($0) == false }
            pending = unchecked + unresolved
            await publish(pending)
            guard !pending.isEmpty else { return }

            do {
                try await Task.sleep(for: policy.pollInterval)
            } catch {
                return
            }
        }
    }
}
