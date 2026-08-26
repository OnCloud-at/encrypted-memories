import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// A light frosted-glass band pinned behind an inline navigation or toolbar title.
///
/// The platform vibrancy view blurs sibling Metal layers. The gradient mask supplies the soft bottom fade,
/// while the caller supplies a stable height so layout does not depend on window reads during body evaluation.
public struct TopFrostBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryLoadingCoverPresented) private var loadingCoverPresented

    /// Total band height: the top safe-area / toolbar inset plus a little fade room below it.
    private let height: CGFloat
    /// 0…1 - dials the frost from barely-there to full, so it stays a subtle band rather than a dark strip.
    private let intensity: CGFloat

    public init(height: CGFloat, intensity: CGFloat = 0.6) {
        self.height = height
        self.intensity = intensity
    }

    public var body: some View {
        FrostBlur(
            intensity: intensity,
            isActive: !loadingCoverPresented,
            animated: !reduceMotion
        )
        .frame(height: max(48, height))
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

// Shared gradient stops (mask alpha, top to bottom): uniform frost held across the bar, soft-faded only at
// the very bottom edge so it never reads as a hard opaque strip cutting through a photo row.
private func frostMaskColors(intensity: CGFloat) -> [CGColor] {
    let alpha = min(max(intensity, 0), 1)
    return [
        CGColor(gray: 0, alpha: alpha),
        CGColor(gray: 0, alpha: alpha),
        CGColor(gray: 0, alpha: 0),
    ]
}
private let frostMaskLocations: [NSNumber] = [0.0, 0.80, 1.0]

#if canImport(UIKit)
    private struct FrostBlur: UIViewRepresentable {
        let intensity: CGFloat
        let isActive: Bool
        let animated: Bool

        func makeUIView(context: Context) -> FrostBarView {
            FrostBarView(intensity: intensity, isActive: isActive)
        }

        func updateUIView(_ view: FrostBarView, context: Context) {
            view.setIntensity(intensity)
            view.setActive(isActive, animated: animated)
        }
    }

    private final class FrostBarView: UIView {
        private let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        private let gradient = CAGradientLayer()
        private var active: Bool

        init(intensity: CGFloat, isActive: Bool) {
            active = isActive
            super.init(frame: .zero)
            effect.effect = isActive ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
            addSubview(effect)
            gradient.colors = frostMaskColors(intensity: intensity)
            gradient.locations = frostMaskLocations
            gradient.startPoint = CGPoint(x: 0.5, y: 0)  // UIKit origin is top-left; frost begins at the top.
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            layer.mask = gradient
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func setIntensity(_ intensity: CGFloat) {
            gradient.colors = frostMaskColors(intensity: intensity)
        }

        func setActive(_ isActive: Bool, animated: Bool) {
            guard active != isActive else { return }
            active = isActive
            let changes: () -> Void = { [weak self] in
                guard let self else { return }
                self.effect.effect = isActive ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
            }
            guard animated else {
                changes()
                return
            }
            UIView.animate(
                withDuration: LibraryLoadingCoverMetrics.fadeDuration,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
                animations: changes
            )
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effect.frame = bounds
            gradient.frame = bounds
            CATransaction.commit()
        }
    }
#else
    private struct FrostBlur: NSViewRepresentable {
        let intensity: CGFloat
        let isActive: Bool
        let animated: Bool

        func makeNSView(context: Context) -> FrostBarView {
            FrostBarView(intensity: intensity, isActive: isActive)
        }

        func updateNSView(_ view: FrostBarView, context: Context) {
            view.setIntensity(intensity)
            view.setActive(isActive, animated: animated)
        }
    }

    private final class FrostBarView: NSView {
        private let effect = NSVisualEffectView()
        private let gradient = CAGradientLayer()
        private var active: Bool

        init(intensity: CGFloat, isActive: Bool) {
            active = isActive
            super.init(frame: .zero)
            wantsLayer = true
            effect.blendingMode = .withinWindow
            effect.material = .headerView
            effect.state = .followsWindowActiveState
            effect.alphaValue = isActive ? 1 : 0
            addSubview(effect)
            gradient.colors = frostMaskColors(intensity: intensity)
            gradient.locations = frostMaskLocations
            gradient.startPoint = CGPoint(x: 0.5, y: 1)  // AppKit origin is bottom-left; frost begins at the top.
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.mask = gradient
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func setIntensity(_ intensity: CGFloat) {
            gradient.colors = frostMaskColors(intensity: intensity)
        }

        func setActive(_ isActive: Bool, animated: Bool) {
            guard active != isActive else { return }
            active = isActive
            guard animated else {
                effect.alphaValue = isActive ? 1 : 0
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = LibraryLoadingCoverMetrics.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                effect.animator().alphaValue = isActive ? 1 : 0
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effect.frame = bounds
            gradient.frame = bounds
            CATransaction.commit()
        }
    }
#endif
