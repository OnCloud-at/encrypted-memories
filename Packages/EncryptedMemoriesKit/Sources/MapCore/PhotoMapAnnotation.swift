import Foundation
import MapKit
import PhotosCore

/// One map pin backed by an `AggregatedCoordinate` - a grid cell that may represent several photos.
///
/// Shared by the macOS (`MapFeature`) and iOS/iPadOS (`MapUIKitAdapter`) map UIs because
/// `MKAnnotation`/`CLLocationCoordinate2D` are identical on both platforms. There is no per-platform
/// flavor of this type; only the annotation VIEWS differ (AppKit vs UIKit).
///
/// This is already a final, point-budgeted Core cell. Native hosts render it as a required annotation and
/// never ask MapKit to regroup or declutter it, so its complete member count cannot disappear.
final public class PhotoMapAnnotation: NSObject, MKAnnotation {
    /// Spatial identity remains stable while crawl batches add older members to this cell.
    public let cellID: PhotoLocationCellID
    /// Hero photo of the cell - the one whose thumbnail decorates the pin.
    public let uid: PhotoUID
    /// Every photo collapsed into this cell. Used to drive the cluster-series screen (lists every
    /// underlying photo, not just the hero) and to keep cluster counts honest.
    public let memberUIDs: [PhotoUID]
    /// The number of photos in this final display cell. Equal to `memberUIDs.count`.
    public let memberCount: Int
    public let coordinate: CLLocationCoordinate2D

    public init(_ aggregated: AggregatedCoordinate) {
        self.cellID = aggregated.cellID
        self.uid = aggregated.uid
        self.memberUIDs = aggregated.memberUIDs
        self.memberCount = aggregated.count
        self.coordinate = CLLocationCoordinate2D(
            latitude: aggregated.latitude,
            longitude: aggregated.longitude
        )
    }
}
