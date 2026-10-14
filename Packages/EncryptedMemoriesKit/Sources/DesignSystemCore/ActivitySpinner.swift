import SwiftUI

public extension View {
    /// Spins an SF Symbol steadily clockwise while `active` is true, once per `ActivitySpin.period` everywhere. The
    /// system owns the indefinite animation lifecycle, so foregrounding a scene cannot stack or accelerate repeating
    /// animations. Honors Reduce Motion by holding still.
    func spinsWhileActive(_ active: Bool) -> some View {
        modifier(ActivitySpin(active: active))
    }
}

struct ActivitySpin: ViewModifier {
    /// The one rotation period, in seconds, of every spinning activity symbol.
    nonisolated static let period: Double = 1.7

    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(
                .rotate.clockwise.wholeSymbol,
                options: .repeat(.continuous).speed(1 / Self.period),
                isActive: active && !reduceMotion
            )
    }
}
