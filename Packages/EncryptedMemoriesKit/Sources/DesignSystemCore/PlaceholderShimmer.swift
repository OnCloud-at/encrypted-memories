import SwiftUI

/// The loading sweep for redacted placeholder content: a soft bright band flows diagonally from top-left to
/// bottom-right across the placeholder shapes only. It uses the same motion as `LoadingMark`, so every loading
/// surface in the app pulses alike.
///
/// SwiftUI's `redacted(reason: .placeholder)` draws the grey shapes but has no animation, so this modifier
/// supplies it. The band is a moving `LinearGradient` masked by the content itself, so no rectangle sweeps over
/// the background. Honors Reduce Motion (static placeholder) and stops as soon as the view leaves the screen.
public struct PlaceholderShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isActive: Bool

    private let highlightOpacity = 0.55
    private let period = 1.6
    private let bandHalfExtent = 0.4

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let progress = t.truncatingRemainder(dividingBy: period) / period
                    // The band starts beyond the top-left corner and ends beyond the bottom-right one, so the loop
                    // restarts off-screen without a visible jump.
                    let position = -0.3 + 1.6 * progress
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(highlightOpacity), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: UnitPoint(x: position - bandHalfExtent, y: position - bandHalfExtent),
                                endPoint: UnitPoint(x: position + bandHalfExtent, y: position + bandHalfExtent)
                            )
                        )
                        .blendMode(.plusLighter)
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Adds the app's diagonal loading sweep to redacted placeholder content.
    public func placeholderShimmer(isActive: Bool = true) -> some View {
        modifier(PlaceholderShimmer(isActive: isActive))
    }
}
