import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Blurs a preview without a material's tint or a live backdrop dependency.
@MainActor
public enum PrivacyPreviewImageRenderer {
    public static let maximumDimension: CGFloat = 640
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func render(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(min(image.width, image.height)) * 0.06
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        // Finish rendering before UIKit takes the background snapshot.
        return context.createCGImage(
            output, from: input.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
    }
}
