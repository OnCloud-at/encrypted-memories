import CoreGraphics
import PhotosCore

@testable import TimelineFeature

/// A grid data source with no ready images and no warming work.
@MainActor
final class StubMetalGridDataSource: MetalGridDataSource {
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?

    init(uids: [PhotoUID]) {
        sectionCounts = [uids.count]
        flatUIDs = uids
    }

    init(sections: [Int], volumeID: String = "v") {
        sectionCounts = sections
        flatUIDs = (0..<sections.reduce(0, +)).map { PhotoUID(volumeID: volumeID, nodeID: "\($0)") }
    }

    convenience init(count: Int, volumeID: String = "v") {
        self.init(uids: (0..<count).map { PhotoUID(volumeID: volumeID, nodeID: "\($0)") })
    }

    func image(for uid: PhotoUID) -> CGImage? { nil }
    func warm(_ requests: [ThumbnailRequest]) {}
    func hasImage(for uid: PhotoUID) -> Bool { false }
}
