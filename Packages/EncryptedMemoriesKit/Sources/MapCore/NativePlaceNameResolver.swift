import Foundation
import MapKit
import PhotosCore

public actor NativePlaceNameResolver: PlaceNameResolving {
    public static let shared = NativePlaceNameResolver()

    private var cache: [String: String?] = [:]

    public func placeName(latitude: Double, longitude: Double) async -> String? {
        let key = Self.cacheKey(latitude, longitude)
        if let cached = cache[key] { return cached }
        let name = await Self.reverseGeocode(latitude: latitude, longitude: longitude)
        cache[key] = name
        return name
    }

    private var cityCache: [String: String?] = [:]

    /// City-level name for search suggestions ("Klosterneuburg", not a shop at that spot). The coordinate is
    /// rounded to about 1 km before the request, so Apple receives only a coarse cluster location.
    public func cityName(latitude: Double, longitude: Double) async -> String? {
        let roundedLatitude = (latitude * 100).rounded() / 100
        let roundedLongitude = (longitude * 100).rounded() / 100
        let key = Self.cacheKey(roundedLatitude, roundedLongitude)
        if let cached = cityCache[key] { return cached }
        let name = await Self.mapItems(latitude: roundedLatitude, longitude: roundedLongitude)
            .lazy.compactMap(Self.cityName).first
        cityCache[key] = name
        return name
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        await mapItems(latitude: latitude, longitude: longitude).lazy.compactMap(bestName).first
    }

    private static func mapItems(latitude: Double, longitude: Double) async -> [MKMapItem] {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
            let mapItems = try? await request.mapItems
        else { return [] }
        return mapItems
    }

    private static func cityName(_ item: MKMapItem) -> String? {
        let representations = item.addressRepresentations
        if let city = representations?.cityName, !city.isEmpty { return city }
        if let region = representations?.regionName, !region.isEmpty { return region }
        return nil
    }

    private static func bestName(_ item: MKMapItem) -> String? {
        let address = item.address
        let addressRepresentations = item.addressRepresentations
        if let name = item.name, !name.isEmpty {
            let isAddress = [address?.shortAddress, address?.fullAddress]
                .compactMap { $0 }
                .contains(name)
            if !isAddress { return name }
        }
        if let city = addressRepresentations?.cityName, !city.isEmpty { return city }
        if let city = addressRepresentations?.cityWithContext, !city.isEmpty { return city }
        if let region = addressRepresentations?.regionName, !region.isEmpty { return region }
        return address?.shortAddress ?? address?.fullAddress
    }

    private static func cacheKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
