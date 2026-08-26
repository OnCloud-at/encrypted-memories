import SwiftUI

public extension View {
    /// Spins an SF Symbol steadily clockwise while `active` is true. The system owns the indefinite
    /// animation lifecycle, so foregrounding a scene cannot stack or accelerate repeating animations.
    /// Honors Reduce Motion by holding still.
    func spinsWhileActive(_ active: Bool, period: Double = 1.1) -> some View {
        modifier(ActivitySpin(active: active, period: period))
    }
}

private struct ActivitySpin: ViewModifier {
    let active: Bool
    let period: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(
                .rotate.clockwise.wholeSymbol,
                options: .repeat(.continuous).speed(1 / max(0.1, period)),
                isActive: active && !reduceMotion
            )
    }
}
