import PhotosCore

public struct TimelineSearchProjectionKey: Hashable, Sendable {
    public let sourceRevision: UInt64
    public let query: String
    public let context: TimelineSearchContext
    public let semanticMatches: Set<PhotoUID>?
    public let refinement: TimelineRefinement

    public init(
        sourceRevision: UInt64,
        query: String,
        context: TimelineSearchContext,
        semanticMatches: Set<PhotoUID>?,
        refinement: TimelineRefinement = .all
    ) {
        self.sourceRevision = sourceRevision
        self.query = query
        self.context = context
        self.semanticMatches = semanticMatches
        self.refinement = refinement
    }
}

/// One authoritative, indexed result for a settled query. Both Apple hosts consume this value instead of
/// independently filtering or flattening the full library during view rendering.
public struct TimelineSearchProjection: Sendable {
    public let key: TimelineSearchProjectionKey
    public let sections: [TimelineSection]
    public let snapshot: TimelineSnapshot
    /// Stable display order for top-leading filter results. Core builds the reversed array once per projection,
    /// so repeated SwiftUI selection and chrome updates do not allocate another full result array.
    public let presentationItems: [PhotoItem]
    public let revision: UInt64

    public init(key: TimelineSearchProjectionKey, sections: [TimelineSection], revision: UInt64 = 0) {
        self.key = key
        let filtered = TimelineSearch.filter(
            sections,
            query: key.query,
            context: key.context,
            semanticMatches: key.semanticMatches,
            refinement: key.refinement
        )
        let projection = TimelineContentProjection(sections: filtered)
        self.sections = projection.sections
        snapshot = projection.snapshot
        if key.refinement.isActive, TimelineSearchQuery(key.query).isEmpty {
            presentationItems = Array(projection.snapshot.items.reversed())
        } else {
            presentationItems = projection.snapshot.items
        }
        self.revision = revision
    }
}

/// Newest-wins worker for large-library search. The scan runs outside UI actors, the previous scan is
/// cooperatively cancelled, and a completion is returned only if no newer request superseded it.
public actor TimelineSearchProjectionCoordinator {
    private var generation: UInt64 = 0
    private var pendingTask: Task<TimelineSearchProjection, Never>?
    private var cachedProjection: TimelineSearchProjection?

    public init() {}

    deinit {
        pendingTask?.cancel()
    }

    public func resolve(
        sections: [TimelineSection],
        key: TimelineSearchProjectionKey
    ) async -> TimelineSearchProjection? {
        if cachedProjection?.key == key { return cachedProjection }

        generation &+= 1
        let requestGeneration = generation
        pendingTask?.cancel()
        let task = Task.detached(priority: .userInitiated) {
            TimelineSearchProjection(key: key, sections: sections, revision: requestGeneration)
        }
        pendingTask = task
        let projection = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, requestGeneration == generation else { return nil }
        cachedProjection = projection
        pendingTask = nil
        return projection
    }

    public func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        cachedProjection = nil
    }
}
