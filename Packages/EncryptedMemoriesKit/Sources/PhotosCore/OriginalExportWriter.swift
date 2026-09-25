import Foundation

/// Writes decrypted originals to a destination that the user selected, and names downloaded originals for every
/// export path.
///
/// Every write goes to a staging directory on the destination volume first. The destination receives only a
/// complete file: a single original or a finished ZIP archive. Every unsuccessful exit removes the partial output.
public enum OriginalExportWriter {
    public enum Failure: Error, Equatable {
        /// The destination volume cannot hold the next original plus the archive headroom.
        case lowDisk
    }

    /// Headroom for the ZIP central directory and file-system metadata.
    static let archiveSafetyMargin: Int64 = 256 * 1024 * 1024

    /// Number of leading bytes that identify a media format when the original has no usable filename.
    static let headerByteCount = 64

    // MARK: - Naming

    /// Export filename of a downloaded original. The decrypted Proton filename wins. A missing extension comes
    /// from the leading bytes of the file, then the link MIME type, then the timeline media type.
    public static func exportFilename(
        forDownloadedOriginal file: URL,
        item: PhotoItem,
        metadata: PhotoMetadata?,
        fallbackBase: String
    ) throws -> String {
        let header = try fileHeader(file)
        let ext = OriginalFileNaming.resolvedExtension(
            filename: metadata?.filename,
            mimeType: metadata?.mimeType,
            header: header,
            fallbackMediaType: item.mediaType,
            isVideo: item.isVideo
        )
        return OriginalFileNaming.exportFilename(
            metadataFilename: metadata?.filename,
            fallbackBase: fallbackBase,
            ext: ext
        )
    }

    static func fileHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: headerByteCount) ?? Data()
    }

    // MARK: - Destination writes

    /// Downloads one original into a staging directory on the destination volume, then installs the completed file.
    public static func writeSingle(
        item: PhotoItem,
        to destination: URL,
        provider: any OriginalFileProvider,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let stagingDirectory = try stagingDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedFile = stagingDirectory.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        try await provider.writeOriginal(for: item.uid, to: stagedFile, onProgress: onProgress)
        try installCompletedFile(stagedFile, at: destination)
    }

    /// Streams several originals into one staged ZIP archive, one download at a time, then installs the archive.
    ///
    /// Each original is downloaded to a bounded sidecar file beside the staged archive, streamed once into the
    /// archive, and erased. The write stops with ``Failure/lowDisk`` before the volume runs out of space.
    public static func writeArchive(
        items: [PhotoItem],
        to destination: URL,
        provider: any OriginalFileProvider & PhotoMetadataProvider,
        freeBytes: (URL) -> Int64? = DeviceStorage.availableCapacity(at:),
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let total = Double(items.count)
        let stagingDirectory = try stagingDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedArchive = stagingDirectory.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        let writer = try ZipStreamWriter(url: stagedArchive)
        var success = false
        defer { if !success { writer.abort() } }
        var used = Set<String>()
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let metadata = try? await provider.metadata(for: item.uid)
            if let rawSize = metadata?.fileSize, rawSize > 0, rawSize <= Int(Int64.max / 2),
                let free = freeBytes(stagingDirectory), free < Int64(rawSize) * 2 + archiveSafetyMargin
            {
                throw Failure.lowDisk
            }
            let sidecar = stagingDirectory.appendingPathComponent(
                ".encrypted-memories-export-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: sidecar) }
            try await provider.writeOriginal(
                for: item.uid,
                to: sidecar,
                onProgress: { progress in onProgress((Double(index) + progress * 0.85) / total) }
            )
            try Task.checkCancellation()
            let size = Int64(try sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if let free = freeBytes(stagingDirectory), free < size + archiveSafetyMargin { throw Failure.lowDisk }
            let name = try exportFilename(
                forDownloadedOriginal: sidecar,
                item: item,
                metadata: metadata,
                fallbackBase: String(item.uid.nodeID.prefix(8))
            )
            try writer.addFile(name: uniqueArchiveName(name, used: &used), fileURL: sidecar)
            onProgress(Double(index + 1) / total)
        }
        try writer.finish()
        try installCompletedFile(stagedArchive, at: destination)
        success = true
    }

    /// A sandbox-safe staging directory on the destination volume.
    ///
    /// A save panel authorizes the selected file but not sibling files with generated names. Foundation's
    /// replacement directory is the location Apple provides for atomic-save staging on the destination volume.
    static func stagingDirectory(for destination: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
    }

    static func installCompletedFile(_ stagedFile: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try fileManager.moveItem(at: stagedFile, to: destination)
        }
    }

    /// Returns `name`, or `name 2`, `name 3` and so on before the extension, so archive entries never collide.
    static func uniqueArchiveName(_ name: String, used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }
}
