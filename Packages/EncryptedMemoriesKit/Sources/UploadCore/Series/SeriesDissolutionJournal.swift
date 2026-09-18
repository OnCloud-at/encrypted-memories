import CryptoKit
import Foundation
import PhotosCore

/// Durable record of one "Keep Only Favorites" operation on a series (burst).
///
/// Proton Drive cannot detach a related photo from its main photo. The operation therefore copies every
/// kept favorite into a new standalone photo and then moves the whole series to the trash. The journal is
/// written before each remote step, so a crash at any point resumes without a duplicate copy and never
/// trashes the series before every favorite exists as a standalone photo.
public struct SeriesDissolutionJournal: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// At least one favorite may still lack its standalone copy. The series is untouched.
        case copyingFavorites
        /// Every favorite has a confirmed standalone copy. The series may move to the trash.
        case trashingSeries
    }

    public struct Favorite: Codable, Sendable, Equatable {
        public let memberUID: PhotoUID
        /// The standalone photo that holds this favorite's original bytes. Nil until it is confirmed.
        public var copyUID: PhotoUID?
        /// True once the copy carries Proton's favorite tag. The tag is written once per copy.
        public var favoriteTagAdded: Bool
        /// Albums of the own library that already contain the copy. One entry per confirmed album write.
        public var addedAlbumIDs: [String]

        public init(
            memberUID: PhotoUID,
            copyUID: PhotoUID? = nil,
            favoriteTagAdded: Bool = false,
            addedAlbumIDs: [String] = []
        ) {
            self.memberUID = memberUID
            self.copyUID = copyUID
            self.favoriteTagAdded = favoriteTagAdded
            self.addedAlbumIDs = addedAlbumIDs
        }

        // An app update can meet a journal that an older build wrote without the carry-over fields.
        // Their absence means "nothing carried over yet", which is the safe state for a resume.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            memberUID = try container.decode(PhotoUID.self, forKey: .memberUID)
            copyUID = try container.decodeIfPresent(PhotoUID.self, forKey: .copyUID)
            favoriteTagAdded = try container.decodeIfPresent(Bool.self, forKey: .favoriteTagAdded) ?? false
            addedAlbumIDs = try container.decodeIfPresent([String].self, forKey: .addedAlbumIDs) ?? []
        }
    }

    public let seriesMainUID: PhotoUID
    /// Every photo of the series, the main photo included. All of them move to the trash together.
    /// A retry or a server read can add a member that the caller did not know.
    public var seriesUIDs: [PhotoUID]
    public var favorites: [Favorite]
    public var phase: Phase

    public init(
        seriesMainUID: PhotoUID,
        seriesUIDs: [PhotoUID],
        favorites: [Favorite],
        phase: Phase = .copyingFavorites
    ) {
        self.seriesMainUID = seriesMainUID
        self.seriesUIDs = seriesUIDs
        self.favorites = favorites
        self.phase = phase
    }

    public var confirmedFavoriteCount: Int { favorites.count { $0.copyUID != nil } }
    public var allFavoritesConfirmed: Bool { favorites.allSatisfy { $0.copyUID != nil } }
}

/// Persistence seam of the dissolution journal. `save` must be atomic and durable before it returns.
public protocol SeriesDissolutionJournalStore: Sendable {
    func journal(forSeries mainUID: PhotoUID) throws -> SeriesDissolutionJournal?
    func save(_ journal: SeriesDissolutionJournal) throws
    func remove(forSeries mainUID: PhotoUID) throws
    /// Operations that a crash or an error interrupted. After account activation the host resumes only those
    /// in the trash step; one that still copies favorites waits for the user.
    func pendingJournals() throws -> [SeriesDissolutionJournal]
}

/// One JSON file per series in the account data directory, replaced atomically. The sign-out purge removes
/// the directory with the rest of the account data. A file holds node identifiers only, never names or bytes.
public struct SeriesDissolutionJournalFileStore: SeriesDissolutionJournalStore {
    public static let directoryName = "series-dissolution"

    private let directory: URL

    public init(accountDataDirectory: URL) {
        directory = accountDataDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func journal(forSeries mainUID: PhotoUID) throws -> SeriesDissolutionJournal? {
        let url = fileURL(for: mainUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SeriesDissolutionJournal.self, from: Data(contentsOf: url))
    }

    public func save(_ journal: SeriesDissolutionJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: fileURL(for: journal.seriesMainUID), options: .atomic)
    }

    public func remove(forSeries mainUID: PhotoUID) throws {
        let url = fileURL(for: mainUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func pendingJournals() throws -> [SeriesDissolutionJournal] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(SeriesDissolutionJournal.self, from: Data(contentsOf: $0)) }
    }

    private func fileURL(for mainUID: PhotoUID) -> URL {
        let digest = SHA256.hash(data: Data("\(mainUID.volumeID)/\(mainUID.nodeID)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
