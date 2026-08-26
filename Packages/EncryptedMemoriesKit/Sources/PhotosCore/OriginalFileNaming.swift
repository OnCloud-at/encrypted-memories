import Foundation

/// Resolves the on-disk file extension for an exported or shared original from the best
/// available source in priority order.
///
/// The shared timeline `mediaType` can be a lossy placeholder. This pure decision combines the
/// decrypted Proton link filename, link MIME, and original-byte signature for both export paths.
///
/// Pure Foundation: no file I/O (callers pass the leading bytes), no `UniformTypeIdentifiers`/ImageIO
/// (which would break the PhotosCore cross-platform import allowlist), and no platform UI. Byte sniffing reuses
/// ``VideoContentSniffer`` so there is one magic-number source of truth.
public enum OriginalFileNaming {
    /// Canonical lowercased MIME to extension (no dot). The reverse of
    /// ``UploadCore.SupportedMedia.table``; kept here so Core export naming never depends on the
    /// system UTI database (deterministic across machines and CI).
    public static let extensionForMIME: [String: String] = [
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/heic-sequence": "heic",
        "image/heif-sequence": "heif",
        "image/avif": "avif",
        "image/tiff": "tiff",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/bmp": "bmp",
        "image/x-adobe-dng": "dng",
        "video/quicktime": "mov",
        "video/mp4": "mp4",
        "video/x-m4v": "m4v",
        "video/mpeg": "mpg",
        "video/webm": "webm",
        "video/x-matroska": "mkv",
    ]

    /// The MIME types the SDK timeline stamps on every item. They are too generic to trust for a
    /// concrete extension whenever a stronger signal (a real filename or the byte signature) exists;
    /// otherwise a HEIC would be labelled `.jpg`.
    public static let placeholderMIMETypes: Set<String> = ["image/jpeg", "video/quicktime"]

    /// Media extensions accepted verbatim from a real Proton filename (`IMG_0001.HEIC` becomes
    /// `heic`). This is the union of extensions recognised by ``VideoContentSniffer`` and image handling.
    public static let knownMediaExtensions: Set<String> = VideoContentSniffer.videoExtensions.union([
        "jpg", "jpeg", "png", "heic", "heif", "avif", "gif", "webp", "tiff", "tif", "bmp", "dng", "raw",
    ])

    // MARK: - Public API

    /// The best-source export extension (lowercased, no dot), or `nil` if nothing could be resolved
    /// (the caller then supplies a last-resort default). Prefer the recognized filename extension,
    /// then a non-placeholder MIME type, header signature, placeholder MIME type, and finally the
    /// timeline media type.
    public static func fileExtension(
        filename: String?,
        mimeType: String?,
        header: Data?,
        fallbackMediaType: String? = nil
    ) -> String? {
        // The original filename extension is authoritative.
        if let ext = recognizedExtension(fromFilename: filename) { return ext }

        // Prefer a metadata MIME type that is not the generic timeline placeholder.
        if let mime = normalizedMIME(mimeType), !placeholderMIMETypes.contains(mime),
            let ext = extensionForMIME[mime]
        {
            return ext
        }

        // Use the byte signature when the MIME type is a placeholder.
        if let header, let ext = extensionForHeader(header) { return ext }

        // Map the placeholder MIME type when no better signal is available.
        if let mime = normalizedMIME(mimeType), let ext = extensionForMIME[mime] { return ext }

        // Use the timeline media type as the final mapped source.
        if let mime = normalizedMIME(fallbackMediaType), let ext = extensionForMIME[mime] { return ext }

        return nil
    }

    /// Convenience: the export extension with a guaranteed value. Falls back to `mov` for anything
    /// that looks like a video, else `jpg`, matching the existing iOS and macOS fallback.
    public static func resolvedExtension(
        filename: String?,
        mimeType: String?,
        header: Data?,
        fallbackMediaType: String?,
        isVideo: Bool
    ) -> String {
        if let ext = fileExtension(
            filename: filename, mimeType: mimeType, header: header, fallbackMediaType: fallbackMediaType
        ) {
            return ext
        }
        return isVideo ? "mov" : "jpg"
    }

    /// The exported/saved file's full basename, metadata-first. The real decrypted Proton
    /// `metadataFilename` is authoritative - it IS the original's own name and already carries the correct
    /// extension (`IMG_0001.HEIC`), so it is returned verbatim (only sanitised for path safety), never
    /// re-stamped. This is what keeps a HEIC named `IMG_0001.HEIC` instead of a re-invented
    /// `ProductBrand-…jpg`. Only when no usable original name exists (metadata lookup failed completely, or
    /// the name is empty/unsafe) do we fall back to `fallbackBase` + the resolved `ext`. When the real name
    /// exists but lacks a recognised media extension, its base is kept and the sniffed `ext` appended.
    /// Pure/value-only, so the iOS and macOS export + Photos-save paths share one decision (unit-tested).
    public static func exportFilename(metadataFilename: String?, fallbackBase: String, ext: String) -> String {
        if let sanitized = sanitizedOriginalName(metadataFilename) {
            // The original's own extension is the most authoritative signal - keep the whole name verbatim.
            if recognizedExtension(fromFilename: sanitized) != nil { return sanitized }
            // A real base name with a missing/unknown extension: keep the base, append the sniffed extension.
            return "\(sanitized).\(ext)"
        }
        return "\(fallbackBase).\(ext)"
    }

    /// A filesystem-safe rendering of a real original filename, or `nil` when there is nothing usable.
    /// Reduces the name to its last path component and strips NUL/trailing whitespace so a hostile or
    /// edge-case Proton link name (`../evil`, `a/b/IMG.HEIC`) can never escape the export directory or
    /// create nested folders; `nil` for empty/whitespace-only / reserved (`.`/`..`) names so the caller
    /// uses its generated fallback.
    public static func sanitizedOriginalName(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let base = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != ".", base != ".." else { return nil }
        return base
    }

    /// The recognised media extension carried by a real filename, lowercased (no dot), or `nil` when
    /// the name is empty / has no extension / the extension isn't a known media type.
    public static func recognizedExtension(fromFilename filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, knownMediaExtensions.contains(ext) else { return nil }
        return ext
    }

    /// The concrete extension for a media file from its leading bytes, or `nil` if unrecognised.
    /// Distinguishes still-image ISO-BMFF brands (HEIC/HEIF/AVIF) from playable video containers
    /// (MOV/MP4) - the distinction `PhotoItem.mediaType` cannot make.
    public static func extensionForHeader(_ rawHeader: Data) -> String? {
        // Rebase to a fresh 0-indexed buffer so subscripting is safe regardless of how the caller
        // sliced the Data, and bound the work to the signature region.
        let head = Data(rawHeader.prefix(32))
        guard head.count >= 4 else { return nil }

        // ISO-BMFF `ftyp`: split still-image brands from video containers.
        if head.count >= 12, head.subdata(in: 4..<8).elementsEqual(Data("ftyp".utf8)) {
            let brand = (String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? "").lowercased()
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("hevc") || brand.hasPrefix("hevx")
            {
                return "heic"
            }
            if brand.hasPrefix("mif1") || brand.hasPrefix("msf1") || brand.hasPrefix("heif") { return "heif" }
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") { return "avif" }
            // Any other ftyp box is a playable video container.
            return VideoContentSniffer.videoExtension(forHeader: head)
        }

        // JPEG FF D8 FF
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        // PNG 89 50 4E 47
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "png" }
        // GIF "GIF8"
        if head.prefix(4).elementsEqual(Data("GIF8".utf8)) { return "gif" }
        // TIFF little-endian "II*\0" / big-endian "MM\0*" (also the container of most camera RAW/DNG)
        if head[0] == 0x49, head[1] == 0x49, head[2] == 0x2A, head[3] == 0x00 { return "tiff" }
        if head[0] == 0x4D, head[1] == 0x4D, head[2] == 0x00, head[3] == 0x2A { return "tiff" }
        // WebP: "RIFF" .... "WEBP"
        if head.count >= 12, head.prefix(4).elementsEqual(Data("RIFF".utf8)),
            head.subdata(in: 8..<12).elementsEqual(Data("WEBP".utf8))
        {
            return "webp"
        }
        // Matroska / WebM: 1A 45 DF A3
        if head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 { return "mkv" }
        return nil
    }

    // MARK: - Private

    /// Lowercases + trims a MIME and strips any `; charset=…` parameter, or `nil` when empty.
    private static func normalizedMIME(_ mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.split(separator: ";").first.map(String.init) ?? mime
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
