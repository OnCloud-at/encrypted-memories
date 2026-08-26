import Foundation
import PhotosCore

/// One bounded page of cluster identities. Platform hosts resolve these IDs into PhotoItems only for the
/// visible page, so opening a dense cluster does not materialize the complete member set.
public struct PhotoLocationClusterPage: Sendable, Equatable {
    public let index: Int
    public let uids: [PhotoUID]
    public let totalCount: Int
    public let hasPrevious: Bool
    public let hasNext: Bool

    public init(index: Int, uids: [PhotoUID], totalCount: Int, hasPrevious: Bool, hasNext: Bool) {
        self.index = index
        self.uids = uids
        self.totalCount = totalCount
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
    }
}

/// Deterministic, ID-only paging for map cluster detail.
public struct PhotoLocationClusterPager: Sendable, Equatable {
    public let pageSize: Int
    public let uids: [PhotoUID]

    public init(uids: [PhotoUID], pageSize: Int = 120) {
        self.uids = uids
        self.pageSize = max(1, pageSize)
    }

    public var totalCount: Int { uids.count }
    public var pageCount: Int { max(1, (uids.count + pageSize - 1) / pageSize) }

    public func page(at index: Int) -> PhotoLocationClusterPage? {
        guard (0..<pageCount).contains(index) else { return nil }
        let start = index * pageSize
        let end = min(uids.count, start + pageSize)
        return PhotoLocationClusterPage(
            index: index,
            uids: Array(uids[start..<end]),
            totalCount: totalCount,
            hasPrevious: index > 0,
            hasNext: index + 1 < pageCount
        )
    }
}
