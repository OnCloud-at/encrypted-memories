import Testing

@testable import DesignSystemCore

@Suite struct ActivityProgressTests {
    @Test func barFractionStaysWithinTheNativeRange() {
        #expect(ActivityProgressBar.clamped(-0.5) == 0)
        #expect(ActivityProgressBar.clamped(0.25) == 0.25)
        #expect(ActivityProgressBar.clamped(1.5) == 1)
        #expect(ActivityProgressBar.clamped(.nan) == 0)
        #expect(ActivityProgressBar.clamped(.infinity) == 0)
    }

    @Test func stateLineUsesSeventyPercentOfTheReadableWidth() {
        // A wide window offers more than the readable width; the line stays at 70 % of it.
        #expect(ActivityProgressStateLayout.availableWidth(for: 1_200) == 320)
        #expect(abs(ActivityProgressStateLayout.lineWidth(in: 320) - 224) < 0.001)
        // Without a proposal the state assumes the readable width.
        #expect(ActivityProgressStateLayout.availableWidth(for: nil) == 320)
        // A narrow state keeps the 120 pt minimum, but never more than the state offers.
        #expect(ActivityProgressStateLayout.lineWidth(in: 150) == 120)
        #expect(ActivityProgressStateLayout.lineWidth(in: 100) == 100)
        #expect(ActivityProgressStateLayout.availableWidth(for: -10) == 0)
    }

    @Test func everySpinningSymbolSharesOnePeriod() {
        #expect(ActivitySpin.period == 1.7)
    }
}
