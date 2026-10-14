import PhotosCore

/// Presentation of the stored location and the place name already resolved by the viewer.
public struct ViewerInfoLocation {
    public let placeName: String?
    public let markerTitle: String
    public let coordinateText: String?
    public let showsMap: Bool
    /// Whether the location section has anything to show: a usable place name or the stored coordinates.
    public var hasContent: Bool { placeName != nil || coordinateText != nil }

    public init(metadata: PhotoMetadata?, placeName: String?, mapAndPlacesEnabled: Bool) {
        let trimmed = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.placeName = mapAndPlacesEnabled ? (trimmed?.isEmpty == false ? placeName : nil) : nil
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
