import Testing

@testable import DesignSystemCore

@Suite struct LibraryLoadingCoverTests {
    @Test func sharedCoverUsesStableCrossPlatformMetrics() {
        #expect(LibraryLoadingCoverMetrics.fadeDuration == 0.32)
        #expect(LibraryLoadingCoverMetrics.markSize == 72)
        #expect(LibraryLoadingCoverMetrics.activityBannerOffset == 92)
    }
}
