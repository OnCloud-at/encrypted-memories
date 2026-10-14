import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import ProtonDriveSDK

/// Generates the encrypted-thumbnail inputs the SDK upload requires. All work is CPU/IO bound and is
/// only ever called off the main thread (from the upload backend). Best-effort: if a thumbnail can't
/// be produced (corrupt file, unusual codec) it's omitted rather than failing the whole upload.
///
/// Every output is an opaque 8-bit JPEG in sRGB or Display P3, so every Proton client shows it with the right colours.
enum UploadMediaProcessor {
    /// Proton's thumbnail dimensions and clear-data limits. The API allows a small amount of
    /// additional space for the SDK's encrypted envelope.
    private static let thumbnailMaxPixel = 512
    private static let previewMaxPixel = 1920
    static let thumbnailMaxBytes = 60 * 1_024
    static let previewMaxBytes = 1_024 * 1_024
    private static let compressionQualities: [Double] = [0.7, 0.4, 0.2, 0.1, 0]
    /// HDR sources take a half-float buffer of up to about 22 MB at preview size. One conversion at a time keeps
    /// parallel uploads within the memory of small iPhones.
    static let hdrConversions = UploadHDRConversionGate()

    static func thumbnails(for url: URL, isVideo: Bool) async -> [ThumbnailData] {
        guard let source = await baseImage(for: url, isVideo: isVideo) else { return [] }
        let isHDR = usesHDRTransfer(source)
        if isHDR { await hdrConversions.acquire() }
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
        if isHDR { await hdrConversions.release() }
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
        // An HDR frame keeps its HDR transfer here, so it takes the same reference-white conversion as an HDR photo.
        // The default (forceSDR) maps the HDR peak to SDR white and shows reference white at about 60 %.
        generator.dynamicRangePolicy = .matchSource
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    // MARK: - Encoding

    private static func jpeg(downscaling image: CGImage, maxPixel: Int, maxBytes: Int) -> Data? {
        guard let encodedImage = sdrImage(of: image, maxPixel: maxPixel) else { return nil }
        for quality in compressionQualities {
            guard let data = JPEGEncoding.data(from: encodedImage, quality: quality) else { return nil }
            if data.count <= maxBytes {
                return data
            }
        }
        return nil
    }

    /// An opaque image of at most `maxPixel` in the output colour space; JPEG encoding stores it with 8 bits. Nil when a
    /// source that needs a colour conversion cannot be converted: no thumbnail is better than one with wrong colours.
    static func sdrImage(
        of image: CGImage, maxPixel: Int,
        draw: (CGImage, _ width: Int, _ height: Int, CGColorSpace, _ halfFloat: Bool) -> CGImage? = draw
    ) -> CGImage? {
        let (width, height) = scaledSize(of: image, maxPixel: maxPixel)
        let colorSpace = outputColorSpace(for: image)
        if usesHDRTransfer(image) {
            // ITU-R BT.2408: HDR reference white becomes SDR white, and brighter highlights clip. Extended linear sRGB
            // holds reference white at 1.0. A direct draw into SDR maps the HDR peak to white instead.
            guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                let anchored = draw(image, width, height, linear, true)
            else { return nil }
            return draw(anchored, width, height, colorSpace, false)
        }
        let needsConversion = image.colorSpace != colorSpace
        if width == image.width, height == image.height, !needsConversion, isOpaque(image) {
            return image
        }
        if let drawn = draw(image, width, height, colorSpace, false) {
            return drawn
        }
        return needsConversion ? nil : image
    }

    private static func scaledSize(of image: CGImage, maxPixel: Int) -> (width: Int, height: Int) {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return (image.width, image.height) }
        let scale = Double(maxPixel) / Double(longest)
        return (Int((Double(image.width) * scale).rounded()), Int((Double(image.height) * scale).rounded()))
    }

    static func draw(
        _ image: CGImage, width: Int, height: Int, in colorSpace: CGColorSpace, halfFloat: Bool
    ) -> CGImage? {
        let bitmapInfo =
            halfFloat
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: halfFloat ? 16 : 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// HLG and PQ content: its reference white is not SDR white.
    static func usesHDRTransfer(_ image: CGImage) -> Bool {
        image.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
    }

    /// Proton clients expect plain 8-bit SDR JPEGs; one that ignores an HLG, PQ, BT.2020 or linear profile
    /// shows such a thumbnail grey, washed out or dark. sRGB and Display P3 sources keep their colour space;
    /// every other source, including video frames, is drawn into sRGB.
    private static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace,
            colorSpace.name == CGColorSpace.sRGB || colorSpace.name == CGColorSpace.displayP3
        {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            true
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            false
        @unknown default:
            false
        }
    }
}

/// Admits one holder at a time, in arrival order.
actor UploadHDRConversionGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callers that wait for the holder.
    var waitingCount: Int { waiters.count }

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
