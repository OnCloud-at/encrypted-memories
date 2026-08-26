import Foundation
import Metal
import MetalRenderingCore
import PhotosCore

/// Runtime probe for the Metal-backed library grid. It reports whether the renderer can initialize on this
/// machine, so callers can handle an unavailable GPU or shader without crashing.
enum MetalGridRuntime {
    /// One-time probe: a Metal device exists AND the production renderer/shader builds. Cached.
    static let isMetalRenderable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        guard Metal3RuntimeCapability.supports(device: device) else { return false }
        return MetalGridRenderer(device: device, clearColor: MetalGridPalette.clearColor) != nil
    }()

    @MainActor private static var didLogResolution = false

    /// Logs the resolved render path exactly once (idempotent across the many TimelineView re-renders).
    @MainActor static func logResolutionOnce() {
        guard !didLogResolution else { return }
        didLogResolution = true
        PhotoDiagnostics.shared.emit(
            "MetalGrid",
            [
                "activePath": isMetalRenderable ? "metal" : "unavailable",
                "metalRenderable": "\(isMetalRenderable)",
            ])
    }
}
