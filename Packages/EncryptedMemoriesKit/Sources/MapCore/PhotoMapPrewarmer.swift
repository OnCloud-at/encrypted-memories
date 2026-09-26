import Foundation
import MapKit
import PhotosCore
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Loads the map area that the library map opens at into MapKit's tile cache, once per launch, so the map draws at
/// once instead of showing its pins over an empty grey grid while the tiles arrive.
///
/// MapKit shares its tile cache between snapshots and map views and keeps it across launches. Measured on a Mac with
/// areas that were never shown: 1.1 to 3.0 s until an `MKMapView` drew them completely, 0.08 to 0.11 s after a
/// snapshot of the same area. The cost is one small snapshot; no map view stays loaded.
@MainActor
public final class PhotoMapPrewarmer {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "Map")
    private var snapshotter: MKMapSnapshotter?
    private var prewarmedRect: MKMapRect?

    public init() {}

    /// `viewportSize` approximates the map view, so the snapshot loads the same zoom level.
    public func prewarm(coordinates: [PhotoCoordinate], viewportSize: CGSize) {
        guard snapshotter == nil,
            let rect = PhotoMapAnnotationLoader.denseCoreMapRect(for: coordinates),
            let visible = Self.visibleMapRect(framing: rect, in: viewportSize),
            !(prewarmedRect.map { MKMapRectEqualToRect($0, visible) } ?? false)
        else { return }
        let options = MKMapSnapshotter.Options()
        options.mapRect = visible
        options.size = viewportSize
        options.pointOfInterestFilter = .excludingAll
        #if canImport(UIKit)
            options.traitCollection = UITraitCollection(userInterfaceStyle: Self.currentInterfaceStyle())
        #else
            options.appearance = NSApp.effectiveAppearance
        #endif
        let snapshotter = MKMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        let start = Date()
        snapshotter.start { [weak self] _, error in
            let seconds = Date().timeIntervalSince(start)
            Self.logger.notice(
                "[Map] prewarm seconds=\(seconds, format: .fixed(precision: 2), privacy: .public) ok=\(error == nil, privacy: .public)"
            )
            Task { @MainActor in
                self?.snapshotter = nil
                if error == nil { self?.prewarmedRect = visible }
            }
        }
    }

    /// The area an `MKMapView` of `size` shows after framing `rect` with the loader's padding: the rect scaled to fit
    /// inside the padded view, centred.
    nonisolated static func visibleMapRect(framing rect: MKMapRect, in size: CGSize) -> MKMapRect? {
        let padding = Double(PhotoMapAnnotationLoader.framingPadding) * 2
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > padding, height > padding, rect.size.width > 0 || rect.size.height > 0 else { return nil }
        let pointsPerScreenPoint = max(rect.size.width / (width - padding), rect.size.height / (height - padding))
        let visibleWidth = width * pointsPerScreenPoint
        let visibleHeight = height * pointsPerScreenPoint
        return MKMapRect(
            x: rect.midX - visibleWidth / 2, y: rect.midY - visibleHeight / 2,
            width: visibleWidth, height: visibleHeight)
    }

    #if canImport(UIKit)
        private static func currentInterfaceStyle() -> UIUserInterfaceStyle {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.traitCollection.userInterfaceStyle ?? .unspecified
        }
    #endif
}
