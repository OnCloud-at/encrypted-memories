import AppKit
import DesignSystemCore
import QuartzCore
import SwiftUI

/// AppKit-only launch material. It samples the desktop and other windows so the complete startup surface
/// remains translucent until the mounted library is ready.
public struct LibraryFrostedBackdrop: NSViewRepresentable {
    private let material: NSVisualEffectView.Material
    private let isActive: Bool

    public init(isActive: Bool, material: NSVisualEffectView.Material = .fullScreenUI) {
        self.isActive = isActive
        self.material = material
    }

    public func makeNSView(context: Context) -> LibraryFrostedBackdropView {
        let view = LibraryFrostedBackdropView(isActive: isActive)
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        return view
    }

    public func updateNSView(_ view: LibraryFrostedBackdropView, context: Context) {
        view.material = material
        view.setActive(isActive, animated: !context.environment.accessibilityReduceMotion)
    }
}

@MainActor
public final class LibraryFrostedBackdropView: NSVisualEffectView {
    private var active: Bool

    init(isActive: Bool) {
        active = isActive
        super.init(frame: .zero)
        alphaValue = isActive ? 1 : 0
        isHidden = !isActive
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setActive(_ isActive: Bool, animated: Bool) {
        guard active != isActive else { return }
        active = isActive
        if isActive {
            isHidden = false
        }

        guard animated else {
            alphaValue = isActive ? 1 : 0
            isHidden = !isActive
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = LibraryLoadingCoverMetrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = isActive ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.active else { return }
                self.isHidden = true
            }
        }
    }
}
