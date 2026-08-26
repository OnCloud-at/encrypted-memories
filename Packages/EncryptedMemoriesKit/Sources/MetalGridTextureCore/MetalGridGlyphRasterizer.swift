import CoreGraphics

package enum MetalGridGlyphContent: Equatable, Hashable, Sendable {
    case symbol(String)
    case text(String)
}

package struct MetalGridGlyphRequest: Equatable, Hashable, Sendable {
    package let content: MetalGridGlyphContent
    package let pixelSize: Int
    /// Width divided by height for text canvases. SF Symbols remain square.
    package let aspectRatio: Double
    package let textStyle: MetalGridGlyphTextStyle
    package let weight: MetalGridGlyphWeight
    package let color: MetalGridGlyphColor

    package init(symbol: String, pixelSize: Int = 44, weight: MetalGridGlyphWeight = .bold, color: MetalGridGlyphColor)
    {
        self.content = .symbol(symbol)
        self.pixelSize = pixelSize
        self.aspectRatio = 1
        self.textStyle = .system
        self.weight = weight
        self.color = color
    }

    package init(
        text: String,
        pixelSize: Int = 60,
        aspectRatio: Double,
        textStyle: MetalGridGlyphTextStyle = .system,
        weight: MetalGridGlyphWeight = .semibold,
        color: MetalGridGlyphColor
    ) {
        self.content = .text(text)
        self.pixelSize = pixelSize
        self.aspectRatio = aspectRatio
        self.textStyle = textStyle
        self.weight = weight
        self.color = color
    }

    package var canvasPixelWidth: Int {
        switch content {
        case .symbol:
            pixelSize
        case .text:
            max(1, Int((Double(pixelSize) * aspectRatio).rounded()))
        }
    }
}

package enum MetalGridGlyphTextStyle: String, Sendable {
    case system
    case monospaced
}

package enum MetalGridGlyphWeight: String, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

package struct MetalGridGlyphColor: Equatable, Hashable, Sendable {
    package let red: Double
    package let green: Double
    package let blue: Double
    package let alpha: Double

    package init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    package static let white = MetalGridGlyphColor(red: 1, green: 1, blue: 1, alpha: 1)
}

@MainActor
package protocol MetalGridGlyphRasterizing: AnyObject {
    func image(for request: MetalGridGlyphRequest) -> CGImage?
}
