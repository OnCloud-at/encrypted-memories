#if canImport(UIKit)
    import MapKit
    import MapCore
    import MediaLocationCore
    import PhotosCore
    import UIKit

    @MainActor
    public final class UIKitLibraryMapHostView: UIView {
        private let mapView = MKMapView()
        private let index: PhotoLocationIndex
        private var thumbnail: (PhotoUID) -> UIImage?
        private var loadThumbnail: (PhotoUID) async -> UIImage?
        private var onSelectPhoto: (PhotoUID) -> Void
        private var onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)?
        /// In-flight async thumbnail loads. The loader tells us (via its `onRemoved` callback) which to cancel when
        /// their annotations leave the viewport - otherwise every pinch-zoom in a dense region leaves orphan tasks
        /// racing to set thumbnails on recycled views.
        private let thumbnailLoads = MapThumbnailLoads<UIImage>()
        private var lastMapBoundsSize = CGSize.zero
        /// Shared engine (MapCore): framing, off-main aggregation, diff, generation guard, add/remove.
        private var loader: PhotoMapAnnotationLoader!

        public init(
            index: PhotoLocationIndex,
            visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy,
            thumbnail: @escaping (PhotoUID) -> UIImage?,
            loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
            onSelectPhoto: @escaping (PhotoUID) -> Void,
            onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)? = nil
        ) {
            self.index = index
            self.thumbnail = thumbnail
            self.loadThumbnail = loadThumbnail
            self.onSelectPhoto = onSelectPhoto
            self.onSelectCluster = onSelectCluster
            super.init(frame: .zero)
            self.loader = PhotoMapAnnotationLoader(
                index: index,
                policy: visibleCoordinatePolicy,
                onRemoved: { [weak self] uids in
                    guard let self else { return }
                    self.thumbnailLoads.cancel(uids)
                }
            )
            configureMap()
            // The loader computes the dense-core frame off-main, then loads its first pins.
            // The index warms the shared coordinate evidence before the map opens.
            loader.attach(mapView)
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            let size = mapView.bounds.size
            guard size != lastMapBoundsSize else { return }
            lastMapBoundsSize = size
            loader.reloadVisible()
        }

        public func configure(
            thumbnail: @escaping (PhotoUID) -> UIImage?,
            loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
            onSelectPhoto: @escaping (PhotoUID) -> Void,
            onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)? = nil
        ) {
            self.thumbnail = thumbnail
            self.loadThumbnail = loadThumbnail
            self.onSelectPhoto = onSelectPhoto
            self.onSelectCluster = onSelectCluster
            // Only update the stored closures. Do not force a full re-query/re-aggregate here: SwiftUI calls
            // this on every `updateUIView` (each state change re-passes value-identical closures), and the
            // aggregate over thousands of coordinates is expensive on the main thread. Content changes flow through
            // `refreshIfChanged` (revision-gated) and map moves through `regionDidChangeAnimated`; a newly
            // available thumbnail closure is picked up lazily by the next `viewFor`/thumbnail request.
        }

        public func refreshIfChanged() {
            loader.refreshIfChanged(revision: index.revision)
        }

        private func configureMap() {
            mapView.delegate = self
            mapView.showsUserLocation = false
            mapView.isPitchEnabled = false
            mapView.pointOfInterestFilter = .excludingAll
            mapView.register(
                UIKitPhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: UIKitPhotoAnnotationView.reuseID)

            mapView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mapView)
            NSLayoutConstraint.activate([
                mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
                mapView.topAnchor.constraint(equalTo: topAnchor),
                mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    extension UIKitLibraryMapHostView: MKMapViewDelegate {
        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            loader.reloadVisible()
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view =
                mapView.dequeueReusableAnnotationView(
                    withIdentifier: UIKitPhotoAnnotationView.reuseID,
                    for: annotation
                ) as! UIKitPhotoAnnotationView
            let image = thumbnail(photo.uid)
            view.setThumbnail(image)
            // A single cell can aggregate many photos (the 80 m floor merges a same-place burst); show its
            // true count so a 30-photo pin doesn't masquerade as a single picture.
            view.setCount(photo.memberCount)
            if image == nil {
                requestThumbnailIfNeeded(photo.uid)
            }
            return view
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photo = view.annotation as? PhotoMapAnnotation {
                switch photo.selection {
                case .photo(let uid):
                    onSelectPhoto(uid)
                case .cluster(let uids, let coordinate):
                    // Without a cluster handler the hero photo opens.
                    if let handler = onSelectCluster {
                        handler(uids, coordinate)
                    } else {
                        onSelectPhoto(photo.uid)
                    }
                }
                mapView.deselectAnnotation(view.annotation, animated: false)
            }
        }

        private func requestThumbnailIfNeeded(_ uid: PhotoUID) {
            // The resident case is answered by the sync `thumbnail()` check in `viewFor`; the loads skip a photo whose
            // load still runs.
            thumbnailLoads.requestIfNeeded(uid, load: loadThumbnail) { [weak self] image, uid in
                self?.applyLoadedThumbnail(image, for: uid)
            }
        }

        private func applyLoadedThumbnail(_ image: UIImage, for uid: PhotoUID) {
            // Single-shot lookup via the loader - O(1) instead of scanning all annotations.
            if let annotation = loader.annotation(for: uid),
                let view = mapView.view(for: annotation) as? UIKitPhotoAnnotationView
            {
                view.setThumbnail(image)
            }
        }
    }
#endif
