import Foundation
import XCTest

@testable import PhotosCore

final class MapAndPlacesPolicyTests: XCTestCase {
    func testDefaultAllowsMapAndPlacesAndExplicitOffBlocksThem() throws {
        let suite = "MapAndPlacesPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(MapAndPlacesPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AppSettingsKey.mapAndPlacesEnabled)
        XCTAssertFalse(MapAndPlacesPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AppSettingsKey.mapAndPlacesEnabled)
        XCTAssertTrue(MapAndPlacesPolicy.isEnabled(defaults: defaults))
    }

    func testDisablingPlacesRemovesOnlyCoordinatesFromSuggestions() {
        let coordinates = [
            PhotoCoordinate(uid: PhotoUID(volumeID: "v", nodeID: "p"), latitude: 48, longitude: 16, date: .now)
        ]
        XCTAssertEqual(MapAndPlacesPolicy.suggestionCoordinates(coordinates, enabled: true), coordinates)
        XCTAssertEqual(MapAndPlacesPolicy.suggestionCoordinates(coordinates, enabled: false), [])
    }

    func testCrawlRequiresMapEnabledAndPhotosToInspect() {
        XCTAssertTrue(MapAndPlacesPolicy.allowsLocationCrawl(enabled: true, itemCount: 1))
        XCTAssertFalse(MapAndPlacesPolicy.allowsLocationCrawl(enabled: false, itemCount: 1))
        XCTAssertFalse(MapAndPlacesPolicy.allowsLocationCrawl(enabled: true, itemCount: 0))
    }
}
