import PhotoViewerCore
import PhotosCore
import XCTest

final class ViewerInfoLocationTests: XCTestCase {
    private let metadata = PhotoMetadata(latitude: 48.3, longitude: 14.2)

    func testKnownLocationShowsTheResolvedNameMapAndStoredCoordinates() {
        let location = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: true)
        XCTAssertEqual(location.placeName, "Known place")
        XCTAssertEqual(location.markerTitle, "Known place")
        XCTAssertTrue(location.showsMap)
        XCTAssertEqual(location.coordinateText, PhotoCoordinateText.format(latitude: 48.3, longitude: 14.2))
    }

    func testKnownLocationWithoutANameStillShowsMapAndCoordinates() {
        for name: String? in [nil, ""] {
            let location = ViewerInfoLocation(metadata: metadata, placeName: name, mapAndPlacesEnabled: true)
            XCTAssertNil(location.placeName)
            XCTAssertTrue(location.showsMap)
            XCTAssertNotNil(location.coordinateText)
        }
    }

    func testNoLocationShowsNeitherMapNorCoordinates() {
        let location = ViewerInfoLocation(metadata: PhotoMetadata(), placeName: nil, mapAndPlacesEnabled: true)
        XCTAssertNil(location.placeName)
        XCTAssertFalse(location.showsMap)
        XCTAssertNil(location.coordinateText)
    }

    func testMapAndPlacesOffKeepsOnlyStoredCoordinates() {
        let location = ViewerInfoLocation(metadata: metadata, placeName: "Known place", mapAndPlacesEnabled: false)
        XCTAssertNil(location.placeName)
        XCTAssertFalse(location.showsMap)
        XCTAssertEqual(location.coordinateText, PhotoCoordinateText.format(latitude: 48.3, longitude: 14.2))
    }
}
