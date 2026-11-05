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
    public static func candidate(for url: URL) throws -> UploadBackupAssetCandidate {
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

    /// Why one watched file does not enter the backup queue on return.
    public enum ReturnOutcome {
        /// The file is no longer on disk. It needs no backup and counts as done.
        case gone
        /// The file exists, but its attributes cannot be read. Its queue duty is owed.
        case unreadable(FolderEnumerationError.FailureClass)
        /// The file exists and its candidate enters the queue.
        case readable(UploadBackupAssetCandidate)
    }

    /// The one decision whether a watched file counts as returned: a file that is gone is done,
    /// a file whose attributes cannot be read is not.
    public static func returnOutcome(for url: URL) -> ReturnOutcome {
        do {
            return .readable(try candidate(for: url))
        } catch {
            let failure =
                error as? FolderEnumerationError
                ?? FolderEnumerationError(operation: .attributes, url: url, error: error)
            return failure.failureClass == .missing ? .gone : .unreadable(failure.failureClass)
        }
    }

    /// What a batch of returned watched files did.
    public struct ReturnBatch: Sendable, Equatable {
        /// True when every file is gone (done) or was submitted to the queue.
        public let allDone: Bool
        /// How many files were submitted to the queue. The queue itself may still drop a row,
        /// for example an excluded source or a dismissed recheck, so this does not promise the
        /// row survived.
        public let queuedCount: Int

        public init(allDone: Bool, queuedCount: Int) {
            self.allDone = allDone
            self.queuedCount = queuedCount
        }
    }

    /// Returns excluded watched files to the backup queue. A file outside the watched folders and
    /// a file that is gone need nothing and count as done. A file whose attributes cannot be read
    /// does not count as returned, so its queue duty stays with the coordinator. Readable files
    /// are enqueued even when another file of the batch could not be read.
    public static func returnToBackup(
        paths: [String],
        resolve: @Sendable (String) -> URL?,
        engine: UploadBackupSyncEngine
    ) async -> ReturnBatch {
        var candidates: [UploadBackupAssetCandidate] = []
        var allDone = true
        for path in paths {
            guard let url = resolve(path) else { continue }
            switch returnOutcome(for: url) {
            case .gone: continue
            case .unreadable: allDone = false
            case .readable(let candidate): candidates.append(candidate)
            }
        }
        guard !candidates.isEmpty else { return ReturnBatch(allDone: allDone, queuedCount: 0) }
        do {
            _ = try await engine.enqueueBatch(candidates)
        } catch {
            return ReturnBatch(allDone: false, queuedCount: 0)
        }
        return ReturnBatch(allDone: allDone, queuedCount: candidates.count)
    }
}
