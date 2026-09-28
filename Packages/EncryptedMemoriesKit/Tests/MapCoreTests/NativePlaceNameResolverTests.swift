import Foundation
import PhotosCore
import Testing

@testable import MapCore

@Suite("Place lookup privacy")
struct NativePlaceNameResolverTests {
    @Test func disabledLookupReturnsWithoutStartingARequest() async throws {
        let suite = "NativePlaceNameResolverTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppSettingsKey.mapAndPlacesEnabled)
        let resolver = NativePlaceNameResolver(defaultsSuiteName: suite)

        #expect(await resolver.placeName(latitude: 48, longitude: 16) == nil)
        #expect(await resolver.cityName(latitude: 48, longitude: 16) == nil)
        #expect(await resolver.startedRequestCount == 0)

        await resolver.cancelPending()
        #expect(await resolver.requestGeneration == 1)
        defaults.set(true, forKey: AppSettingsKey.mapAndPlacesEnabled)
        await resolver.cancelPending()
        #expect(await resolver.requestGeneration == 1, "a late stop must not cancel requests after re-enabling")
    }
}
