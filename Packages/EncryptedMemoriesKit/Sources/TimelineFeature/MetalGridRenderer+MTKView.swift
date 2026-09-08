import CoreGraphics
import MetalKit
import MetalRenderingCore

extension MetalGridDrawableTarget {
    @MainActor
    init?(view: MTKView) {
        guard let drawable = view.currentDrawable,
            let pass = view.currentRenderPassDescriptor
        else { return nil }
        self.init(
            drawable: drawable,
            renderPassDescriptor: pass,
            presentsWithTransaction: view.presentsWithTransaction
        )
    }
}
