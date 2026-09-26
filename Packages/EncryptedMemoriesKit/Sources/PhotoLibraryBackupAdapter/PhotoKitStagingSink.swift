import Foundation
import UploadCore

/// Receives one original that PhotoKit downloads from iCloud. It hashes every chunk and also stages the bytes in the
/// temp store, so the upload reuses the file and the original downloads only once. When the temp budget or the disk
/// refuses a chunk, or the original outgrows half of the temp budget, the sink drops the partial file and only
/// hashes the rest; the upload then exports the original again, as before. The half keeps one large video from
/// starving the other photos that stage at the same time.
///
/// Not synchronized: the PhotoKit liveness guard serializes `receive`, and `finish`/`abandon` run after the request ended.
final class PhotoKitStagingSink: @unchecked Sendable {
    struct Result {
        let byteCount: Int64
        let sha1Digest: Data
        /// The committed temp file with every byte, or nil when the sink only hashed.
        let stagedURL: URL?
    }

    private let tempStore: BackupTempFileStore
    private let maximumStagedBytes: Int64
    private let sha1 = UploadSHA1Accumulator()
    private var byteCount: Int64 = 0
    private var partialURL: URL?
    private var handle: FileHandle?

    init(tempStore: BackupTempFileStore, filename: String) {
        self.tempStore = tempStore
        maximumStagedBytes = tempStore.maximumBytes / 2
        // PhotoKit exposes no size before the download, so the reservation starts empty and each chunk is accounted.
        guard let url = try? tempStore.reserve(filename: filename, expectedBytes: 0) else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: url)
        else {
            tempStore.discard(url)
            return
        }
        partialURL = url
        self.handle = handle
    }

    var isStaging: Bool { partialURL != nil }

    func receive(_ data: Data) {
        sha1.update(data)
        byteCount += Int64(data.count)
        guard let partialURL, let handle else { return }
        guard byteCount <= maximumStagedBytes else {
            dropStaging()
            return
        }
        do {
            try tempStore.recordWrite(to: partialURL, byteCount: data.count)
            try handle.write(contentsOf: data)
        } catch {
            dropStaging()
        }
    }

    /// Ends a completed download: the identity of every received byte and, if all of them reached the disk, the file.
    func finish() -> Result {
        var stagedURL: URL?
        if let partialURL, let handle {
            do {
                try handle.close()
                self.handle = nil
                stagedURL = try tempStore.commit(partialURL)
                self.partialURL = nil
            } catch {
                dropStaging()
            }
        }
        return Result(byteCount: byteCount, sha1Digest: sha1.finalizeDigest(), stagedURL: stagedURL)
    }

    /// Ends a failed or cancelled download and removes its partial file.
    func abandon() {
        dropStaging()
    }

    private func dropStaging() {
        try? handle?.close()
        handle = nil
        if let partialURL { tempStore.discard(partialURL) }
        partialURL = nil
    }
}
