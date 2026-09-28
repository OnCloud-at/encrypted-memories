import AVFoundation
import Foundation
import ImageIO

/// Writes a separate outbound copy without standard image or movie location metadata.
/// An unsupported format fails before the caller can deliver the original bytes.
public enum LocationSanitizedCopy {
    public enum Failure: Error {
        case unsupportedFormat
        case copyFailed
        case locationRemains
    }

    public static func write(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw Failure.copyFailed }
        do {
            if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                let type = CGImageSourceGetType(imageSource)
            {
                try writeImage(imageSource, type: type, to: destination)
            } else {
                try await writeMovie(from: source, to: destination)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func writeImage(_ source: CGImageSource, type: CFString, to destination: URL) throws {
        guard
            let writer = CGImageDestinationCreateWithURL(
                destination as CFURL, type, CGImageSourceGetCount(source), nil)
        else { throw Failure.unsupportedFormat }
        // `kCGImageMetadataShouldExcludeGPS` keeps GPS in HEIC and drops the EXIF and the Apple maker note of a
        // JPEG, which breaks the Live Photo pairing. A lossless copy with the source metadata minus its location
        // tags keeps everything else.
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let cleaned = CGImageMetadataCreateMutableCopy(metadata)
        else { throw Failure.copyFailed }
        var locationPaths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if Self.isLocationTag(tag) { locationPaths.append(path as String) }
            return true
        }
        for path in locationPaths { CGImageMetadataRemoveTagWithPath(cleaned, nil, path as CFString) }
        let options =
            [kCGImageDestinationMetadata: cleaned, kCGImageDestinationMergeMetadata: false] as CFDictionary
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(writer, source, options, &error) else {
            _ = error?.takeRetainedValue()
            throw Failure.copyFailed
        }
        guard let output = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            throw Failure.copyFailed
        }
        for index in 0..<CGImageSourceGetCount(output) {
            let properties = CGImageSourceCopyPropertiesAtIndex(output, index, nil) as? [CFString: Any]
            guard properties?[kCGImagePropertyGPSDictionary] == nil else { throw Failure.locationRemains }
        }
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

    private static func writeMovie(from source: URL, to destination: URL) async throws {
        let fileType: AVFileType
        switch destination.pathExtension.lowercased() {
        case "mov": fileType = .mov
        case "mp4": fileType = .mp4
        case "m4v": fileType = .m4v
        default: throw Failure.unsupportedFormat
        }
        guard
            let session = try await AVAssetExportSession(
                asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)
        else { throw Failure.unsupportedFormat }
        guard await session.supportedFileTypes.contains(fileType) else { throw Failure.unsupportedFormat }
        session.metadataItemFilter = .forSharing()
        try await session.export(to: destination, as: fileType)
        let outputMetadata = try await AVURLAsset(url: destination).load(.metadata)
        let locationIdentifiers: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataLocationISO6709,
            .quickTimeUserDataLocationISO6709,
        ]
        guard
            !outputMetadata.contains(where: { item in
                item.identifier.map(locationIdentifiers.contains) ?? false
            })
        else { throw Failure.locationRemains }
    }
}
