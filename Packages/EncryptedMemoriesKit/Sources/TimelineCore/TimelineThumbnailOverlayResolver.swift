import Foundation
import GridCore
import PhotosCore

/// Supplies metadata that the lightweight timeline enumeration cannot carry.
///
/// Resolves encrypted video duration only for a settled, resident viewport. Concurrency stays bounded so metadata
/// requests cannot compete with thumbnail delivery during scrolling.
@MainActor
package final class TimelineThumbnailOverlayResolver {
    package var onChange: (() -> Void)?

    private var overlays: [PhotoUID: GridThumbnailOverlay] = [:]
    private var videoUIDs = Set<PhotoUID>()
    private var attempted = Set<PhotoUID>()
    private var latestVisible: [PhotoUID] = []
    private var settleTask: Task<Void, Never>?
    private var pending: [PhotoUID] = []
    private var pendingSet = Set<PhotoUID>()
    private var inFlight = Set<PhotoUID>()
    private let settleDelay: Duration
    private let maxConcurrentLoads: Int

    package init(
        items: [PhotoItem],
        settleDelay: Duration = .milliseconds(150),
        maxConcurrentLoads: Int = 2
    ) {
        self.settleDelay = settleDelay
        self.maxConcurrentLoads = max(1, maxConcurrentLoads)
        update(items: items)
    }

    package func update(items: [PhotoItem]) {
        let previous = overlays
        var next: [PhotoUID: GridThumbnailOverlay] = [:]
        next.reserveCapacity(items.count)
        var nextVideos = Set<PhotoUID>()
        for item in items {
            var overlay = TimelineThumbnailOverlayPolicy.overlay(for: item)
            if overlay.durationText == nil {
                overlay.durationText = previous[item.uid]?.durationText
            }
            next[item.uid] = overlay
            if item.isVideo { nextVideos.insert(item.uid) }
        }
        overlays = next
        videoUIDs = nextVideos
        attempted.formIntersection(nextVideos)
        pending.removeAll { !nextVideos.contains($0) }
        pendingSet = Set(pending)
        latestVisible = []
        settleTask?.cancel()
        settleTask = nil
    }

    package func overlay(for uid: PhotoUID) -> GridThumbnailOverlay {
        overlays[uid] ?? .empty
    }

    /// Debounces changes to the resident viewport without cancelling metadata already in flight.
    package func noteVisible(
        _ uids: [PhotoUID],
        metadataProvider: any PhotoMetadataProvider
    ) {
        var seen = Set<PhotoUID>()
        let unresolved = uids.filter { uid in
            seen.insert(uid).inserted
                && videoUIDs.contains(uid)
                && overlays[uid]?.durationText == nil
                && !attempted.contains(uid)
        }
        guard unresolved != latestVisible else { return }
        latestVisible = unresolved
        settleTask?.cancel()
        settleTask = nil
        guard !unresolved.isEmpty else { return }

        let delay = settleDelay
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.latestVisible == unresolved else { return }
            self.settleTask = nil
            self.enqueue(unresolved, metadataProvider: metadataProvider)
        }
    }

    private func enqueue(
        _ uids: [PhotoUID],
        metadataProvider: any PhotoMetadataProvider
    ) {
        for uid in uids where attempted.insert(uid).inserted {
            guard pendingSet.insert(uid).inserted else { continue }
            pending.append(uid)
        }
        pump(metadataProvider: metadataProvider)
    }

    private func pump(metadataProvider: any PhotoMetadataProvider) {
        while inFlight.count < maxConcurrentLoads, !pending.isEmpty {
            let uid = pending.removeFirst()
            pendingSet.remove(uid)
            guard videoUIDs.contains(uid), overlays[uid]?.durationText == nil else { continue }
            inFlight.insert(uid)
            Task { @MainActor [weak self] in
                let duration = try? await metadataProvider.metadata(for: uid).durationSeconds
                guard let self else { return }
                self.complete(uid: uid, duration: duration, metadataProvider: metadataProvider)
            }
        }
    }

    private func complete(
        uid: PhotoUID,
        duration: Double?,
        metadataProvider: any PhotoMetadataProvider
    ) {
        inFlight.remove(uid)
        if videoUIDs.contains(uid),
            let text = TimelineThumbnailOverlayPolicy.durationText(for: duration),
            overlays[uid]?.durationText != text
        {
            overlays[uid]?.durationText = text
            onChange?()
        }
        pump(metadataProvider: metadataProvider)
    }
}
