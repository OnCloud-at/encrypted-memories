import CoreGraphics
import GridCore
import Testing

@testable import TimelineFeature

/// The apparent gap that the engine and a zoom transaction report along the ladder, and the smoothstep curve that
/// eases it. The recorded digests are the output of the code before its copies were merged.
@Suite struct GridApparentMetricsTests {
    /// FNV-1a over the bit patterns of the values: any change in any bit changes the digest.
    private static func digest(_ values: [CGFloat]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in values {
            hash = (hash ^ UInt64(Double(value).bitPattern)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static let positions: [CGFloat] = stride(from: -0.5, through: 6.5, by: 0.01).map { CGFloat($0) }

    @Test func theEngineAndAZoomTransactionKeepTheirApparentGaps() throws {
        let recorded: [(name: String, profile: GridLevelProfile, digest: UInt64)] = [
            ("regular", .testRegularTimeline, 0x883f_a414_ea59_8a06),
            ("compact", .testCompactTimeline, 0xa660_e19f_327f_854b),
        ]
        for (name, profile, expected) in recorded {
            let engine = SquareTileGridEngine(sectionCounts: [500], profile: profile)
            let transaction = try #require(
                engine.beginZoomTransaction(
                    cursorContentPoint: CGPoint(x: 200, y: 300), viewportPoint: CGPoint(x: 200, y: 300), level: 0,
                    width: 800))
            let engineGaps = Self.positions.map { engine.apparentGap(at: $0) }
            let transactionGaps = Self.positions.map { transaction.apparentGap(at: $0) }
            #expect(engineGaps == transactionGaps, "\(name): the transaction and the engine agree")
            #expect(Self.digest(engineGaps) == expected, "\(name): the apparent gaps along the ladder changed")
        }
    }

    @Test func smoothstepEasesFromZeroToOneAndClamps() {
        for x in Self.positions {
            let t = min(max(x, 0), 1)
            #expect(gridSmoothstep(x) == t * t * (3 - 2 * t))
        }
        #expect(gridSmoothstep(-3) == 0 && gridSmoothstep(0) == 0)
        #expect(gridSmoothstep(1) == 1 && gridSmoothstep(7) == 1)
        #expect(gridSmoothstep(0.5) == 0.5)
    }
}
