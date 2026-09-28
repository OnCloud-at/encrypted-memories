import PhotosCore
import UIKit

/// Covers one scene's complete window, including presented viewers and sheets, before iOS captures a preview.
@MainActor
final class MobilePrivacyPreviewShield {
    private weak var window: UIWindow?
    private var blur: UIVisualEffectView?

    func update(enabled: Bool, isSceneActive: Bool, window: UIWindow?) {
        if self.window !== window {
            remove()
            self.window = window
        }
        guard let window,
            PrivacyPreviewPolicy.shouldCover(
                enabled: enabled, isSceneActive: isSceneActive, isWindowVisible: true)
        else {
            remove()
            return
        }
        if let blur {
            window.bringSubviewToFront(blur)
            return
        }

        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        effect.frame = window.bounds
        effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.accessibilityElementsHidden = true
        let tint = UIView(frame: effect.bounds)
        tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tint.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
        effect.contentView.addSubview(tint)
        window.addSubview(effect)
        blur = effect
    }

    func remove() {
        blur?.removeFromSuperview()
        blur = nil
    }
}
