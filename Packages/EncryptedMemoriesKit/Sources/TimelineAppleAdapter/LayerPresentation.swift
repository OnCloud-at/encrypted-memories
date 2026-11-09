import Foundation
import QuartzCore

/// Native layer presentation for the timeline label; callers provide geometry and timing from their policy.
@MainActor
public enum LayerPresentation {
    public static func effectiveOpacity(of layer: CALayer) -> Float {
        var result: Float = 1
        var ancestor: CALayer? = layer
        while let current = ancestor {
            if current.isHidden { return 0 }
            result *= current.presentation()?.opacity ?? current.opacity
            ancestor = current.superlayer
        }
        return result
    }

    /// Live targets keep the remaining onset residual; a new slide starts at the current presented position.
    public static func setTranslationX(_ target: CGFloat, on layer: CALayer, duration: TimeInterval?, tracking: Bool) {
        var slide: CABasicAnimation?
        if let duration {
            let current = layer.presentation()?.affineTransform().tx ?? layer.affineTransform().tx
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = current - target
            animation.toValue = 0
            animation.isAdditive = true
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            slide = animation
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: target, y: 0))
        CATransaction.commit()
        if let slide {
            layer.add(slide, forKey: "transform")
        } else if !tracking {
            layer.removeAnimation(forKey: "transform")
        }
    }
}
