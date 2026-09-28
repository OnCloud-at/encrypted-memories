import Foundation
import MapKit
import PhotosCore

public actor NativePlaceNameResolver: PlaceNameResolving {
    public static let shared = NativePlaceNameResolver()

    private let defaults: UserDefaults
    private var activeRequests: [UUID: MKReverseGeocodingRequest] = [:]
    private(set) var requestGeneration: UInt64 = 0
    private(set) var startedRequestCount = 0
    private var cache: [String: String?] = [:]

    public init(defaultsSuiteName: String? = nil) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func cancelPending() {
        guard !MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return }
        requestGeneration &+= 1
        for request in activeRequests.values { request.cancel() }
        activeRequests.removeAll()
    }

    public func placeName(latitude: Double, longitude: Double) async -> String? {
        guard MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return nil }
        let key = Self.cacheKey(latitude, longitude)
        if let cached = cache[key] { return cached }
        let generation = requestGeneration
        let name = await reverseGeocode(latitude: latitude, longitude: longitude)
        guard generation == requestGeneration, MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return nil }
        cache[key] = name
        return name
    }

    private var cityCache: [String: String?] = [:]

    /// City-level name for search suggestions ("Klosterneuburg", not a shop at that spot). The coordinate is
    /// rounded to about 1 km before the request, so Apple receives only a coarse cluster location.
    public func cityName(latitude: Double, longitude: Double) async -> String? {
        guard MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return nil }
        let roundedLatitude = (latitude * 100).rounded() / 100
        let roundedLongitude = (longitude * 100).rounded() / 100
        let key = Self.cacheKey(roundedLatitude, roundedLongitude)
        if let cached = cityCache[key] { return cached }
        let generation = requestGeneration
        let name = await mapItems(latitude: roundedLatitude, longitude: roundedLongitude)
            .lazy.compactMap(Self.cityName).first
        guard generation == requestGeneration, MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return nil }
        cityCache[key] = name
        return name
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        await mapItems(latitude: latitude, longitude: longitude).lazy.compactMap(Self.bestName).first
    }

    private func mapItems(latitude: Double, longitude: Double) async -> [MKMapItem] {
        guard MapAndPlacesPolicy.isEnabled(defaults: defaults) else { return [] }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return [] }
        startedRequestCount += 1
        let id = UUID()
        activeRequests[id] = request
        defer { activeRequests[id] = nil }
        let items = (try? await request.mapItems) ?? []
        return MapAndPlacesPolicy.isEnabled(defaults: defaults) ? items : []
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
