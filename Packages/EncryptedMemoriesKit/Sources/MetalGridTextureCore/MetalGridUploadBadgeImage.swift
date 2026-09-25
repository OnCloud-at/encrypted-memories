import CoreGraphics
import GridCore

/// Draws upload badges with CoreGraphics only, for every platform alike. A dark translucent disc keeps the
/// white ring legible on bright photos; the checkmark uses a white disc, like other system badges.
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
            drawDisc(context, disc)
            drawRing(context, in: disc, fraction: 0)
        case .uploading(let step):
            drawDisc(context, disc)
            let fraction =
                Double(min(max(step, 0), GridUploadBadge.progressSteps)) / Double(GridUploadBadge.progressSteps)
            drawRing(context, in: disc, fraction: fraction)
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

    private static func drawRing(_ context: CGContext, in disc: CGRect, fraction: Double) {
        let lineWidth = disc.width * 0.11
        let ringRect = disc.insetBy(dx: disc.width * 0.2, dy: disc.width * 0.2)
        let center = CGPoint(x: ringRect.midX, y: ringRect.midY)
        let radius = ringRect.width / 2
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.42))
        context.strokeEllipse(in: ringRect)
        guard fraction > 0 else { return }
        // CoreGraphics has a bottom-left origin: start at 12 o'clock and fill clockwise.
        let start = CGFloat.pi / 2
        let end = start - CGFloat(min(1, fraction)) * 2 * .pi
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.strokePath()
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
