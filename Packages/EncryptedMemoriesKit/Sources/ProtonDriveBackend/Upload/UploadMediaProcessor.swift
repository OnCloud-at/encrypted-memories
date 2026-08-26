import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ProtonDriveSDK
import UniformTypeIdentifiers

/// Generates the encrypted-thumbnail inputs the SDK upload requires. All work is CPU/IO bound and is
/// only ever called off the main thread (from the upload backend). Best-effort: if a thumbnail can't
/// be produced (corrupt file, unusual codec) it's omitted rather than failing the whole upload.
enum UploadMediaProcessor {
    /// Proton's thumbnail dimensions and clear-data limits. The API allows a small amount of
    /// additional space for the SDK's encrypted envelope.
    private static let thumbnailMaxPixel = 512
    private static let previewMaxPixel = 1920
    static let thumbnailMaxBytes = 60 * 1_024
    static let previewMaxBytes = 1_024 * 1_024
    private static let compressionQualities: [Double] = [0.7, 0.4, 0.2, 0.1, 0]

    static func thumbnails(for url: URL, isVideo: Bool) async -> [ThumbnailData] {
        guard let source = await baseImage(for: url, isVideo: isVideo) else { return [] }
        var result: [ThumbnailData] = []
        if let thumb = jpeg(
            downscaling: source,
            maxPixel: thumbnailMaxPixel,
            maxBytes: thumbnailMaxBytes
        ) {
            result.append(ThumbnailData(type: .thumbnail, data: thumb))
        }
        // Proton Drive uploads only the compact thumbnail for video resources.
        if !isVideo,
            let preview = jpeg(
                downscaling: source,
                maxPixel: previewMaxPixel,
                maxBytes: previewMaxBytes
            )
        {
            result.append(ThumbnailData(type: .preview, data: preview))
        }
        return result
    }

    // MARK: - Base image

    private static func baseImage(for url: URL, isVideo: Bool) async -> CGImage? {
        if isVideo {
            return await videoFrame(url)
        }
        return imageSourceFrame(url)
    }

    /// Full-ish image (downscaled to the preview box) used as the source for both outputs.
    private static func imageSourceFrame(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honour EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewMaxPixel, height: previewMaxPixel)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    // MARK: - Encoding

    private static func jpeg(downscaling image: CGImage, maxPixel: Int, maxBytes: Int) -> Data? {
        let scaled = downscale(image, maxPixel: maxPixel) ?? image
        let encodedImage = opaqueCopyIfNeeded(scaled) ?? scaled
        for quality in compressionQualities {
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                )
            else { return nil }
            CGImageDestinationAddImage(
                destination,
                encodedImage,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= maxBytes {
                return data as Data
            }
        }
        return nil
    }

    private static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let nw = Int((Double(w) * scale).rounded())
        let nh = Int((Double(h) * scale).rounded())
        let colorSpace =
            image.colorSpace?.model == .rgb
            ? image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            : CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    private static func opaqueCopyIfNeeded(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            break
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        @unknown default:
            break
        }
        let colorSpace =
            image.colorSpace?.model == .rgb
            ? image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            : CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
