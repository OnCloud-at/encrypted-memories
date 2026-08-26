import Foundation

/// Stable, world-anchored identity of one map aggregation cell. Latitude uses a power-of-two degree
/// step. Longitude uses the exponent of a power-of-two world partition so the grid closes exactly at
/// the antimeridian and every coarser cell has exactly two children.
public struct PhotoLocationCellID: Hashable, Sendable, Equatable {
    public let latitudeStepExponent: Int
    public let longitudeCellCountExponent: Int
    public let latitudeIndex: Int
    public let longitudeIndex: Int

    public init(
        latitudeStepExponent: Int,
        longitudeCellCountExponent: Int,
        latitudeIndex: Int,
        longitudeIndex: Int
    ) {
        self.latitudeStepExponent = latitudeStepExponent
        self.longitudeCellCountExponent = longitudeCellCountExponent
        self.latitudeIndex = latitudeIndex
        self.longitudeIndex = longitudeIndex
    }
}

/// A group of photos that share a map cell, presented to MapKit as a single pin.
///
/// `PhotoLocationAggregation` bins all coordinates that fall inside the same grid cell of the visible
/// map rect into one `AggregatedCoordinate`. Each becomes one `MKAnnotation`, so MKMapView never has to
/// manage thousands of individual pin views: a dense 3k-photo neighborhood collapses to a handful of
/// cells, each carrying the true count of photos it represents. These are final display cells: native
/// map hosts must not apply a second clustering or collision-hiding authority.
public struct AggregatedCoordinate: Sendable, Equatable {
    /// Stable spatial identity, separate from the thumbnail hero. Membership may grow while this ID
    /// remains unchanged as location crawl batches arrive.
    public let cellID: PhotoLocationCellID
    /// All photos represented by this cell. Used to drive the cluster-series screen (lists every
    /// underlying photo, not just the cell's hero) and to keep cluster counts honest.
    public let memberUIDs: [PhotoUID]
    /// The stable world-grid center shown on the map. Using the center rather than an arbitrary member
    /// centroid preserves the unpitched viewport policy's target spacing.
    public let latitude: Double
    public let longitude: Double
    /// The hero photo whose thumbnail decorates this cell. Newest member wins so the cell stays
    /// visually anchored to the most recent visit as the crawl fills the index in.
    public let uid: PhotoUID

    public var count: Int { memberUIDs.count }

    public init(
        cellID: PhotoLocationCellID,
        memberUIDs: [PhotoUID],
        latitude: Double,
        longitude: Double,
        uid: PhotoUID
    ) {
        self.cellID = cellID
        self.memberUIDs = memberUIDs
        self.latitude = latitude
        self.longitude = longitude
        self.uid = uid
    }
}
