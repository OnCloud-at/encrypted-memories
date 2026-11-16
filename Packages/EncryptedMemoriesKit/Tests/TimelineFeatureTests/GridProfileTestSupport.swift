import CoreGraphics
import GridCore
import TimelineCore

@testable import TimelineFeature

extension GridLevelProfile {
    static var testRegularTimeline: GridLevelProfile {
        TimelineGridProfileConfiguration.production.profile(id: "regularTimeline")!
    }

    static var testCompactTimeline: GridLevelProfile {
        TimelineGridProfileConfiguration.production.profile(id: "compactTimeline")!
    }
}

extension SquareTileGridEngine {
    /// The width at which the exact-fill slot side of a level, less half a point, rounds to the nominal column
    /// count of the level.
    static let testReferenceWidth: CGFloat = 1280

    static var testRegularLevels: [GridLevelMetrics] { GridLevelProfile.testRegularTimeline.levels }

    static func testRegular(sectionCounts: [Int]) -> SquareTileGridEngine {
        SquareTileGridEngine(sectionCounts: sectionCounts, profile: .testRegularTimeline)
    }
}

extension GridZoomCommitDelta {
    /// Horizontal shift in whole columns, rounded; this is the dominant component of the phase seam.
    func anchorColumnShift(pitch: CGFloat) -> Int {
        pitch > 0 ? Int((anchorDelta.width / pitch).rounded()) : 0
    }
}

extension MetalGridCoordinator {
    /// Max per-item rect delta (L1 of origin + size) between two index-keyed slot sets: 0 when every shared item
    /// sits in the same place.
    nonisolated static func maxIndexedRectDelta(source: [GridRenderSlot], target: [GridRenderSlot]) -> CGFloat {
        var src: [Int: CGRect] = [:]
        src.reserveCapacity(source.count)
        for s in source { src[s.index] = s.rect }
        var maxD: CGFloat = 0
        for t in target {
            guard let r = src[t.index] else { continue }
            let d =
                abs(r.minX - t.rect.minX) + abs(r.minY - t.rect.minY) + abs(r.width - t.rect.width)
                + abs(r.height - t.rect.height)
            if d > maxD { maxD = d }
        }
        return maxD
    }
}
