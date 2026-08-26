import AppKit
import MapCore
import MapKit
import MediaLocationCore
import PhotosCore
import SwiftUI

/// The library map: a native MapKit map (Apple tiles, no API key) with clustered photo badges over the
/// shared, encrypted `PhotoLocationIndex`.
///
/// Only the final Core display cells in the visible map rect (+ margin) are placed, so even a large library
/// remains bounded while every represented UID stays in exactly one visible count. Annotations refresh as
/// the background GPS crawl fills the index (the `revision` binding).
public struct LibraryMapView: NSViewRepresentable {
    private let index: PhotoLocationIndex
    private let thumbnail: (PhotoUID) -> NSImage?
    private let loadThumbnail: (PhotoUID) async -> NSImage?
    private let onSelectPhoto: (PhotoUID) -> Void
    private let onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void

    public init(
        index: PhotoLocationIndex,
        thumbnail: @escaping (PhotoUID) -> NSImage?,
        loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
        onSelectPhoto: @escaping (PhotoUID) -> Void,
        onSelectCluster: @escaping ([PhotoUID], CLLocationCoordinate2D) -> Void = { _, _ in }
    ) {
        self.index = index
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
        self.onSelectCluster = onSelectCluster
    }

    public func makeNSView(context: Context) -> MKMapView {
        let map = ResizeAwareMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.register(PhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.reuseID)
        context.coordinator.attach(map)
        return map
    }

    public func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.thumbnail = thumbnail
        context.coordinator.loadThumbnail = loadThumbnail
        context.coordinator.onSelectPhoto = onSelectPhoto
        context.coordinator.onSelectCluster = onSelectCluster
        context.coordinator.refreshIfChanged(revision: index.revision)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            index: index, thumbnail: thumbnail, loadThumbnail: loadThumbnail,
            onSelectPhoto: onSelectPhoto, onSelectCluster: onSelectCluster)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        var thumbnail: (PhotoUID) -> NSImage?
        var loadThumbnail: (PhotoUID) async -> NSImage?
        var onSelectPhoto: (PhotoUID) -> Void
        var onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void
        private weak var map: MKMapView?
        private var thumbnailLoadTasks: [PhotoUID: Task<Void, Never>] = [:]
        /// Shared engine (MapCore): framing, off-main aggregation, diff, generation guard, add/remove.
        private var loader: PhotoMapAnnotationLoader!

        init(
            index: PhotoLocationIndex,
            thumbnail: @escaping (PhotoUID) -> NSImage?,
            loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
            onSelectPhoto: @escaping (PhotoUID) -> Void,
            onSelectCluster: @escaping ([PhotoUID], CLLocationCoordinate2D) -> Void
        ) {
            self.thumbnail = thumbnail
            self.loadThumbnail = loadThumbnail
            self.onSelectPhoto = onSelectPhoto
            self.onSelectCluster = onSelectCluster
            super.init()
            self.loader = PhotoMapAnnotationLoader(
                index: index,
                policy: .standard,
                onRemoved: { [weak self] uids in
                    guard let self else { return }
                    for uid in uids { self.thumbnailLoadTasks.removeValue(forKey: uid)?.cancel() }
                }
            )
        }

        deinit {
            for (_, task) in thumbnailLoadTasks { task.cancel() }
        }

        func attach(_ map: MKMapView) {
            self.map = map
            (map as? ResizeAwareMapView)?.onBoundsSizeChange = { [weak self] in
                self?.loader.reloadVisible()
            }
            loader.attach(map)
        }

        func refreshIfChanged(revision: Int) {
            loader.refreshIfChanged(revision: revision)
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !mapView.inLiveResize else { return }
            loader.reloadVisible()
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view =
                mapView.dequeueReusableAnnotationView(withIdentifier: PhotoAnnotationView.reuseID, for: annotation)
                as! PhotoAnnotationView
            let image = thumbnail(photo.uid)
            view.setThumbnail(image)
            // A single cell can aggregate many photos (the minCellMeters floor merges a same-place
            // burst); show its true count so a multi-photo pin doesn't masquerade as a single picture.
            view.setCount(photo.memberCount)
            if image == nil {
                requestThumbnailIfNeeded(photo.uid)
            }
            return view
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photo = view.annotation as? PhotoMapAnnotation {
                if photo.memberUIDs.count == 1 {
                    onSelectPhoto(photo.uid)
                } else {
                    onSelectCluster(photo.memberUIDs, photo.coordinate)
                }
                mapView.deselectAnnotation(view.annotation, animated: false)
            }
        }

        private func requestThumbnailIfNeeded(_ uid: PhotoUID) {
            guard thumbnailLoadTasks[uid] == nil else { return }
            let loadThumbnail = loadThumbnail
            thumbnailLoadTasks[uid] = Task { @MainActor [weak self] in
                let image = await loadThumbnail(uid)
                guard let self else { return }
                self.thumbnailLoadTasks.removeValue(forKey: uid)
                if Task.isCancelled { return }
                guard let image else { return }
                self.applyLoadedThumbnail(image, for: uid)
            }
        }

        private func applyLoadedThumbnail(_ image: NSImage, for uid: PhotoUID) {
            guard let map else { return }

            if let annotation = loader.annotation(for: uid),
                let view = map.view(for: annotation) as? PhotoAnnotationView
            {
                view.setThumbnail(image)
            }
        }
    }
}

/// MKMapView does not promise a region callback for every split-view/window resize. This narrow AppKit host
/// reports point-size changes to the shared loader so its horizontal/vertical cell budgets remain accurate.
@MainActor
private final class ResizeAwareMapView: MKMapView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastBoundsSize = CGSize.zero

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastBoundsSize else { return }
        lastBoundsSize = size
        guard !inLiveResize else { return }
        onBoundsSizeChange?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        lastBoundsSize = bounds.size
        onBoundsSizeChange?()
    }
}
