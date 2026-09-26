import AlbumCore
import Foundation
import PhotosCore

/// One album that holds part of the shared library.
public struct ShardRecord: Sendable, Equatable {
    public let index: Int
    public let album: AlbumNodeIdentifier

    public init(index: Int, album: AlbumNodeIdentifier) {
        self.index = index
        self.album = album
    }
}

/// The account-wide shared-library state that all of the owner's devices agree on.
public struct SharedLibraryState: Sendable, Equatable {
    public var settings: SharedLibrarySettings
    public var hidden: Set<PhotoUID>
    public var personal: Set<PhotoUID>
    /// Shard albums in index order.
    public var shards: [ShardRecord]

    public init(
        settings: SharedLibrarySettings = .off,
        hidden: Set<PhotoUID> = [],
        personal: Set<PhotoUID> = [],
        shards: [ShardRecord] = []
    ) {
        self.settings = settings
        self.hidden = hidden
        self.personal = personal
        self.shards = shards
    }

    public func visibility(of photo: PhotoUID) -> PhotoVisibility {
        PhotoVisibility(isHidden: hidden.contains(photo), isPersonal: personal.contains(photo))
    }

    /// Merges every device's journal. For each thing, the latest change wins; journals in a newer format and
    /// unrecognized changes do not count.
    public static func merged(_ journals: [SharedLibraryJournal]) -> SharedLibraryState {
        var winners: [SharedLibraryMergeKey: SharedLibraryJournalEntry] = [:]
        for journal in journals where journal.isSupported {
            for entry in journal.entries {
                guard let key = SharedLibraryMergeKey(entry.change) else { continue }
                if let current = winners[key], !entry.supersedes(current) { continue }
                winners[key] = entry
            }
        }
        var state = SharedLibraryState()
        for entry in winners.values {
            switch entry.change {
            case .hidden(let photo, isHidden: true): state.hidden.insert(photo)
            case .personal(let photo, isPersonal: true): state.personal.insert(photo)
            case .settings(let settings): state.settings = settings
            case .shardCreated(let index, let album): state.shards.append(ShardRecord(index: index, album: album))
            case .hidden, .personal, .shardRetired, .unrecognized: break
            }
        }
        state.shards.sort { ($0.index, $0.album.nodeID) < ($1.index, $1.album.nodeID) }
        return state
    }
}
