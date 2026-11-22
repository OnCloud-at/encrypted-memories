import Foundation
import PhotosCore
import Testing

@testable import MapCore

@Suite struct PhotoMapSelectionTests {
    private func annotation(members: [String], hero: String) -> PhotoMapAnnotation {
        let uid = { PhotoUID(volumeID: "v", nodeID: $0) }
        return PhotoMapAnnotation(
            AggregatedCoordinate(
                cellID: PhotoLocationCellID(
                    latitudeStepExponent: -2, longitudeCellCountExponent: 10, latitudeIndex: 10, longitudeIndex: 20),
                memberUIDs: members.map(uid), latitude: 47, longitude: 13, uid: uid(hero)))
    }

    @Test func aCellOfOnePhotoOpensThatPhoto() {
        let pin = annotation(members: ["a"], hero: "a")

        #expect(pin.selection == .photo(PhotoUID(volumeID: "v", nodeID: "a")))
    }

    @Test func aCellOfSeveralPhotosOpensTheClusterWithEveryMemberAndItsCoordinate() {
        let pin = annotation(members: ["a", "b", "c"], hero: "b")

        guard case .cluster(let members, let coordinate) = pin.selection else {
            Issue.record("a cell of three photos must open the cluster")
            return
        }
        #expect(members == ["a", "b", "c"].map { PhotoUID(volumeID: "v", nodeID: $0) })
        #expect(coordinate.latitude == pin.coordinate.latitude && coordinate.longitude == pin.coordinate.longitude)
    }
}
