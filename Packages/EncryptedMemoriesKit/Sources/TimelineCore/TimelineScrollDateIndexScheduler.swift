import Foundation
import PhotosCore

/// Builds the scroll date index of a changing photo list away from the main actor. A library refresh can replace the
/// list many times per second; the scheduler keeps at most one build running and builds the newest list next, so a
/// result always arrives and stale lists are skipped. A cancelled build is cancelled all the way into its background
/// task, and a later build starts only after it ended.
@MainActor
public final class TimelineScrollDateIndexScheduler {
    public typealias Builder = @Sendable (_ items: [PhotoItem], _ revision: UInt64) async -> TimelineScrollDateIndex?

    /// Receives each finished index, or nil for an empty list.
    public var onIndex: ((TimelineScrollDateIndex?) -> Void)?

    private let build: Builder
    private var revision: UInt64 = 0
    private var pending: [PhotoItem]?
    private var task: Task<Void, Never>?
    /// The last cancelled task. The next build waits for it, so two full-library builds never overlap.
    private var retiring: Task<Void, Never>?

    public init(build: @escaping Builder = TimelineScrollDateIndexScheduler.detachedBuild) {
        self.build = build
    }

    /// The default builder: one pass over the items on a background task. Cancelling the caller cancels that task,
    /// which stops within 256 items.
    public nonisolated static let detachedBuild: Builder = { items, revision in
        let task = Task.detached(priority: .userInitiated) {
            TimelineScrollDateIndex.build(items: items, revision: revision)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Schedules an index for `items`. An empty list reports nil at once.
    public func update(items: [PhotoItem]) {
        revision &+= 1
        guard !items.isEmpty else {
            cancel()  // A running build must not deliver an index for the old list afterwards.
            onIndex?(nil)
            return
        }
        pending = items
        guard task == nil else { return }  // The running build picks up the newest list next.
        let previous = retiring
        task = Task { [weak self] in
            await previous?.value
            await self?.drain()
        }
    }

    /// Stops building; no later result reaches `onIndex`.
    public func cancel() {
        pending = nil
        guard let task else { return }
        task.cancel()
        retiring = task
        self.task = nil
    }

    private func drain() async {
        while let items = pending, !Task.isCancelled {
            pending = nil
            let index = await build(items, revision)
            guard !Task.isCancelled else { return }
            onIndex?(index)
        }
        if !Task.isCancelled { task = nil }  // A cancelled build may already have a successor.
    }
}
