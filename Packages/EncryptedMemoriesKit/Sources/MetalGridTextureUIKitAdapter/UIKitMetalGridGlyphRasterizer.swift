#if canImport(UIKit)
    import CoreGraphics
    import MetalGridTextureCore
    import UIKit

    @MainActor
    package final class UIKitMetalGridGlyphRasterizer: MetalGridGlyphRasterizing {
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

        private func symbolImage(_ symbolName: String, request: MetalGridGlyphRequest) -> CGImage? {
            let pixelSize = CGFloat(request.pixelSize)
            let configuration = UIImage.SymbolConfiguration(
                pointSize: pixelSize * 0.72,
                weight: request.weight.uiSymbolWeight
            )
            guard
                let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                    .withTintColor(request.color.uiColor, renderingMode: .alwaysOriginal)
            else { return nil }

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false

            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: pixelSize, height: pixelSize),
                format: format
            )
            let image = renderer.image { _ in
                let size = symbol.size
                let rect = CGRect(
                    x: (pixelSize - size.width) / 2,
                    y: (pixelSize - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                symbol.draw(in: rect)
            }
            return image.cgImage
        }

        private func textImage(_ text: String, request: MetalGridGlyphRequest) -> CGImage? {
            guard !text.isEmpty, request.aspectRatio > 0 else { return nil }
            let height = CGFloat(request.pixelSize)
            let width = CGFloat(request.canvasPixelWidth)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: request.textStyle.uiFont(
                        size: height * 0.82,
                        weight: request.weight.uiFontWeight
                    ),
                    .foregroundColor: request.color.uiColor,
                ]
            )
            let measured = attributed.size()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height),
                format: format
            ).image { _ in
                attributed.draw(
                    at: CGPoint(
                        x: (width - measured.width) / 2,
                        y: (height - measured.height) / 2
                    )
                )
            }.cgImage
        }
    }

    package extension MetalGridGlyphColor {
        init(_ color: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0

            if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
            } else {
                self.init(red: 1, green: 1, blue: 1, alpha: 1)
            }
        }

        fileprivate var uiColor: UIColor {
            UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        }
    }

    private extension MetalGridGlyphTextStyle {
        func uiFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            switch self {
            case .system:
                UIFont.systemFont(ofSize: size, weight: weight)
            case .monospaced:
                UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
        }
    }

    private extension MetalGridGlyphWeight {
        var uiSymbolWeight: UIImage.SymbolWeight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        var uiFontWeight: UIFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }
#endif
