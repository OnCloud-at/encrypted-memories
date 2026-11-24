import Foundation
import PhotosCore
import UploadCore

/// Proton's refusal rounds of the photos that Album Sync backs up. Album Sync resets its queue before every album run,
/// and each run holds only the photos of one album, so the rounds live in this file next to the queue instead.
/// Without it, a photo that Proton refuses would get the full attempt budget again in every album run.
///
/// The file is a cache that can be rebuilt: losing it loses only rounds, so a photo gets more attempts, never fewer.
/// It sits in the account data directory, which sign-out removes as a whole. One album executor per account directory
/// reads and writes it, and Album Sync runs one album at a time, so no two runs write it at once.
struct AlbumSyncRefusalStore {
    static let fileName = "album-sync-refusals-v1.json"
    static let formatVersion = 1
    /// A file above this size is not one that this store wrote; it reads as unknown and the next complete write
    /// replaces it.
    static let maximumFileSize = 8 * 1024 * 1024

    /// The refusal rounds of one photo revision.
    struct Entry: Codable, Equatable, Sendable {
        let source: UploadSourceIdentity
        let revision: UploadBackupRevision
        /// The stored issue record of the row, with its `serviceRejection`.
        var lastError: String
        /// The build under which the photo's last round parked. A photo that stopped gets one more round under another
        /// build.
        var roundBuild: String?
    }

    /// The answer of one read.
    enum Lookup: Equatable {
        case found([Entry])
        case absent
        /// The file could not be read. A file that could be read but does not decode, or that a later app version
        /// wrote, is `replaceable`: only a complete write of the next run replaces it. A file that could not be read
        /// at all is not: a later read can succeed, so nothing overwrites it.
        case unknown(replaceable: Bool)
    }

    private struct Contents: Codable {
        let version: Int
        let entries: [Entry]
    }

    let url: URL
    private let fileSystem: any DurableFileSystem

    init(accountDataDirectory: URL, fileSystem: any DurableFileSystem = LocalDurableFileSystem()) {
        url = accountDataDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.fileSystem = fileSystem
    }

    func read() -> Lookup {
        let data: Data
        do {
            // The injected file system covers the writes only; the read and its size check use the local disk.
            // A file whose size cannot be read is unknown and left alone, as a file that cannot be read.
            guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
                return .unknown(replaceable: false)
            }
            guard size <= Self.maximumFileSize else { return .unknown(replaceable: true) }
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .absent
        } catch {
            return .unknown(replaceable: false)
        }
        do {
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard contents.version == Self.formatVersion else { return .unknown(replaceable: true) }
            return .found(contents.entries)
        } catch {
            return .unknown(replaceable: true)
        }
    }

    /// Replaces the whole file in one atomic step: a process that ends meanwhile leaves the earlier file or this one.
    /// This rests on the atomic write of Foundation (`Data.write(to:options: .atomic)`), which writes a temporary file
    /// and renames it over the earlier one.
    func replace(with entries: [Entry]) throws {
        let data = try JSONEncoder().encode(Contents(version: Self.formatVersion, entries: entries))
        try fileSystem.replace(url, with: data)
    }
}
