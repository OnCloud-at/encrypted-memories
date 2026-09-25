import CoreGraphics
import GridCore

/// Draws upload badges with CoreGraphics only, for every platform alike. A dark translucent disc with a white
/// outline keeps the badge legible on bright photos. Progress fills the disc with white like a pie until it is
/// solid; the checkmark then shows on that white disc.
package enum MetalGridUploadBadgeImage {
    /// The SF Symbol a platform rasterizer renders for `badge`, when the badge carries one.
    package static func symbolName(for badge: GridUploadBadge) -> String? { badge.symbolName }

    /// `symbol` is the host-rendered white `symbolName(for:)`, drawn centered on the disc.
    package static func make(_ badge: GridUploadBadge, pixelSize: Int, symbol: CGImage? = nil) -> CGImage? {
        guard pixelSize > 0,
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let size = CGFloat(pixelSize)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let disc = bounds.insetBy(dx: size * 0.04, dy: size * 0.04)
        context.setShouldAntialias(true)
        switch badge {
        case .waiting:
            drawPie(context, in: disc, fraction: 0)
        case .uploading(let step):
            let fraction =
                Double(min(max(step, 0), GridUploadBadge.progressSteps)) / Double(GridUploadBadge.progressSteps)
            drawPie(context, in: disc, fraction: fraction)
        case .done:
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
            context.fillEllipse(in: disc)
            drawCheckmark(context, in: disc)
        case .attention:
            drawDisc(context, disc)
            drawExclamation(context, in: disc)
        case .notBackedUp:
            drawDisc(context, disc)
            if let symbol {
                let side = disc.width * 0.62
                let aspect = CGFloat(symbol.width) / CGFloat(max(1, symbol.height))
                let width = aspect >= 1 ? side : side * aspect
                let height = aspect >= 1 ? side / aspect : side
                context.draw(
                    symbol,
                    in: CGRect(x: disc.midX - width / 2, y: disc.midY - height / 2, width: width, height: height))
            }
        }
        return context.makeImage()
    }

    private static func drawDisc(_ context: CGContext, _ rect: CGRect) {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        context.fillEllipse(in: rect)
    }

    private static func drawPie(_ context: CGContext, in disc: CGRect, fraction: Double) {
        drawDisc(context, disc)
        let lineWidth = disc.width * 0.07
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        if fraction > 0 {
            let center = CGPoint(x: disc.midX, y: disc.midY)
            // CoreGraphics has a bottom-left origin: start at 12 o'clock and fill clockwise.
            let start = CGFloat.pi / 2
            let end = start - CGFloat(min(1, fraction)) * 2 * .pi
            context.setFillColor(white)
            context.move(to: center)
            context.addArc(center: center, radius: disc.width / 2, startAngle: start, endAngle: end, clockwise: true)
            context.closePath()
            context.fillPath()
        }
        context.setStrokeColor(white)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: disc.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    private static func drawCheckmark(_ context: CGContext, in disc: CGRect) {
        let width = disc.width
        context.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(width * 0.11)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: disc.minX + width * 0.29, y: disc.minY + width * 0.51))
        context.addLine(to: CGPoint(x: disc.minX + width * 0.44, y: disc.minY + width * 0.35))
        context.addLine(to: CGPoint(x: disc.minX + width * 0.72, y: disc.minY + width * 0.66))
        context.strokePath()
    }

    private static func drawExclamation(_ context: CGContext, in disc: CGRect) {
        let width = disc.width
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(width * 0.11)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: disc.midX, y: disc.minY + width * 0.72))
        context.addLine(to: CGPoint(x: disc.midX, y: disc.minY + width * 0.44))
        context.strokePath()
        let dot = width * 0.12
        context.fillEllipse(in: CGRect(x: disc.midX - dot / 2, y: disc.minY + width * 0.22, width: dot, height: dot))
    }
}
