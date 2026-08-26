import Testing

@testable import GridCore

@Suite struct GridThumbnailRevealPolicyTests {
    @Test func revealStartsTransparentAndSettlesQuicklyAtOpaque() {
        #expect(GridThumbnailRevealPolicy.opacity(elapsed: 0) == 0)
        #expect(GridThumbnailRevealPolicy.opacity(elapsed: GridThumbnailRevealPolicy.duration) == 1)
        #expect(GridThumbnailRevealPolicy.opacity(elapsed: GridThumbnailRevealPolicy.duration * 2) == 1)
    }

    @Test func revealUsesMonotonicEaseOutCurve() {
        let quarter = GridThumbnailRevealPolicy.opacity(elapsed: GridThumbnailRevealPolicy.duration * 0.25)
        let half = GridThumbnailRevealPolicy.opacity(elapsed: GridThumbnailRevealPolicy.duration * 0.5)
        let threeQuarters = GridThumbnailRevealPolicy.opacity(elapsed: GridThumbnailRevealPolicy.duration * 0.75)

        #expect(quarter > 0)
        #expect(quarter < half)
        #expect(half < threeQuarters)
        #expect(threeQuarters < 1)
        #expect(half > 0.5, "ease-out must reveal promptly instead of making ready media feel delayed")
    }
}
