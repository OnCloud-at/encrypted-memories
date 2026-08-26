import CoreGraphics
import simd

// MARK: - TileContentFitter
//
// Media aspect is resolved here, outside the grid engine. The fitter returns the content rectangle and texture
// UV window for an already-resolved square slot. The result never changes grid geometry or hit testing.

/// Display modes for fitting media inside an unchanged square slot.
public enum TileContentDisplayMode: String, Equatable, Sendable, CaseIterable {
    /// Preserves the full media aspect ratio inside the square slot.
    case aspectFitInsideSquare
    /// Fills the square slot and center-crops the overflow.
    case squareFillCrop
}

/// How the media fits inside its square slot (the low-level fitter mode). `TileContentDisplayMode` is the
/// toggle-facing synonym; the two map one-to-one (`squareFillCrop` to `aspectFill`, `aspectFitInsideSquare` to `aspectFit`).
public enum TileContentMode: Equatable, Sendable {
    /// Center-crops the media to cover the whole square.
    case aspectFill
    /// Fits the whole media inside the square. The unused area remains in the slot.
    case aspectFit

    public init(_ display: TileContentDisplayMode) {
        self = display == .squareFillCrop ? .aspectFill : .aspectFit
    }
}

public extension TileContentDisplayMode {
    var fitterMode: TileContentMode { TileContentMode(self) }
}

/// The result: where to draw the image (`contentRect`, viewport/content coords matching the slot) and the
/// texture UV window to sample. Always contained in the slot it was fitted to.
public struct TileContentLayout: Equatable, Sendable {
    public let contentRect: CGRect
    public let uvMin: SIMD2<Float>
    public let uvMax: SIMD2<Float>

    public init(contentRect: CGRect, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>) {
        self.contentRect = contentRect
        self.uvMin = uvMin
        self.uvMax = uvMax
    }
}

public enum TileContentFitter {
    // MARK: Toggle-facing API (TileContentDisplayMode) - the same square slot in, content fit out.

    /// Fit by explicit media pixel size for a toggle display mode.
    public static func fit(
        slotRect: CGRect, mediaPixelSize: CGSize, displayMode: TileContentDisplayMode
    ) -> TileContentLayout {
        fit(slotRect: slotRect, mediaPixelSize: mediaPixelSize, mode: displayMode.fitterMode)
    }

    /// Fit by media aspect ratio for a toggle display mode.
    public static func fit(
        slotRect: CGRect, mediaAspect: CGFloat, displayMode: TileContentDisplayMode
    ) -> TileContentLayout {
        fit(slotRect: slotRect, mediaAspect: mediaAspect, mode: displayMode.fitterMode)
    }

    // MARK: Low-level API (TileContentMode)

    /// Fit by explicit media pixel size.
    public static func fit(slotRect: CGRect, mediaPixelSize: CGSize, mode: TileContentMode) -> TileContentLayout {
        let aspect = mediaPixelSize.height > 0 ? mediaPixelSize.width / mediaPixelSize.height : 1
        return fit(slotRect: slotRect, mediaAspect: aspect, mode: mode)
    }

    /// Fit by media aspect ratio (width / height).
    public static func fit(slotRect: CGRect, mediaAspect: CGFloat, mode: TileContentMode) -> TileContentLayout {
        let mediaAR = max(mediaAspect, 0.0001)
        let slotAR = slotRect.height > 0 ? slotRect.width / slotRect.height : 1
        switch mode {
        case .aspectFill:
            // Cover: the content rect IS the slot; crop the longer media axis via the UV window so the
            // image fills the square edge-to-edge (no bars), clipped to the slot.
            var insetX: Float = 0
            var insetY: Float = 0
            if mediaAR > slotAR {
                insetX = Float((1 - slotAR / mediaAR) / 2)
            } else {
                insetY = Float((1 - mediaAR / slotAR) / 2)
            }
            return TileContentLayout(
                contentRect: slotRect,
                uvMin: SIMD2(insetX, insetY), uvMax: SIMD2(1 - insetX, 1 - insetY))
        case .aspectFit:
            // Letterbox: the largest centered rect with the media aspect that fits inside the slot.
            var w = slotRect.width
            var h = slotRect.height
            if mediaAR >= slotAR { h = w / mediaAR } else { w = h * mediaAR }
            let rect = CGRect(x: slotRect.midX - w / 2, y: slotRect.midY - h / 2, width: w, height: h)
            return TileContentLayout(contentRect: rect, uvMin: SIMD2(0, 0), uvMax: SIMD2(1, 1))
        }
    }
}

/// A short, renderer-neutral interpolation between the two supported thumbnail fits. Hosts own only
/// the clock; the shared composer applies identical geometry and UV interpolation on every platform.
public struct TileContentDisplayTransition: Sendable, Equatable {
    public let from: TileContentDisplayMode
    public let to: TileContentDisplayMode
    public let progress: CGFloat

    public init(from: TileContentDisplayMode, to: TileContentDisplayMode, progress: CGFloat) {
        self.from = from
        self.to = to
        self.progress = min(1, max(0, progress))
    }
}
