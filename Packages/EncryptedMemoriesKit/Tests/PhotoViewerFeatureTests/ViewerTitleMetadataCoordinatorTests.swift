import PhotosCore
import XCTest

@testable import PhotoViewerCore

final class ViewerTitleMetadataCoordinatorTests: XCTestCase {
    func testOnlyKnownGPSReservesThePOIHeadline() {
        XCTAssertFalse(ViewerTitleMetadataState.resolving.shouldReservePlaceNameLine(hasKnownLocation: false))
        XCTAssertTrue(ViewerTitleMetadataState.resolving.shouldReservePlaceNameLine(hasKnownLocation: true))
        XCTAssertFalse(
            ViewerTitleMetadataState.resolved(.init(metadata: nil, placeName: nil))
                .shouldReservePlaceNameLine(hasKnownLocation: true)
        )
    }

    @MainActor
    func testPreparePrefetchesCurrentAndAdjacentTitles() async {
        let metadata = MetadataProvider()
        let places = PlaceResolver()
        let items = (0..<5).map { index in
            PhotoItem(
                uid: PhotoUID(volumeID: "v", nodeID: "n\(index)"),
                captureTime: Date(timeIntervalSince1970: TimeInterval(index)),
                mediaType: "image/jpeg"
            )
        }
        let coordinator = ViewerTitleMetadataCoordinator(
            metadataProvider: metadata,
            placeNameResolver: places,
            prefetchRadius: 1
        )

        coordinator.prepare(items: items, around: 2)
        let previous = await coordinator.resolve(items[1])
        let current = await coordinator.resolve(items[2])
        let next = await coordinator.resolve(items[3])

        XCTAssertEqual(previous.placeName, "48.1,16.2")
        XCTAssertEqual(current.placeName, "48.2,16.2")
        XCTAssertEqual(next.placeName, "48.3,16.2")
        let requestedNodeIDs = await metadata.requestedNodeIDs()
        XCTAssertEqual(requestedNodeIDs, Set(["n1", "n2", "n3"]))
    }
}

private actor MetadataProvider: PhotoMetadataProvider {
    private var requested = Set<String>()

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        requested.insert(uid.nodeID)
        let suffix = Double(uid.nodeID.dropFirst()) ?? 0
        return PhotoMetadata(latitude: 48 + suffix / 10, longitude: 16.2)
    }

    func requestedNodeIDs() -> Set<String> { requested }
}

private actor PlaceResolver: PlaceNameResolving {
    func placeName(latitude: Double, longitude: Double) async -> String? {
        String(format: "%.1f,%.1f", latitude, longitude)
    }
}
