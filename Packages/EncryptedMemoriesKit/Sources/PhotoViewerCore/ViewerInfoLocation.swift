import PhotosCore

/// Presentation of the stored location and the place name already resolved by the viewer.
public struct ViewerInfoLocation {
    public let placeName: String?
    public let markerTitle: String
    public let coordinateText: String?
    public let showsMap: Bool

    public init(metadata: PhotoMetadata?, placeName: String?, mapAndPlacesEnabled: Bool) {
        self.placeName = mapAndPlacesEnabled ? placeName.flatMap { $0.isEmpty ? nil : $0 } : nil
        markerTitle = self.placeName ?? L10n.string("map.cluster_title")
        if let latitude = metadata?.latitude, let longitude = metadata?.longitude {
            coordinateText = PhotoCoordinateText.format(latitude: latitude, longitude: longitude)
            showsMap = mapAndPlacesEnabled
        } else {
            coordinateText = nil
            showsMap = false
        }
    }
}
