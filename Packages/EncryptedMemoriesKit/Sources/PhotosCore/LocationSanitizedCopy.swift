import AVFoundation
import Foundation
import ImageIO
import OSLog

/// Writes a separate outbound copy without image or movie location metadata.
///
/// - A photo or video without location leaves as its original bytes.
/// - A photo with location in a format that ImageIO can write gets a lossless copy without the location tags.
/// - A photo in a format that ImageIO cannot write (RAW, DNG, WebP, HEIF, JPEG XL) always leaves as a JPEG that is
///   rendered from its pixels, like Apple Photos shares RAW photos. The file name then ends in `.jpg`.
/// - A video with location gets a passthrough copy without its location keys. A container other than MOV, MP4, or
///   M4V becomes MOV.
/// - A file that neither ImageIO nor AVFoundation can read fails; the original bytes never leave unchecked.
public enum LocationSanitizedCopy {
    public enum Failure: Error {
        case unsupportedFormat
        case copyFailed
        case locationRemains
    }

    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PrivacyExport")

    /// Extensions whose photos ImageIO writes on every supported platform (probed on the SDK 27 toolchain).
    private static let writableImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "avif",
    ]
    private static let imageExtensions: Set<String> = writableImageExtensions.union([
        "heif", "dng", "raw", "webp", "jxl", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "srw", "x3f", "erf", "mrw", "3fr", "fff", "iiq", "rwl",
    ])
    private static let movieMIMETypes: [String: String] = [
        "mov": "video/quicktime", "qt": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v",
        "3gp": "video/3gpp", "3g2": "video/3gpp2",
    ]
    private static let passthroughFileTypes: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v]

    /// The name a location-free copy of `name` gets, before any bytes are read. Callers that must name a file in
    /// advance, like a save panel, use it.
    public static func outputFilename(forOriginalName name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext), !writableImageExtensions.contains(ext) {
            return url.deletingPathExtension().appendingPathExtension("jpg").lastPathComponent
        }
        if movieMIMETypes[ext] != nil, passthroughFileTypes[ext] == nil {
            return url.deletingPathExtension().appendingPathExtension("mov").lastPathComponent
        }
        return name
    }

    /// Writes the copy of `source` for the outbound name of `destination` and returns the written file. The
    /// extension of `destination` tells the original format, because a staged download can carry any name.
    @discardableResult
    public static func write(from source: URL, to destination: URL) async throws -> URL {
        try await write(from: source, to: destination, writableImageTypes: nil)
    }

    /// `writableImageTypes` replaces the platform's writable photo types; tests use it for formats that ImageIO
    /// reads but cannot write, because such samples cannot be created in a test.
    static func write(from source: URL, to destination: URL, writableImageTypes: Set<String>?) async throws -> URL {
        try Task.checkCancellation()
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw Failure.copyFailed }
        let ext = destination.pathExtension.lowercased()
        var written: URL?
        do {
            if let movieMIME = movieMIMETypes[ext] {
                written = try await writeMovie(from: source, mimeType: movieMIME, to: destination)
            } else if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                let type = CGImageSourceGetType(imageSource)
            {
                let writable =
                    writableImageTypes
                    ?? Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
                written = try writeImage(
                    imageSource, type: type, writable: writable.contains(type as String), original: source,
                    to: destination)
            } else {
                throw Failure.unsupportedFormat
            }
            try Task.checkCancellation()
            return written ?? destination
        } catch {
            logger.error(
                "Location-free copy failed for extension \(ext, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            try? FileManager.default.removeItem(at: written ?? destination)
            throw error
        }
    }

    // MARK: Photos

    private static func writeImage(
        _ source: CGImageSource, type: CFString, writable: Bool, original: URL, to destination: URL
    ) throws -> URL {
        guard writable else { return try render(source, as: "public.jpeg" as CFString, to: jpegURL(destination)) }
        guard hasImageLocation(source) else {
            try FileManager.default.copyItem(at: original, to: destination)
            return destination
        }
        // Some containers keep GPS outside the metadata that the lossless copy replaces. Each step is checked, and
        // the next one runs only when the location is still there: lossless copy, the same format rendered again,
        // then a JPEG.
        if (try? copyLosslessly(source, type: type, to: destination)) != nil { return destination }
        try? FileManager.default.removeItem(at: destination)
        if (try? render(source, as: type, to: destination)) != nil { return destination }
        try? FileManager.default.removeItem(at: destination)
        return try render(source, as: "public.jpeg" as CFString, to: jpegURL(destination))
    }

    private static func jpegURL(_ destination: URL) -> URL {
        destination.deletingPathExtension().appendingPathExtension("jpg")
    }

    /// Copies every image without decoding it, with the source metadata minus its location tags.
    ///
    /// `kCGImageMetadataShouldExcludeGPS` keeps GPS in HEIC and drops the EXIF and the Apple maker note of a JPEG,
    /// which breaks the Live Photo pairing, so the copy replaces the metadata instead.
    private static func copyLosslessly(_ source: CGImageSource, type: CFString, to destination: URL) throws {
        guard
            let writer = CGImageDestinationCreateWithURL(
                destination as CFURL, type, CGImageSourceGetCount(source), nil)
        else { throw Failure.unsupportedFormat }
        let options =
            [kCGImageDestinationMetadata: try cleanedMetadata(of: source), kCGImageDestinationMergeMetadata: false]
            as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(writer, source, options, &error) else {
            _ = error?.takeRetainedValue()
            throw Failure.copyFailed
        }
        try verifyNoImageLocation(at: destination)
    }

    /// Renders the primary image in `type` with every metadata tag except the location.
    private static func render(_ source: CGImageSource, as type: CFString, to output: URL) throws -> URL {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
            let writer = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil)
        else { throw Failure.unsupportedFormat }
        do {
            CGImageDestinationAddImageAndMetadata(
                writer, image, try cleanedMetadata(of: source, at: index),
                [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw Failure.copyFailed }
            try verifyNoImageLocation(at: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    private static func cleanedMetadata(of source: CGImageSource, at index: Int = 0) throws -> CGMutableImageMetadata {
        // A photo without any metadata, for example a BMP, gets an empty set.
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else {
            return CGImageMetadataCreateMutable()
        }
        guard let cleaned = CGImageMetadataCreateMutableCopy(metadata) else { throw Failure.copyFailed }
        for path in locationTagPaths(in: metadata) { CGImageMetadataRemoveTagWithPath(cleaned, nil, path as CFString) }
        return cleaned
    }

    private static func locationTagPaths(in metadata: CGImageMetadata) -> [String] {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if Self.isLocationTag(tag) { paths.append(path as String) }
            return true
        }
        return paths
    }

    private static func hasImageLocation(_ source: CGImageSource) -> Bool {
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            if hasLocation(properties) { return true }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
                !locationTagPaths(in: metadata).isEmpty
            {
                return true
            }
        }
        return false
    }

    private static func verifyNoImageLocation(at url: URL) throws {
        guard let output = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.copyFailed }
        guard !hasImageLocation(output) else { throw Failure.locationRemains }
    }

    private static func hasLocation(_ properties: [CFString: Any]?) -> Bool {
        guard let properties else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        return iptcPlaceKeys.contains { iptc[$0] != nil }
    }

    private static var iptcPlaceKeys: [CFString] {
        [
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        ]
    }

    /// EXIF GPS tags, plus the place names that IPTC and Photoshop metadata can carry.
    private static func isLocationTag(_ tag: CGImageMetadataTag) -> Bool {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
            let name = CGImageMetadataTagCopyName(tag) as String?
        else { return false }
        switch prefix {
        case "exif", "exifEX": return name.hasPrefix("GPS")
        case "photoshop": return ["City", "State", "Country"].contains(name)
        case "Iptc4xmpCore": return ["Location", "CountryCode"].contains(name)
        case "Iptc4xmpExt": return ["LocationCreated", "LocationShown"].contains(name)
        default: return false
        }
    }

    // MARK: Videos

    /// The location keys of QuickTime, 3GP, and common movie metadata.
    private static let movieLocationIdentifiers: Set<AVMetadataIdentifier> = [
        .commonIdentifierLocation,
        .identifier3GPUserDataLocation,
        .quickTimeUserDataLocationISO6709,
        .quickTimeMetadataLocationISO6709,
        .quickTimeMetadataLocationName,
        .quickTimeMetadataLocationBody,
        .quickTimeMetadataLocationNote,
        .quickTimeMetadataLocationRole,
        .quickTimeMetadataLocationDate,
        .quickTimeMetadataLocationHorizontalAccuracyInMeters,
    ]

    private static func hasMovieLocation(_ asset: AVURLAsset) async throws -> Bool {
        try await asset.load(.metadata).contains { $0.identifier.map(movieLocationIdentifiers.contains) ?? false }
    }

    private static func writeMovie(from source: URL, mimeType: String, to destination: URL) async throws -> URL {
        // A staged download has no media extension; AVFoundation cannot open it without the type.
        let asset = AVURLAsset(url: source, options: [AVURLAssetOverrideMIMETypeKey: mimeType])
        guard try await asset.load(.isReadable) else { throw Failure.unsupportedFormat }
        guard try await hasMovieLocation(asset) else {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
        let ext = destination.pathExtension.lowercased()
        let fileType = passthroughFileTypes[ext] ?? .mov
        let output =
            passthroughFileTypes[ext] == nil
            ? destination.deletingPathExtension().appendingPathExtension("mov") : destination
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
            await session.supportedFileTypes.contains(fileType)
        else { throw Failure.unsupportedFormat }
        session.metadataItemFilter = .forSharing()
        do {
            try await session.export(to: output, as: fileType)
            guard try await !hasMovieLocation(AVURLAsset(url: output)) else { throw Failure.locationRemains }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
