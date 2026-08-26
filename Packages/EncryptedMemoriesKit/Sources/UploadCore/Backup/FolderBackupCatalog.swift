import Foundation

/// Streams supported files as backup candidates. The platform layer owns sandbox access for the
/// complete scan. A changed file modification date requires another content check.
public struct FolderBackupCatalog: UploadBackupAssetCatalog {
    public let folder: URL
    public let includeHidden: Bool

    public init(folder: URL, includeHidden: Bool = false) {
        self.folder = folder
        self.includeHidden = includeHidden
    }

    public func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let iterator = FolderEnumerator.stream(
            folder,
            includeHidden: includeHidden
        ).makeAsyncIterator()
        return AsyncThrowingStream(unfolding: {
            while let entry = try await iterator.next() {
                try Task.checkCancellation()
                if entry.isSupported {
                    return try Self.candidate(for: entry.url)
                }
            }
            return nil
        })
    }

    /// Creates one candidate from one file and reports attribute failures to the caller.
    static func candidate(for url: URL) throws -> UploadBackupAssetCandidate {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FolderEnumerationError(
                operation: .attributes,
                url: url,
                error: error
            )
        }
        guard let modified = attributes[.modificationDate] as? Date else {
            throw FolderEnumerationError(
                operation: .attributes,
                url: url,
                failureClass: .transient,
                domain: "EncryptedMemories.FolderEnumeration",
                code: 1
            )
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let snapshot = UploadBackupAssetSnapshot(
            source: .file(url),
            revision: UploadBackupRevision(date: modified),
            editRevision: .unavailable,
            resourceCount: 1
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: url.lastPathComponent,
            byteCount: size
        )
    }
}
