import AppKit
import CoreGraphics
import MetalGridTextureCore

@MainActor
package final class AppKitMetalGridGlyphRasterizer: MetalGridGlyphRasterizing {
    package init() {}

    package func image(for request: MetalGridGlyphRequest) -> CGImage? {
        guard request.pixelSize > 0 else { return nil }
        switch request.content {
        case .symbol(let symbol):
            return symbolImage(symbol, request: request)
        case .text(let text):
            return textImage(text, request: request)
        }
    }

    private func symbolImage(_ symbol: String, request: MetalGridGlyphRequest) -> CGImage? {
        let pixelSize = request.pixelSize
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(pixelSize) * 0.72, weight: request.weight.nsFontWeight)
        guard
            let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        else { return nil }

        let canvas = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        canvas.lockFocus()
        let size = base.size
        let rect = NSRect(
            x: (CGFloat(pixelSize) - size.width) / 2,
            y: (CGFloat(pixelSize) - size.height) / 2,
            width: size.width,
            height: size.height
        )
        base.draw(in: rect)
        request.color.nsColor.set()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill(using: .sourceAtop)
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func textImage(_ text: String, request: MetalGridGlyphRequest) -> CGImage? {
        guard !text.isEmpty, request.aspectRatio > 0 else { return nil }
        let height = CGFloat(request.pixelSize)
        let width = CGFloat(request.canvasPixelWidth)
        let canvas = NSImage(size: NSSize(width: width, height: height))
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: request.textStyle.nsFont(
                    size: height * 0.82,
                    weight: request.weight.nsFontWeight
                ),
                .foregroundColor: request.color.nsColor,
            ]
        )
        let measured = attributed.size()
        canvas.lockFocus()
        attributed.draw(
            at: NSPoint(
                x: (width - measured.width) / 2,
                y: (height - measured.height) / 2
            )
        )
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

package extension MetalGridGlyphColor {
    init(_ color: NSColor) {
        let rgba = color.usingColorSpace(.sRGB) ?? color
        self.init(
            red: rgba.redComponent,
            green: rgba.greenComponent,
            blue: rgba.blueComponent,
            alpha: rgba.alphaComponent
        )
    }

    fileprivate var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension MetalGridGlyphTextStyle {
    func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch self {
        case .system:
            NSFont.systemFont(ofSize: size, weight: weight)
        case .monospaced:
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}

private extension MetalGridGlyphWeight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
