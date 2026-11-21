import Foundation
import PhotosCore

public struct ViewerTitleMetadataResolution: Equatable, Sendable {
    public let metadata: PhotoMetadata?
    public let placeName: String?
    public let metadataLoadFailed: Bool
    /// The cause of the failed read when the provider's error names one; nil for an unclassified error.
    public let failureCause: FailureCause?

    public init(
        metadata: PhotoMetadata?, placeName: String?, metadataLoadFailed: Bool = false,
        failureCause: FailureCause? = nil
    ) {
        self.metadata = metadata
        self.placeName = placeName
        self.metadataLoadFailed = metadataLoadFailed
        self.failureCause = failureCause
    }

    public var metadataLoadState: PhotoMetadataLoadState {
        if let metadata { return .loaded(metadata) }
        return metadataLoadFailed ? .failed : .unavailable
    }
}

public enum ViewerTitleMetadataState: Equatable, Sendable {
    case resolving
    case resolved(ViewerTitleMetadataResolution)

    public var resolution: ViewerTitleMetadataResolution? {
        guard case .resolved(let value) = self else { return nil }
        return value
    }

    /// Reserve the POI headline only when the encrypted location index already proves this photo has GPS.
    /// Unknown and location-less photos show the capture date on line one immediately; nearby GPS photos still
    /// keep stable two-line geometry while reverse geocoding finishes.
    public func shouldReservePlaceNameLine(hasKnownLocation: Bool) -> Bool {
        hasKnownLocation && self == .resolving
    }
}

/// Bounded shared metadata prefetch for viewer titles. Both app shells ask for the current item and its nearby
/// neighbors, so a normal swipe can promote an already-resolved POI without first replacing it with the date.
@MainActor
public final class ViewerTitleMetadataCoordinator {
    private struct ResolutionTask {
        let id: UUID
        let task: Task<ViewerTitleMetadataResolution, Never>
    }

    private let metadataProvider: (any PhotoMetadataProvider)?
    private let placeNameResolver: (any PlaceNameResolving)?
    private let prefetchRadius: Int
    private let infoRereadPause: @MainActor (Duration) async -> Void
    private var states: [PhotoUID: ViewerTitleMetadataState] = [:]
    private var tasks: [PhotoUID: ResolutionTask] = [:]
    /// Photos whose failed read the Info already repeated silently once while they stayed in the window.
    private var silentlyRereadForInfo: Set<PhotoUID> = []

    /// How long the Info waits before it reads the details of the shown photo a second time.
    public static let infoRereadDelay: Duration = .seconds(3)

    public init(
        metadataProvider: (any PhotoMetadataProvider)?,
        placeNameResolver: (any PlaceNameResolving)?,
        prefetchRadius: Int = 2,
        infoRereadPause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.metadataProvider = metadataProvider
        self.placeNameResolver = placeNameResolver
        self.prefetchRadius = max(0, prefetchRadius)
        self.infoRereadPause = infoRereadPause
    }

    public func state(for uid: PhotoUID) -> ViewerTitleMetadataState {
        states[uid] ?? .resolving
    }

    public func prepare(items: [PhotoItem], around index: Int) {
        guard !items.isEmpty else {
            cancelAll()
            return
        }
        let boundedIndex = min(max(index, 0), items.count - 1)
        let lower = max(0, boundedIndex - prefetchRadius)
        let upper = min(items.count - 1, boundedIndex + prefetchRadius)
        let retained = Set(items[lower...upper].map(\.uid))

        for uid in tasks.keys where !retained.contains(uid) {
            tasks.removeValue(forKey: uid)?.task.cancel()
        }
        states = states.filter { retained.contains($0.key) }
        silentlyRereadForInfo.formIntersection(retained)
        for item in items[lower...upper] {
            beginResolutionIfNeeded(for: item)
        }
    }

    public func resolve(_ item: PhotoItem) async -> ViewerTitleMetadataResolution {
        beginResolutionIfNeeded(for: item)
        if let resolution = states[item.uid]?.resolution { return resolution }
        guard let entry = tasks[item.uid] else {
            return ViewerTitleMetadataResolution(metadata: nil, placeName: nil)
        }
        let resolution = await entry.task.value
        complete(resolution, for: item.uid, taskID: entry.id)
        return states[item.uid]?.resolution ?? resolution
    }

    /// The details that the Info shows for `item`. A failed read is repeated once after a short pause without a
    /// message, because the read changes nothing and a new attempt often succeeds. The repeat belongs to the Info and
    /// the shown photo: `resolve` and the prefetch of the neighbors never repeat a read, and a person's Try again
    /// reads once more without another silent repeat.
    ///
    /// `infoIsOpen` is asked when the first read ends and again when the pause ends, so a title read that fails
    /// while the Info is closed repeats only if the Info opens before it ends, and an Info that closes during the
    /// pause ends the repeat. An error that names a cause repeats only when the shared failure policy repeats that
    /// cause on its own; an error without a cause repeats once, and the failure stays visible after that.
    public func resolveForInfo(
        _ item: PhotoItem, infoIsOpen: @MainActor @Sendable () -> Bool = { true }
    ) async -> ViewerTitleMetadataResolution {
        let first = await resolve(item)
        guard !Task.isCancelled, first.metadataLoadFailed, Self.repeatsSilently(first), canRereadForInfo(item.uid),
            infoIsOpen()
        else { return first }
        await infoRereadPause(Self.infoRereadDelay)
        // The wait is over. The Info may have closed, the viewer may have left the photo, or the task may have ended.
        guard !Task.isCancelled, infoIsOpen(), canRereadForInfo(item.uid) else { return first }
        silentlyRereadForInfo.insert(item.uid)
        invalidate(item.uid)
        return await resolve(item)
    }

    /// Whether the Info still has its one silent repeat for `uid`: the read of the photo in the window failed and
    /// no Info has repeated it yet.
    public func canRereadForInfo(_ uid: PhotoUID) -> Bool {
        states[uid]?.resolution?.metadataLoadFailed == true && !silentlyRereadForInfo.contains(uid)
    }

    /// Whether an Info that opens now reads the details again: the photo's read failed and no Info repeated it yet.
    /// A read that still runs decides when it ends, and a failure that the Info already repeated stays as it is.
    public func shouldReadAgainWhenInfoOpens(_ uid: PhotoUID, metadataLoadState: PhotoMetadataLoadState) -> Bool {
        metadataLoadState == .failed && canRereadForInfo(uid)
    }

    private static func repeatsSilently(_ resolution: ViewerTitleMetadataResolution) -> Bool {
        guard let cause = resolution.failureCause else { return true }
        return FailurePolicy.resolve(cause, situation: .awaitedByPerson, safety: .safeRead).retry == .automatic
    }

    public func cancelAll() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll(keepingCapacity: false)
        states.removeAll(keepingCapacity: false)
        silentlyRereadForInfo.removeAll(keepingCapacity: false)
    }

    public func invalidate(_ uid: PhotoUID) {
        tasks.removeValue(forKey: uid)?.task.cancel()
        states[uid] = nil
    }

    private func beginResolutionIfNeeded(for item: PhotoItem) {
        guard states[item.uid] == nil else { return }
        states[item.uid] = .resolving
        guard let metadataProvider else {
            states[item.uid] = .resolved(.init(metadata: nil, placeName: nil))
            return
        }

        let placeNameResolver = self.placeNameResolver
        let task = Task<ViewerTitleMetadataResolution, Never> {
            let metadata: PhotoMetadata
            do {
                metadata = try await metadataProvider.metadata(for: item.uid)
            } catch {
                // A read that a cancelled sharer ended is no failure of the photo: it carries the cause that the
                // policy never repeats.
                let cause: FailureCause? =
                    FailureCancellation.isCancellation(error)
                    ? .cancelled : (error as? any FailureClassifiable)?.failureCause
                return .init(
                    metadata: nil, placeName: nil, metadataLoadFailed: !Task.isCancelled, failureCause: cause)
            }
            guard !Task.isCancelled else { return .init(metadata: nil, placeName: nil) }
            guard metadata.hasLocation,
                let latitude = metadata.latitude,
                let longitude = metadata.longitude,
                let placeNameResolver
            else { return .init(metadata: metadata, placeName: nil) }
            let placeName = await placeNameResolver.placeName(latitude: latitude, longitude: longitude)
            guard !Task.isCancelled else { return .init(metadata: nil, placeName: nil) }
            return .init(metadata: metadata, placeName: placeName)
        }
        let taskID = UUID()
        tasks[item.uid] = ResolutionTask(id: taskID, task: task)
        Task { [weak self] in
            let resolution = await task.value
            self?.complete(resolution, for: item.uid, taskID: taskID)
        }
    }

    private func complete(
        _ resolution: ViewerTitleMetadataResolution,
        for uid: PhotoUID,
        taskID: UUID
    ) {
        guard tasks[uid]?.id == taskID else { return }
        tasks[uid] = nil
        states[uid] = .resolved(resolution)
    }
}
