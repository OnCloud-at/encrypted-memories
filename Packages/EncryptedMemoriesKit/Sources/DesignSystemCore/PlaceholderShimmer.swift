import SwiftUI

/// The loading sweep for redacted placeholder content: a brighter band flows diagonally from top-left to
/// bottom-right across the placeholder shapes only. It uses the same motion as `LoadingMark`, so every loading
/// surface in the app pulses alike.
///
/// SwiftUI's `redacted(reason: .placeholder)` draws the grey shapes but has no animation, so this modifier
/// supplies it. Only the placeholder shapes change, so no rectangle sweeps over the background. Honors Reduce
/// Motion (static placeholder) and stops as soon as the view leaves the screen.
public struct PlaceholderShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isActive: Bool

    /// Opacity of the placeholder shapes outside the band; the band itself shows them at full opacity.
    private let restingOpacity = 0.35
    private let period = 1.4
    // A narrow band reads as the familiar skeleton shimmer; applied once to a whole block, it sweeps across all
    // placeholder shapes as one continuous highlight.
    private let bandHalfExtent = 0.25

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            // The placeholder shapes are masked by a moving gradient: dimmed at rest, full strength inside the
            // band. `redacted` draws its shapes translucent, so brightening them from above would barely show.
            content.mask {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let progress = t.truncatingRemainder(dividingBy: period) / period
                    // The band starts beyond the top-left corner and ends beyond the bottom-right one, so the loop
                    // restarts off-screen without a visible jump.
                    let position = -0.3 + 1.6 * progress
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(restingOpacity), location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black.opacity(restingOpacity), location: 1),
                        ],
                        startPoint: UnitPoint(x: position - bandHalfExtent, y: position - bandHalfExtent),
                        endPoint: UnitPoint(x: position + bandHalfExtent, y: position + bandHalfExtent)
                    )
                }
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
