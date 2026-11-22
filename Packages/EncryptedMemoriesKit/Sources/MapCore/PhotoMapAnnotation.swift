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

    /// What a tap on the pin opens.
    public enum Selection: Equatable {
        /// The photo itself: the cell holds exactly one photo.
        case photo(PhotoUID)
        /// The list of every photo of the cell, with the cell's coordinate.
        case cluster([PhotoUID], CLLocationCoordinate2D)

        public static func == (lhs: Selection, rhs: Selection) -> Bool {
            switch (lhs, rhs) {
            case (.photo(let a), .photo(let b)): a == b
            case (.cluster(let a, let ac), .cluster(let b, let bc)):
                a == b && ac.latitude == bc.latitude && ac.longitude == bc.longitude
            default: false
            }
        }
    }

    public var selection: Selection {
        memberUIDs.count == 1 ? .photo(uid) : .cluster(memberUIDs, coordinate)
    }

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
