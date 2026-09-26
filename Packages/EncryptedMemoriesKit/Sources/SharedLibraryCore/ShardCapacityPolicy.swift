import Foundation

/// How full a shard album may get. Proton allows 10,000 photos per album and 500 albums per account. A photo group
/// counts with every file it adds to an album (a Live Photo's video, a burst's frames) until tests show which files
/// Proton counts; filling stops below the limit to leave that margin.
public struct ShardCapacityPolicy: Sendable, Equatable {
    /// Filling stops here.
    public let fillTarget: Int
    /// Proton rejects additions beyond this.
    public let hardLimit: Int
    /// Albums per account, including the owner's own albums.
    public let maximumAlbums: Int

    public init(fillTarget: Int, hardLimit: Int, maximumAlbums: Int) {
        self.hardLimit = max(1, hardLimit)
        self.fillTarget = min(max(1, fillTarget), self.hardLimit)
        self.maximumAlbums = max(1, maximumAlbums)
    }

    public static let proton = ShardCapacityPolicy(fillTarget: 9_500, hardLimit: 10_000, maximumAlbums: 500)

    /// Whether a shard that holds `count` files can take a photo group of `groupSize` files.
    public func accepts(groupSize: Int, into count: Int) -> Bool {
        count + max(1, groupSize) <= fillTarget
    }

    /// Whether the account can hold one more album.
    public func canCreateAlbum(existingAlbumCount: Int) -> Bool {
        existingAlbumCount < maximumAlbums
    }
}
