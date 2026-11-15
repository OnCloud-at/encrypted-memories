import CryptoKit
import Foundation
import PhotosCore

/// One JSON file per photo in a directory of the account data, named by the SHA-256 of "volume/node". The sign-out
/// purge removes the directory with the rest of the account data. The revert and the series dissolution journals keep
/// their files here; each decodes its own type and keeps its own rule for a file that does not decode.
struct PhotoJournalDirectory: Sendable {
    private let directory: URL
    private let fileSystem: any DurableFileSystem

    init(accountDataDirectory: URL, name: String, fileSystem: any DurableFileSystem) {
        directory = accountDataDirectory.appendingPathComponent(name, isDirectory: true)
        self.fileSystem = fileSystem
    }

    /// The bytes of the file of `uid`; nil when there is none. A file that cannot be read throws.
    func data(for uid: PhotoUID) throws -> Data? {
        let url = fileURL(for: uid)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Replaces the file of `uid` with `data` in one atomic step.
    func save(_ data: Data, for uid: PhotoUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileSystem.replace(fileURL(for: uid), with: data)
    }

    /// Removes the file of `uid`; nothing happens when there is none. Every other failure throws, also one that hides
    /// whether the file exists.
    func remove(for uid: PhotoUID) throws {
        do {
            try fileSystem.remove(fileURL(for: uid))
        } catch CocoaError.fileNoSuchFile {
            // No journal of this photo.
        }
    }

    /// The bytes of every journal file, in the order of the file names. A file that cannot be read throws.
    func allData() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try Data(contentsOf: $0) }
    }

    private func fileURL(for uid: PhotoUID) -> URL {
        let digest = SHA256.hash(data: Data("\(uid.volumeID)/\(uid.nodeID)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
