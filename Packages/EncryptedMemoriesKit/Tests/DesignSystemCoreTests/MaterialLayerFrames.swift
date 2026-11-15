import Foundation
import QuartzCore

/// Finds drawn material in a hosted view's layers. Hosted SwiftUI tests have no accessibility tree, and a material
/// draws as a backdrop layer. The package tests on macOS and the iOS app tests share this file.
enum MaterialLayerFrames {
    /// The frame of the largest backdrop layer below `root`, in `target`'s coordinates, or nil when none has an area.
    /// Scroll views add empty backdrop layers, and a prominent button draws a smaller one than a card.
    static func largest(below root: CALayer, in target: CALayer) -> CGRect? {
        func frames(_ layer: CALayer) -> [CGRect] {
            let own =
                NSStringFromClass(type(of: layer)) == "CABackdropLayer" ? [layer.convert(layer.bounds, to: target)] : []
            return own + (layer.sublayers ?? []).flatMap(frames)
        }
        return frames(root).filter { !$0.isEmpty }.max { $0.width * $0.height < $1.width * $1.height }
    }
}
