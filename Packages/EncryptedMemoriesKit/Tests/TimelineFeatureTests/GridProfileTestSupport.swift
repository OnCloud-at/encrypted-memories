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
